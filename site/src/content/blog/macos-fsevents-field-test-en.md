---
title: What macOS FSEvents actually reports when you move and delete files in Finder
date: 2026-08-27
tags: [macos, engineering, file-watching]
lang: en
draft: true
---

The P-Pass desktop app stores the photos it receives from phones in an ordinary folder on the computer, at a path like `~/Pictures/P-Pass 家庭照片库/originals` (`P-Pass 家庭照片库` is the app's default folder name). You can open it in Finder, and anyone can browse it, drag files around, delete them, or create subfolders.

That leads to a requirement we can't avoid: when a user changes these files in Finder, the P-Pass index and photo wall have to follow.

To do that, the desktop daemon needs to know what happened in the directory. We use the Rust `notify` crate (version 7), which is backed by FSEvents on macOS. While writing the watcher, there was one thing we had never actually checked: which events FSEvents emits when you do these things in Finder.

On August 21, 2026, we ran a field test that performed 11 kinds of file operations and printed every event we received. The results ruled out our leading hypothesis for a deletion bug we were chasing, and they changed the rules the watcher uses to handle events and index files.

## Why we watch the library folder

Two parties write to the library folder. One is P-Pass itself: photos from a phone land in a staging area first and are then moved into `originals/`, which at the time was laid out as `<device>/year/month/`. The other is the user, who can reorganize, delete, or add photos in Finder at any time.

The `asset` table in the index records each photo's content hash and its path relative to the library, `rel_path`. The photo wall and the timeline both read from the index. If the files change and the index doesn't, the UI goes wrong in one of two ways: deleted photos still show up, or photos that still exist disappear. We ran into both.

The overall structure of the watcher was settled when we first built it. After an event arrives, it waits for a quiet window (500 ms by default), and any new event inside the window restarts the timer. It then collapses the paths in that batch to their parent directories, deduplicates them, and runs an incremental scan on those directories. The scan goes in two directions. The add direction indexes media files that are on disk but not yet in the index. The delete direction removes records that are in the index but no longer on disk.

Whether this design holds up depends on whether we understand the events correctly. On August 20, while debugging a "deleted photos stay on the photo wall" bug (details below), we realized that much of what we believed about FSEvents was assumed and had never been verified. We ran this test the next day.

## How we tested

We wrote a diagnostic test that is skipped by default and run by hand when needed. It creates two folders in a temporary directory: `watched`, which is being watched, and `outside`, which stands in for a location outside the library. It then performs 11 operations in order, pausing 900 ms after each one, and prints the events received during that pause exactly as they arrive.

None of these operations were done by hand in Finder. The test code reproduces them with the equivalent file system calls: `std::fs::write` to write files, `std::fs::rename` to rename and move, and `remove_file` and `remove_dir_all` to delete. Finder actions reach the file system as these same kinds of calls. Dragging a file into another folder on the same volume is a rename, and the inode stays the same. "Move to Trash" renames the file or directory into `~/.Trash`, which is also a same-volume rename. That is why rows ⑥ and ⑦ in the table use "rename into or out of the watched directory" to reproduce "drag in from somewhere else" and "move to Trash."

At startup the test prints the active watcher implementation. The output is `Fsevent`, which confirms it is using FSEvents.

## Results

| Operation | Events received |
|---|---|
| ① Create file `a.jpg` | `Create(File)` + `Modify(Metadata)` + `Modify(Data)` |
| ② Overwrite the contents of an existing file | `Create(File)` + `Modify(Metadata)` + `Modify(Data)` |
| ③ Rename in the same directory, `a.jpg` → `b.jpg` | `Create(File)` on `a.jpg` + `Modify(Name)` on `a.jpg` + `Modify(Name)` on `b.jpg` |
| ④ Create nested directories `sub/deep` | `Create(Folder)` ×2 |
| ⑤ Move into a subdirectory (sorting inside the library) | `Modify(Name)` on the old path + `Modify(Name)` on the new path |
| ⑥ Move in from outside the library | A single `Modify(Name)` on the new path |
| ⑦ Move out of the library (equivalent to moving to Trash) | A single `Modify(Name)` on the old path |
| ⑧ Delete a single file | `Remove(File)` + `Modify(Name)` |
| ⑨ Write 5 files in a row, then `rm -rf sub` | 5 sets of Create + Modify, then `sub/deep` reports both `Create(Folder)` and `Remove(Folder)` |
| ⑩ Delete the watched root directory | `Remove(Folder)` |
| ⑪ Recreate a root directory with the same name and write a file | Events are delivered as usual |

The event names are `notify`'s `EventKind`, with the subtype in parentheses.

## What the table tells us

### Event types can't be trusted

Three rows make the point. In ②, overwriting a file that already exists is reported as `Create`. In ③, the rename produces a `Create` on the old name `a.jpg`, at the very moment `a.jpg` is going away. In ⑨, deleting a directory produces both `Create` and `Remove` on the same path, `sub/deep`.

The cause is how FSEvents delivers changes. Within a time window it merges all changes by path and hands over a bitmask of flags, and `notify` then splits that mask into several events. So the only thing an event tells you for certain is that something happened at this path. Which thing happened is inferred from the mask.

If the code branched on event type, for example deleting from the index on `Remove` and indexing on `Create`, then case ③ would treat a path that was just renamed away as a new file, and case ⑨ would treat the same directory as both created and deleted.

### Moves have no source or destination

Look at ⑥ and ⑦ together. Moving a file in from outside the library produces a single `Modify(Name)` on the new path. Moving it out produces a single `Modify(Name)` on the old path. The two operations look identical at the event level: one rename event on whichever path sits inside the watched directory.

The system doesn't tell you where a file came from or where it went. When a path receives `Modify(Name)`, the only way to know whether the file arrived or left is to `stat` that path. In ⑤, a move inside the library reports both the old and new paths, but nothing links the two events as a pair.

For photo backup, this finding matters most. When a user drags a photo from one folder to another, what we see in the events is "a file disappeared here and a file appeared there." Recognizing that both are the same photo takes some other method.

### Bulk operations arrive as one batch

In ⑨, the five writes and the `rm -rf` all arrived in the same read. The number of events doesn't really matter; deduplicating the affected directories and scanning them once is enough. The quiet window, parent-path collapsing, and incremental scan are designed for exactly this shape of input.

### The watch survives deleting and recreating the root

Rows ⑩ and ⑪ ruled out the leading hypothesis on our list for the deletion bug. We had thought the most likely cause was that deleting an entire subtree invalidates the FSEvents watch handle, so no further events arrive. In the test, we deleted the whole watched root, created a new directory with the same name, wrote a file into it, and events were delivered as usual.

We pinned this down with an asserting test, `watch_survives_the_root_being_deleted_and_recreated`. If the platform behavior ever does change, this test will fail first.

### The rule we adopted

Put together, these findings gave us the rule we have followed since: **an event only says "go look at this path"; the files actually on disk are the source of truth.**

In the P-Pass watcher, this means event types play no part in decisions and only the path is used. After paths are collapsed into directories, the add direction scans the media files that actually exist on disk, and the delete direction checks each path recorded in the index for existence and removes the record only if the file is gone. Events can't reliably tell you what operation a file went through, so the watcher doesn't try to infer it.

## Two bugs we hit while implementing it

The rule is simple, but once it was in code we still had two bugs, both involving path strings.

### One extra slash

On August 20, we deleted all the photos under `originals` in Finder. The directory was left with only a `.DS_Store`, yet all 186 records in the index were still there, and the photo wall didn't change at all.

Partial reconciliation turns each affected directory into a relative prefix and then queries the index for the records under that prefix:

```rust
let prefix = format!("originals/{}", rel.to_string_lossy());
// list_asset_paths_under then appends another layer:
let like = format!("{prefix}/%");
```

When a single file is deleted, the affected directory is a subdirectory like `<device>/2026/08`, `rel` is non-empty, and the prefix is correct. When an entire subtree is deleted, the parent of the deleted directory still exists, and parent-path collapsing keeps the shallowest level, so the affected directory converges to `originals` itself and `rel` is an empty string. The resulting query is:

```
prefix = "originals/"  →  LIKE 'originals//%'  →  0 rows matched
```

The index clearly had records, but the query returned zero, so nothing was deleted and the UI was never told to refresh. A temporary probe we added printed `rel=""` and `matched rows = 0` on the spot.

While debugging, we listed three hypotheses: the FSEvents handle becomes invalid after a whole-tree delete; the logic in the indexing pipeline that filters out transient deletes was swallowing real deletes; or the daemon wasn't running, or was running an old build. All three were ruled out. The first is the one the field test above disproved.

The integration tests had been green all along, because they deleted single files, while the user had deleted a whole directory tree. `list_asset_paths_under`, the function that looks up records by prefix, had no tests at all, so the double slash sat in the code unnoticed.

We fixed a second problem at the same time. When the scan function hit a directory that no longer existed, it returned an `ENOENT` error, the pipeline exited early, and reconciliation in the delete direction was skipped along with it. When a whole directory has been deleted, failing to read it is expected, so this case is now treated as "nothing to scan" and the delete direction runs as usual.

The fix strips the trailing slash from the prefix before querying. The new tests cover three deletion shapes: `rm -rf` on a whole subtree, Finder's "Delete" (renaming the top-level directory into `~/.Trash`), and a required UI refresh notification after a whole-tree delete. We reverted each fix to check, and the corresponding tests fail every time.

Both delete-direction fixes have been merged and the tests cover the shapes above, but they have not yet been verified on a real device. Two things need to be checked: after deleting a few photos, or an entire date folder, in Finder, the photos should disappear from the photo wall within 5 seconds and the index row count should drop accordingly.

### `/var` and `/private/var`

The second bug was in moves inside the library. We found it while fixing the deletion problem, and it was more serious.

Start with the move problem itself. A user drags an already backed-up photo from a date folder into `originals/My Wedding/`, a folder they created. The file is safely on disk, but the photo disappears from the photo wall and the phone's timeline, and it never comes back.

In a single pass, the watcher runs the add direction first and then the delete direction:

1. The add direction finds the file at its new location, computes its hash, sees that the index already has this content, and treats it as a duplicate. It doesn't update `rel_path`, so the index still points to the old location.
2. The delete direction checks the old directory, finds no file at the old path, and deletes the record, deletes the thumbnail, and writes an audit entry for an external deletion.

The photo is gone from the index. No further file system events will arrive, so nothing triggers a rescan.

The problem was how we defined identity. P-Pass is content-addressed: the hash is a photo's identity, and `rel_path` is only its current location. When the location changes, the right action is to update that record's path. Now, when the hash matches, we first check whether the file the index points to still exists:

| File recorded in the index | Where the newly found file is | Action |
|---|---|---|
| Still exists | Anywhere | Treat as duplicate; leave the source file alone |
| Gone | Already inside `originals/` | Treat as a move; keep the location the user chose |
| Gone | Outside the library (received from a phone, still in staging) | Treat as a move; place it using the date layout at the time |

To decide whether the newly found file is already inside `originals/`, we strip the library root prefix from its path. That is where the bug was. On macOS, `/var` is a symlink to `/private/var`, and FSEvents reports real paths with symlinks resolved. So the watcher's watch root was run through `canonicalize` when it was created, but the library root, `library_root`, was not. Whenever any component of the library path is a symlink, such as `/var`, one side has `/private` and the other doesn't, `strip_prefix` always fails, and an in-library move is misclassified as "from outside the library." The file then gets moved back into a date folder, and the user's own organization is undone.

The fix is to `canonicalize` both sides before comparing. We checked this one the same way: with `canonicalize` removed, the end-to-end test `moving_a_file_inside_originals_keeps_it_indexed` fails immediately. This test runs against real FSEvents, and in addition to counting records, it asserts that `rel_path` points to the new location and that the file is actually there. A test that only counts records would miss errors about where a record points.

The in-library move fix was verified on a real device on August 27: after dragging a backed-up photo into a user-created folder, it still shows on the photo wall and in the timeline, and the file stays where it was dropped.

## What P-Pass does when you organize photos in Finder

The field test also drove a product decision: lenient indexing.

The old indexing policy treated `originals/` as a directory only P-Pass could write to. Any file that didn't match the date layout was moved back into a date folder during indexing. A user who sorted photos into their own folders, or dropped new photos in by hand, would find the next day that everything had gone back to `2026/08/`. For a backup tool, moving a user's files away from where they put them makes people more reluctant to use it than losing a photo would.

We changed the rule: media files anywhere under `originals/` are indexed where they are. We only choose a location for files received from a phone that are still in staging.

The test results back this decision up. Since macOS can't tell "dragged in" from "dragged out," we have to `stat` every path anyway, so letting users put files wherever they like costs nothing extra, while enforcing the date layout means an extra move. In addition, the logic that rebuilds the index from the directory tree already accepted hand-placed files. With strict indexing and lenient rebuilding, a single rebuild would change what the library means.

Before switching to lenient indexing, one precondition had to be in place: a path can be claimed by only one index record. When a user edits an indexed photo in Finder, its contents change, so its hash changes, and a new record is inserted while the old record still points to the same path. Under the old strict layout, the edited file would be moved away, the old path would become empty, and reconciliation would clean up the old record as a side effect, which hid the problem by accident. Lenient indexing no longer moves files, so now, when indexing finds the target path already claimed by a different hash, it deletes the old record and leaves an audit entry.

In concrete terms:

- Create a new folder and drag backed-up photos into it: the photos stay where you put them and show on the photo wall and timeline as usual.
- Drag new photos into `originals/`: they are indexed within a few seconds, stay in place, and are attributed to this computer. Non-media files are still filtered by an allowlist.
- Edit an indexed photo in Finder: there is only one copy at that location, and both the thumbnail and the original open.
- Delete photos or a whole folder in Finder: by design, the photos disappear from the photo wall and the index shrinks to match. The fix for this has been merged and has test coverage, but it has not yet been verified on a real device.

The first three were verified on a real device on August 27.

A few more things to be clear about. The names of folders you create don't currently appear anywhere in the UI. The timeline is ordered only by capture time, and the photo info the phone receives has no path field, so a folder's name has no effect on what's displayed. Turning folders into albums is separate work that hasn't started. Photos you add by hand are attributed to this computer. If you later move the whole library to another computer and rebuild the index, those photos will be attributed to the new computer; their contents and the timeline are unaffected.

There is also a performance cost. Right now, recognizing that a file has moved relies on recomputing its hash. We measured this on a real machine with 203 photos totaling 570 MB: one pass of `stat` took 0.9 ms, and hashing all of them took 573.2 ms, a difference of about 620x. Those numbers are with a warm cache; on a spinning hard drive or a network drive it could be another order of magnitude slower. Finder preserves the inode when it moves a file, so if we record `(dev, inode, size, mtime)` in the index, an unchanged `stat` result is enough to identify a move without rereading the file. This requires a schema change. We have decided to do it, but it isn't scheduled yet.

## FAQ

### Can FSEvents tell a rename apart from a file creation?

Not reliably. In our test, renaming `a.jpg` → `b.jpg` in the same directory produced a `Create(File)` on the old name and a `Modify(Name)` on each name, and overwriting an existing file also reported `Create`. The event type is inferred from merged flags, and only the path can be trusted. To know the current state of a path, you have to `stat` it yourself.

### Does the notify crate give you the source and destination of a rename on macOS?

Not in our tests. Moving a file in from outside the library and moving it out each produced a single `Modify(Name)` on the path inside the watched directory. A move inside the library produced two `Modify(Name)` events, old and new, but nothing pairs them together. Recognizing that something was a move is up to you. P-Pass does it by content hash.

### If I move backed-up photos in Finder, will P-Pass treat it as a deletion?

No. When you move a photo inside the library, its index record is kept and only its path is updated to the new location. The photo wall and phone timeline show it as usual, and the file stays where you put it. This has been fixed and was verified on a real device on August 27. The cost is that moving a large number of photos at once means rereading those files to compute hashes, and how long that takes depends on how many there are and how fast the disk is.

### Can I create my own subfolders inside the originals folder to organize photos?

Yes. Media files anywhere under `originals/` are indexed where they are and won't be moved back into date folders. Subfolder names don't yet appear as albums in the UI.

### How long does it take for the photo wall to update after I delete photos in Finder?

The design target is a few seconds. The watcher processes the batch after 500 ms with no new events, reconciliation finds the files are gone, and it deletes the records and tells the UI to refresh. The slash bug that stopped whole-directory deletes from taking effect has been fixed, the code has been merged, and the tests cover both `rm -rf` and moving to Trash. The "gone within 5 seconds" check has not yet been verified on a real device.
