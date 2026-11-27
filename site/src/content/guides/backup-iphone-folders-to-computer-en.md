---
title: Back up local iPhone folders (photos and videos) straight to your home computer
description: "Back up videos and photos from On My iPhone folders straight to your Mac or Windows computer without saving twice to Photos or granting full photo access."
date: 2026-11-24
tags: [guide, iphone, local-folder, backup]
lang: en
draft: false
---

When an external camera or recording app on your iPhone saves high-bitrate video inside a local folder under "On My iPhone" in the Files app, P-Pass 0.12.1 can back up that folder directly to an ordinary folder on your Mac or Windows computer without asking for permission to your system Photos library.

Until now, those files forced an awkward trade-off. Exporting a multi-gigabyte 4K clip into the Photos app doubles the storage used on your phone and mixes production footage with everyday snapshots. Leaving it only in the app's local directory keeps it out of standard photo-library backups, and copying large folders over a cable still requires manual sorting on the computer. P-Pass adds the chosen "On My iPhone" directory directly to your backup list and lands uncompressed originals on your home computer with no cloud server in between.

## Do you have to grant full Photos access to back up a folder?

No. P-Pass keeps system Photos albums and local folders as separate sources.

In the phone app, open Settings -> Backup range -> Add a Folder and pick the directory through the system folder picker. As long as you leave all system photo albums unchecked, turning on automatic backup never prompts for access to your Photos library. Authorized entries display the actual directory name (such as `Media`) so you can tell different app folders apart at a glance.

## Step-by-step setup (Mac or Windows with iPhone)

Once paired and configured, new photos and videos recorded into that directory resume transferring whenever your phone reaches your home computer:

1. **Choose the destination folder on your computer**: Open P-Pass on an Apple silicon Mac or 64-bit Windows PC and pick an ordinary folder for incoming originals, either on internal storage or an external drive. On Windows, if SmartScreen warns on first launch because the installer is unsigned, click "More info", then "Run anyway".
2. **Pair your iPhone**: Install P-Pass on your iPhone using the App Store or public TestFlight link from the P-Pass homepage. Open the app, scan the QR code on the computer, and enter the 6-digit confirmation code on the computer screen.
3. **Authorize only the target folder**: Go to Settings -> Backup range -> Add a Folder, navigate to "On My iPhone" in the system picker, and select the directory (for example `Blackmagic Camera > Media`). All subdirectories inside that folder are included automatically.
4. **Set a start date if needed**: On the same screen, you can pick a start date so only footage captured from that day forward is queued. P-Pass reads EXIF or video container creation timestamps first and falls back to file modification time when metadata is missing, rather than treating folder move dates as capture dates.
5. **Verify the original files on disk**: After transfer finishes, thumbnails appear in the computer's Photos view, and the exact original video files sit in the folder from step 1 ready to open directly with no transcoding.

If you only want to send a couple of clips occasionally instead of keeping automatic folder backup on, tap "Choose from Files" on the home screen to pick multiple videos for a one-off transfer.

## Does backing up create a second temporary copy on the phone?

No persistent duplicate copy is created on your iPhone. When reading videos from an authorized folder, P-Pass avoids copying multi-gigabyte files into its own temporary cache directory. Instead, it uses coordinated file reads with path-based streaming chunks (`by_reference`) to hash and transfer directly from the source directory.

iOS stores your folder grant as a security-scoped bookmark, restores it across app restarts, and refreshes expiring bookmarks within the existing grant. If the folder permission is revoked or the path becomes unreachable, the transfer queue pauses and prompts you to re-authorize the folder rather than treating missing access as deleted files. Even if the same clip was previously imported via the Photos library, the desktop app deduplicates by full-file content hash so only one original file is stored on disk.

## Current limits to keep in mind

Before adding a local folder to automatic backup, check these four boundaries:

- **Only "On My iPhone" directories are supported**: The current release covers folders stored locally under "On My iPhone" and their subdirectories. External USB-C drives, cloud-drive placeholder folders, and third-party File Provider mounts are not supported.
- **Photos and videos only**: Directory scans match image and video file types via system UTIs. Project configs, LUTs, audio tracks, and documents in the same folder are ignored. P-Pass backs up photos and videos only, not general file sync.
- **iOS foreground and background limits**: Keep P-Pass open in the foreground when sending multi-gigabyte clips. Once you leave the app, iOS controls if and when background work continues; interrupted transfers resume from where they stopped the next time you open the app.
- **One-way append-only backup while the computer stays awake**: Backups only add files to the computer folder. P-Pass does not delete original videos from your phone, nor does it mirror your phone's folder tree on disk. Transfers pause when the computer sleeps or shuts down, so keep a separate copy of critical footage on an external drive at the computer.

For general questions and download links across all platforms, see the [P-Pass homepage](https://p-pass.hawkeye-xb.com) and [FAQ](https://p-pass.hawkeye-xb.com/faq/).
