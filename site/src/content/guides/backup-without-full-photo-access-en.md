---
title: "Back up selected albums, folders, or a few photos without granting full photo library access"
description: "Pairing a phone with P-Pass does not require full photo library permission. Send picked files one-off, grant selected-photos access, or back up local folders only."
date: 2026-11-27
tags: [guide, permissions, privacy, backup]
lang: en
draft: false
---

Right after pairing a photo backup app, many people hesitate to grant full access to an entire camera roll filled with screenshots, chat receipts, and years of unsorted photos. With P-Pass, pairing does not immediately touch your photo library. You can choose to send a few picked files once, grant system "Selected Photos" access, or back up only a local folder on the phone.

Narrowing permissions often introduces subtle traps: landing directly on the home screen can fool users into thinking automatic backup has started when zero photos are queued, or an app opens its own picker right after the OS already asked you to pick selected photos. P-Pass settles these details with an explicit start choice, path-based transfers, and strict timestamp rules.

## Minimal-permission backup options after pairing

Once QR pairing finishes, the phone app stops at a two-choice setup screen separating automatic backup from a quick manual test send so you always know whether automatic transfers are active. You have three ways to back up without granting full library access:

- **One-off manual picks**: If you only want to send a handful of photos or videos occasionally, use the picker on the home screen to send them once. Automatic backup stays off, and no persistent temporary copy is stored inside the app. On iOS, files picked through the system selector remain accessible only while the app stays in the foreground; switching away pauses the transfer, and returning resumes it.
- **System "Selected Photos" access**: When you choose partial access in the OS permission prompt, P-Pass queues the exact photos you already selected in that system dialog without forcing you through a second in-app picker.
- **Local folders only**: Under Settings -> Backup range -> Add a Folder, if you add only local device directories (such as a camera app folder) and leave all system photo albums unchecked, enabling automatic backup never asks for system photo library permission.

In addition, each phone stores its backup range per paired computer. Pairing your phone to another computer never silently carries over the albums or folders configured for the first machine.

## How start-date filters avoid re-uploading older imported photos

When choosing to back up only photos taken from today onward, a common surprise is seeing years-old photos start uploading simply because they were recently imported or moved between folders.

Android records a fresh "date added to media store" whenever you copy old photos back onto a phone or move them across directories. Filtering by that field pulls old archives into today's batch. P-Pass drops media-store add timestamps completely and reads EXIF or video container capture timestamps first, falling back to file modification time only when capture metadata is missing. If neither exists, date-filtered runs skip the file rather than guessing with an import timestamp.

The start date is saved as a fixed timestamp on the device. Even if you toggle automatic backup off for a few days and turn it back on later, the start boundary stays anchored to the original date instead of sliding forward and skipping photos taken while backup was paused.

## What happens when folder permission is revoked

Fine-grained permissions introduce a different hazard: if you revoke access to an authorized folder in system settings, the next scan can no longer see the files previously recorded there.

At that moment, the app cannot distinguish an emptied directory from a revoked permission. To prevent treating missing access as deleted source files and corrupting desktop records, P-Pass halts reconciliation across the backup queue whenever any authorized folder becomes unreadable and prompts you to grant permission again before continuing.

## Current limits to keep in mind

- **Local folders cover on-device paths only**: Standalone folder backup covers local storage such as "On My iPhone" directories and subdirectories. External USB-C drives and cloud-drive placeholder folders are not supported, and scans only pick up photos and videos.
- **Home screen waiting counts**: The waiting count reflects only the albums and folders you selected in your backup range. Unchecked sources (such as screenshots by default) are neither counted nor uploaded automatically.
- **One-way backup while the computer stays awake**: Backups only add files to the computer folder, so deleting photos on your phone leaves the computer copy intact. The computer must stay on and awake during transfers.

For general questions and download links across all platforms, see the [P-Pass homepage](https://p-pass.hawkeye-xb.com) and [FAQ](https://p-pass.hawkeye-xb.com/faq/).
