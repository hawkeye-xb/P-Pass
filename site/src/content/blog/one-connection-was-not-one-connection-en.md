---
title: Why our QUIC connection cache still did five handshakes for five photos
description: "We cached one QUIC connection per (NodeId, ALPN), yet five photos still caused five handshakes on a real device. Why reuse failed and how we fixed it."
date: 2026-09-08
tags: [engineering, networking, backup]
lang: en
draft: false
---

If you send five photos in a row to the same device, you should only need one underlying connection.

We thought we had already built that. On Desktop, we cache one live QUIC `Connection` per `(NodeId, ALPN)`. A new file for the same peer over the same protocol just opens a new stream on that connection. QUIC supports concurrent streams natively, so there is no need for the borrow-and-return bookkeeping of a traditional connection pool.

The unit tests passed. On Android, Flow delivery had also stopped creating a throwaway `DaemonClient()` and was using the Endpoint the app process already had. Everything looked right.

Then we sent five images on a real device, and the logs showed five handshakes.

## Three things that all get called "a connection"

Bugs like this hide behind the word "connection." There are at least three layers:

```text
Endpoint       = a device's long-lived network identity and path knowledge
Connection     = one QUIC session between two Endpoints
Stream          = one independent file/request on a Connection
```

iroh handles NAT hole punching, falls back to a relay, and upgrades the path when a better one appears. An Endpoint also builds up path knowledge about the peers it talks to. What iroh does not do is hand back an existing `Connection` just because we called `connect()` again.

So Desktop has to keep its own keyed cache:

```text
(peer NodeId, ALPN)
    └── live Connection
            ├── stream: file 1
            ├── stream: file 2
            └── stream: file 3
```

That part was correct. The problem was on the other side.

## First real-device run: why the cache kept missing

We put five clearly labeled test images into an album selected for backup, then checked the Flow ledger on the phone, the completion receipts on Desktop, and the daemon debug log, item by item.

On the surface, the result was fine. All five items were backed up and reached `CONFIRMED`.

But the log showed five `ppf/blobs/1` connections going to five different provider NodeIds. The Desktop cache key is `(NodeId, ALPN)`. If the NodeId changes every time, every lookup misses.

The cache logic was fine. The test surfaced something the previous round of changes had hidden: **the control channel reusing the app's Endpoint did not mean the blobs provider that actually moves the photo bytes was reusing it too.**

The control plane and the data plane can have different identities. The protocol allows it, and it is a common setup. The control plane authorizes an immutable, hash-addressed ticket, and the data-plane ticket points at whichever Endpoint serves the bytes. Both running on the same phone is no reason to assume they share a connection.

## Root cause: the provider and the Flow bridge both rebuilt things "to be safe"

The old native blobs provider did the following every time it registered a photo:

1. Created a new private store.
2. Created a new iroh Endpoint.
3. Started a new blobs router.
4. Closed or revoked the previous provider before the next photo began.

The Flow bridge did something similar. Before starting the next strict head-of-queue item, it called `stopActiveFetch` and `revoke` on the previous native provider.

When every photo had its own connection, these steps made obvious sense: an old file should stop being served. They also threw away every reusable Endpoint, Connection, and piece of path knowledge.

The strict consumer's business rules never required that. They require that only one lease is active at a time, that the one active fetch stops on pause or cancel, and that an old photo can't keep being pulled without a current lease.

They do **not** require tearing down the whole network identity when one photo finishes successfully and the next one starts normally.

## The fix: tie each lifetime to its real boundary

We did not loosen pause behavior, and we did not add a pool to the business layer. We only moved each resource's lifetime back to where it belongs:

```text
Provider lifetime
  └── one Endpoint
  └── one private blob store
  └── one swappable blobs handler

Strict queue head advances normally
  └── register next photo → keep Endpoint / Connection

Pause / Cancel / revoke
  └── stop active fetch → shut down current data-plane service
  └── create a new active handler only on next resume
```

Put simply: **when one photo follows another normally, we only open a new stream and keep the Endpoint. Only Pause, Cancel, or revoke shuts down the current data-plane service.**

The strict consumer boundary stays intact. The consumer still decides which photo may start and when to cancel. The transport layer only decides whether a connection that is still alive can carry a new stream. Neither one takes over the other's job.

## How we checked this wasn't a lucky pass

We split the evidence into three parts.

### 1. A local test that fails on the old behavior

The new transport integration test requires that:

- Opening two streams in a row to the same `(peer, ALPN)` produces exactly one inbound connection.
- The ctrl and blobs ALPNs still use two separate connections.
- When the Android provider registers two photos with different content back to back, both tickets carry the same provider identity.
- When the receiver fetches both through `fetch_from`, the second fetch still goes to the same provider identity.

If we switch the cache path back to "connect every time," the connection-count assertion fails. A test that only checks that the transfer eventually succeeded stays green in that case.

### 2. Auditing the protocol semantics

Connection reuse changes the model from one connection per request to many streams on one connection, so we also reviewed the server's accept loop. A rejection, a malformed request, a cancellation, or a stream finishing normally must not let later streams skip authorization. It also must not cause the receiver to quietly stop accepting new streams.

Regressions like these never show up on the happy path for a single photo. They show up after revoke and re-pair, on retries, or on long-lived connections.

### 3. Evidence from a real device

After the fix, on a Samsung phone, five new test files all reached `CONFIRMED` with zero retries, and each had a completion receipt. The daemon debug log showed a single `ppf/blobs/1` connection/hole-punch, and all five `iroh-blobs` get requests ran over that one connection.

In the first real-device run, all five items had also reached `CONFIRMED`. Judging by outcomes alone, you would have thought the problem was fixed long ago. The only difference between the two runs is in the logs: `ppf/blobs/1` handshakes went from five to one.

## What is still unfinished

So far we have only shown connection reuse for consecutive successful items.

Real-device regression testing for Pause, Cancel, and Retry after failure is a separate check. Those paths must stop the current stream, keep or handle the partial transfer, and then resume according to existing Flow semantics. Reusing a connection must never turn an explicit stop by the user into a transfer that silently carries on.

Looking back, the Desktop `(NodeId, ALPN)` cache was correct from the start. What cancelled it out was the old Android logic that rebuilt the Endpoint for every photo. Neither the unit tests nor "all five `CONFIRMED`" could see that layer. We found it because the daemon log showed five different provider NodeIds.
