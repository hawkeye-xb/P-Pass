---
title: Why I'm building photo backup for my family
date: 2026-07-31
tags: [product, design]
lang: en
draft: false
---

Photos on someone else's cloud mean monthly fees, a password to remember, and a company you have to trust will be around. Photos at home have none of these problems — the self-hosting community proved long ago that people want this. Existing tools just assume you can run Docker, configure a reverse proxy, and keep a server humming.

Our families can't do those things, and shouldn't have to. They're simply people who worry about their photos.

And most families already own a "server" — the computer that's always on anyway.

So the question became very concrete: **can we build a zero-threshold version — phone photos landing automatically on the computer that's already running at home? Scan one code, then never think about it again.**

## What we crossed out first

Once the positioning was clear, the first decisions were all about what *not* to build:

- **No cloud storage** — photos on someone else's servers means entrusting the family's memories to a company's billing page;
- **No accounts** — family members can't remember passwords, and shouldn't be asked to;
- **No paywall on peace of mind** — "are my photos safe?" shouldn't be a question you pay monthly to ask. Backing up at home is free, forever.

What we want instead: **photos leave the phone and land on the computer at home**. Devices talk directly, through no one else's cloud.

## "No cloud" is the floor, not a selling point

This decision sits at the very front of the project docs, as a data rule:

> Data stays off the cloud, off any server. The relay is a forwarding fallback, nothing more. Privacy is the floor.

In practice: photo bytes, thumbnails, filenames, and the timeline exist only on the family's own devices. The relay forwards encrypted data and never stores or decrypts it — even if the relay were seized, whoever took it would get ciphertext they cannot read.

This stance isn't marketing; every design decision in the project answers to it.

## Designed for the 60-year-old in the family

One line gets quoted again and again inside the project: **devices are called "Mom's phone", not NodeId.**

Engineers see nodes, identities, encrypted channels. Family members see "is my phone connected to the computer at home?"

So the interaction is compressed to the minimum: pick up the phone, scan one code, then do nothing. Open the app and get the truth — "128 photos on this phone · 126 backed up · 2 to go" — or an honest "not safe yet, still transferring".

Simple doesn't mean black box. There are three layers of control:

1. **Visible** — backup status tells the truth, both ends of a transfer can see it, and whether the link is direct or relayed is labeled;
2. **Interruptible** — pause, cancel, pick albums, disconnect at any time; either end can stop unilaterally;
3. **Auditable** — every pairing and every backup is recorded in plain language, not log codes.

## Where it is now

P-Pass currently runs on macOS + Android, end-to-end encrypted, photos transferred directly between devices, with a relay only helping out when the two ends can't reach each other. Open source, code on [GitHub](https://github.com/hawkeye-xb/P-Pass).

This was written right after the first milestone. The design process, the pits we fell into, the trade-offs — they'll all appear on [this blog](/blog/) over time: how the icon went through nine iterations, how the desktop turned 3-second polling into 36-millisecond events.

The scariest thing about building for family is "looks usable, but nobody trusts it". The goal has always been the same: give "are my photos safe?" an answer that doesn't require trusting anyone.
