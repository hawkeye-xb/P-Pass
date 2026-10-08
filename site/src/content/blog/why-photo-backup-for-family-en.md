---
title: Why we're building photo backup for families
description: "Why we built P-Pass: most families already own an always-on computer. Phone photos should land on it automatically, with no technical setup and one QR scan."
date: 2026-07-31
tags: [product, design]
lang: en
draft: false
---

Photos on someone else's cloud mean paying monthly for storage, remembering another password, and trusting that the company will be around. Photos at home live on your own drive, with no account to keep track of. The self-hosting community proved long ago that people want this. Existing tools just assume you can run Docker, configure a reverse proxy, and keep a server humming.

Our families can't do those things, and they shouldn't need to just to keep their photos safe.

And most families already own a "server": the computer that's always on anyway.

So the question became very concrete: **can we build a version that needs no technical setup, where phone photos land automatically on the computer that's already running at home? Scan one code, then never think about it again.**

## What we crossed out first

Once we knew who it was for, the first decisions were about what *not* to build:

- No cloud storage: photos on a company's servers stay there only as long as you keep paying and the company stays in business.
- No accounts: nobody in the family should need another password to back up their phone.
- No storage plan to buy: your photos live on your own drive, so how much you can keep depends on that drive.

What we want instead: photos leave the phone and land on the computer at home. Devices connect directly when they can; when they can't, a relay forwards the encrypted data. Photos are never stored in any cloud.

## Data stays off the cloud

This decision is the first data rule in the project docs:

> Data stays off the cloud and out of any database of ours. The relay is only a fallback for passing data along. Privacy is the floor.

In practice: photo bytes, thumbnails, filenames, and the timeline exist only on the family's own devices. The relay forwards encrypted data and never stores or decrypts it. Even if the relay were seized, whoever took it would get ciphertext they cannot read.

The design decisions that follow all start from this rule. The site you're reading is part of the evidence: it has no analytics scripts and no trackers. P-Pass is a privacy product, so we hold our own website to the same rule.

## Anyone in the family can use it

One line gets quoted again and again inside the project: **show a device as "Mom's phone" and keep NodeIds off the screen.**

Under the hood there are nodes, identities, and encrypted channels. A family member only wants to know whether their phone is connected to the computer at home.

So the interaction is cut to the minimum: scan one code, then do nothing. Open the app and it shows exactly where things stand: "128 photos on this phone · 126 backed up · 2 to go". Or an honest "not safe yet, still transferring".

The app is simple, but you can still see what it's doing and step in. There are three layers of control:

1. **Visible**: backup status is accurate, both devices in a transfer show it, and each connection is labeled direct or relayed.
2. **Interruptible**: you can pause, cancel, pick albums, or disconnect at any time, and either device can stop a transfer on its own.
3. **Auditable**: every pairing and every backup is recorded in plain language, with no raw log codes on screen.

## Where it is now

P-Pass currently runs on Macs with Apple silicon and Android phones. It's end-to-end encrypted, photos go directly between devices, and a relay only helps out when the two ends can't reach each other. The code is open source and on [GitHub](https://github.com/hawkeye-xb/P-Pass).

We wrote this right after the first milestone. Later posts on [this blog](/blog/) will cover the mistakes and trade-offs along the way, such as why the icon took nine rounds and why phone backups ended up running on Android's own job queue.

The worst outcome when building for family is an app that looks like it works but leaves you unsure. So backup counts, direct-or-relayed status, and every pairing record are right there in the app, and the code is open. You can check whether your photos are safe yourself, instead of taking our word for it.

## FAQ

### How is this different from iCloud Photos or Google Photos?

Your photos are stored on the drive of the computer at home. Nothing is uploaded to a cloud service, and there's no account to create. You pair your phone and computer once by scanning a code, and after that your phone sends photos only to that computer.

### What happens when the computer is off?

Backups need the computer to be on. While it's off, photos simply stay on the phone, untouched. Once the computer is back on and the two devices reconnect, the phone picks up where it left off.

### Can my phone back up when I'm away from home?

Yes. The devices connect directly when they can; when they can't, a relay run by a third party forwards the encrypted data, and it can't see your photos. By default, automatic backups run only when the phone is on Wi-Fi and the battery isn't low. To back up over cellular data too, turn off "Back up only on Wi-Fi" in settings.

### Which devices are supported?

A Mac with Apple silicon on the computer side, and Android 8.0 or later on the phone. Once both are installed, scan the QR code on the computer screen with your phone to pair them.
