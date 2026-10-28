---
title: Connect first, get faster later, which is why P-Pass runs on iroh
description: "A photo you take while you're out should still make it to the computer at home. That's the main reason P-Pass picked iroh: it connects through a relay first, punches holes in the background, and moves to a direct path once one opens. Not needing accounts came along with it. The cost is no browser access and a young dependency."
date: 2026-07-29
tags: [engineering, networking, architecture]
lang: en
draft: false
---

You take a photo while you're out on 5G. The computer at home is behind its router, and the photo is already heading there. That's the main reason we went with iroh rather than WebRTC. Once iroh connects, it sends data through a relay and punches holes in the background, then moves to a direct path when one opens. If the network blocks UDP, it can fall back to a TCP relay on port 443. iroh handles that itself, so we didn't need our own TURN servers. P-Pass doesn't need accounts because iroh uses a device's public key as its identity. The price is that P-Pass doesn't work in a browser, and iroh is a young library.

A phone and a computer at home have two layers of NAT between them. Nobody can tell in advance whether hole punching will work, and the same phone can get a different answer on a different Wi-Fi network. If the app insists on a direct path before sending anything, or reports an error when hole punching fails, the user is left looking at a photo stuck on "waiting".

An iroh endpoint connects to a relay as soon as it starts. When it dials a peer, the first data goes through that relay, so the connection is usable right away. The two ends use the relay to swap the addresses they see for themselves and start punching holes. If a direct path checks out, traffic moves over to it on the same connection, and our transfer code doesn't have to do anything. If no hole ever opens, the connection stays on the relay and the photos still get there.

The relay runs over TCP on port 443, the same port as everyday HTTPS, and networks that block UDP usually leave it alone. It only forwards encrypted data and can't see the photos.

If you'd rather not use a public relay, you can run your own.

Around the time we made this call we ran a NAT traversal field test, and one setup was exactly this worst case. A 5G phone made 20 attempts to reach the computer at home and never got a direct path, but all 20 transfers finished over the relay, at a median 11.3 Mbps. When we swapped in a home computer on a clean network, the same phone went direct over IPv6 at 52 to 68 Mbps. The numbers are in [the field test post](/blog/nat-traversal-home-backup-field-test/).

When WebRTC's ICE can't get through, it falls back to a TURN relay, and TURN can run on port 443 as well. We'd just be the ones putting it together: deploying TURN servers and writing a signaling server for the SDP exchange. With iroh, the endpoint we get already goes through the relay first and switches to direct later.

iroh can move between relay and direct paths because it recognizes a peer by its public key. Each endpoint has an ed25519 key pair. You dial the public key, addresses are only used to find the peer, and in the handshake the other side has to prove it holds the private key. On the day the transport layer was merged, the test had two endpoints with no relay and no address lookup. They had only registered each other's public key, and they connected.

When the phone and the computer pair, each stores the other's public key, and every later connection is checked against it. No account system has to vouch for who's on the other end. To skip accounts with WebRTC, you'd keep the certificate around and remember the peer's fingerprint at pairing, say by scanning a QR code, and you'd write that part yourself.

iroh needs raw UDP to punch holes, a web page can't open a raw UDP socket, and the only peer-to-peer channel a browser has is WebRTC. So P-Pass has no web version, and you can't open a browser on any computer to look at the photos at home.

The iroh we use is its freshly released 1.0. Its API changed a lot across earlier major versions, and the phone apps call it through FFI bindings. We keep it inside one transport module. The rest of the code goes through a few small interfaces and never touches iroh's own types.
