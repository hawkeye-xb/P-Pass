---
title: How P-Pass knows a photo is already backed up
description: "A photo backup can go wrong in two ways: it misses a photo, or it stores one twice. P-Pass would rather store an extra copy than miss a single photo. Which hash we use, where and when it is computed, all follow from that."
date: 2026-07-30
tags: [engineering, backup, dedup]
lang: en
draft: false
---

Every hashing and deduplication decision in P-Pass follows one rule: we would rather store an extra copy on your computer than miss a single photo. You may therefore find more photos there than you expected, such as both the original and the edited version of a shot. Extra copies can be deleted. A missed photo usually goes unnoticed until the phone is lost, and by then there is nowhere left to recover it from.

## A photo's identity is the hash of its contents

To decide whether the computer already has a photo, P-Pass doesn't look at the file name. Switch phones and the camera starts counting from the beginning again, so two completely different photos can both be called `IMG_1234.JPG`. Go by the name and the second one gets treated as already there and skipped.

P-Pass runs BLAKE3 over the whole file and uses those 32 bytes as the photo's identity. The computer's index uses it as the primary key, and transfers are checked against it. We went with BLAKE3 because iroh-blobs, our transfer layer, already addresses data by BLAKE3, so dedup and transfer verification work off the same value.

The file is read 64 KiB at a time and hashed as it goes, so a 4 GB video takes about as much memory as a small picture.

Capture time and the original file name are kept too. Capture time places the photo on the timeline, and the name helps people recognise their files.

Crop a photo on the phone or adjust its colours and the bytes change, so the hash changes. P-Pass treats it as a new photo, uploads it and stores it separately. The earlier version stays on the computer and isn't overwritten.

That leaves two files of the same scene on the computer, which is intentional. If "looks about the same" counted as a duplicate too, any wrong call would skip the version the user wanted to keep.

## The phone hashes, the computer checks

When the phone finds new photos it reads each one, hashes it and sends the hashes to the computer in a batch. The computer looks them up in its index and sends back the ones it doesn't have. Anything it already has costs no transfer at all.

The phone and the computer run separate code in different languages, each with its own BLAKE3 library. A small slip in how chunks are handled would make them compute different hashes for the same photo, and dedup would stop matching. The Rust code on the computer side generates three test vectors. The longest is 1 MiB of pseudo-random data; the other two are an empty input and a 5-byte string. The phone's tests compare against each one bit for bit, feeding the 1 MiB vector in chunks the way a real photo is read. The empty-input result has also been checked against the value the BLAKE3 project publishes.

Once the data reaches the computer, the computer hashes it again itself. If that doesn't match what the phone declared, the whole upload is thrown away and the photo is sent again later. The duplicate check at ingest uses the computer's own hash as well.

If the computer simply trusted the phone's hash, a bug in the phone's code or a few bytes damaged on the way could put one piece of content into the library under another photo's identity. The next time the phone asked about that other photo, the computer would say it already had it, and that photo would be missed.

## When the same content arrives twice at once

If the content is already in the library and its file is still on disk, the computer writes nothing.

Two identical copies can arrive at almost the same moment. Both duplicate checks then see "not there yet", and both go ahead and write to disk. The hash is a unique key in the index, so whichever side writes its record second gets rejected, deletes the file it just wrote and treats the upload as a duplicate. Only one copy is left on the computer.

## The watermark moves only after the computer confirms

The phone doesn't reread its whole library every time. It keeps a watermark and only looks at photos added or changed since then, and the watermark moves forward only after the computer [confirms it got the batch](/blog/why-we-rebuilt-backup-core/). If the watermark moved first, the photos that didn't finish before a dropped connection would never be scanned again. As it is, if the network drops or the app is closed partway through, the next run starts from the old watermark, the same photos are asked about again, and the computer says it already has them.

On older system versions the photo library has no counter that goes up with every change, so the watermark has to go by when a photo was added to the library, which is only accurate to the second. The same photo may be reported more than once. The computer's duplicate check catches those, at the cost of the phone reading a few files again.
