---
title: "Back up phone photos to an external drive: safe eject, unplug recovery, and library relocation"
description: "P-Pass separates the SQLite index and thumbnails from your original photos so external drives eject cleanly when idle, survive unplugs, and relocate cleanly."
date: 2026-11-27
tags: [guide, external-drive, storage, desktop]
lang: en
draft: false
---

Once phone photos and videos grow past a few hundred gigabytes, built-in computer storage fills up fast. Many families put the photo library on an external hard drive, or later move an existing library from the default folder onto a larger disk. P-Pass separates original files from the index ledger so external drives eject cleanly when idle, pause safely when unplugged, and relocate to a bigger drive without re-pairing phones or re-uploading anything.

Putting a photo library on an external drive usually breaks in three places: the operating system refuses to eject the disk because a background service holds open handles, forgetting to plug the drive in tricks backup software into clearing its index, or moving to a larger drive forces phones to scan and resend tens of thousands of files. The desktop service avoids all three by splitting where files live and checking a library marker on disk.

## Why an external drive can eject safely at any time

Backup tools often block disk ejection because they keep the SQLite index, transfer logs, and thumbnail cache inside the same folder as your photos. As long as the background daemon stays running, open file handles lock the drive. P-Pass splits those two locations on the desktop:

- **Inside the external drive or library folder**: only your uncompressed original photos and videos, a tiny `.ppf/` marker folder, and in-flight temporary staging files that must live on the same volume during an active write.
- **Inside local system app data**: the SQLite index, thumbnails, and transfer state stay on your computer's internal drive (under Application Support on macOS, or ProgramData for the Windows service), stored in per-library directories keyed by library ID.

Whenever no photo is actively writing to disk, the background service holds zero handles inside the photo library folder, so you can eject the drive from your file manager or system tray right away. Even if you click eject mid-transfer while a single photo is being written, the daemon halts that file, releases its handles so ejection succeeds, and resumes that incomplete file from its checkpoint the next time you plug the drive back in.

## Will forgetting the drive or renaming the folder wipe the index?

No. P-Pass stores a marker file at `.ppf/library-id` inside the library folder. Every time the desktop service starts or prepares a write, it verifies that the marker exists and matches the library ID recorded in its local ledger.

If the external drive is unplugged, or if you move or rename the library folder while P-Pass is closed or running, the service immediately stops reading and writing that path and enters a paused missing-library state:

1. **No guessing, no empty folders, no index wipe**: P-Pass never treats a missing disk as deleted photos and never silently creates a blank replacement folder at the old path.
2. **Clear status notice**: The desktop home screen switches to a paused-backup state showing the previous library path and sends a system notification.
3. **Automatic recovery**: A background check runs every 5 seconds. Plugging the drive back in or putting the folder back resumes backups automatically, or you can click Recheck in the window right away. Photos on your phones and device pairings stay untouched.

## How to relocate the whole library to a larger drive

"Change library location" in desktop settings runs a full library relocation rather than editing a single path string. After you pick a new folder (on the same drive or a different external drive) and confirm, the window temporarily pauses backups to show progress and moves the library in three steps:

1. **Pre-flight name and read checks**: Any unrelated personal files already sitting in the destination folder are left untouched as long as their names do not collide with top-level library entries. Any name collision aborts before copying starts, and cross-drive moves verify read access on every source file first.
2. **Native copy and per-file verification**: Same-drive moves rename cleanly; cross-drive relocations invoke the OS copy tool (`ditto` on macOS, `robocopy` on Windows) to copy originals, the `.ppf/` marker, and any personal files inside that folder, then verify file sizes, modification timestamps, and every indexed photo before switching the config and removing the old directory.
3. **Safe abort on interruption**: If you modify the source library folder mid-relocation, the job aborts, cleans up partial copies in the destination, and leaves the original library intact. If power drops or the app quits halfway through, the relocation plan and progress saved in local app data pick up cleanly on next launch.

Because `.ppf/library-id` moves with the library and index paths are stored relative to the library root, the computer keeps the same device identity. Phones never need to scan the QR code again, and already backed-up photos are not sent a second time.

## Which folders are blocked on purpose

Both initial setup and "Change library location" block four folder types up front and explain why:

- Operating-system folders and top-level personal roots that change constantly (such as Desktop, Documents, Downloads, or Pictures itself; P-Pass creates a dedicated `P-Pass Library` subfolder inside Pictures by default, or lets you pick another dedicated subfolder).
- Cloud sync folders, where sync clients moving temporary files interfere with library indexing.
- The bare root directory of an external drive (create a dedicated subfolder on the drive instead).
- Mapped network drives, network shares, or links pointing to remote locations.

## Practical limits to keep in mind

Deleting a photo on your phone leaves the copy on your computer or external drive untouched. The computer must stay awake while transfers run; while the drive is unplugged or the computer sleeps, photos stay on your phone until the connection returns.

For general questions and download links across all platforms, see the [P-Pass homepage](https://p-pass.hawkeye-xb.com) and [FAQ](https://p-pass.hawkeye-xb.com/faq/).
