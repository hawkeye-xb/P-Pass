---
title: "Android Battery Drain from Idle QUIC (iroh) Endpoints: 300mAh to 30mAh"
description: "Debugging background battery drain in an Android photo backup app: battery stats were empty, so we reconciled netstats traffic instead and found two idle iroh/QUIC endpoints. Daily battery use dropped from about 300mAh to under 30mAh."
date: 2026-10-13
tags: [engineering, Android, battery, iroh, QUIC]
lang: en
draft: false
---

P-Pass backs up the photos on your phone to a computer at home. Most of the time the phone app should sit in the background and do nothing, and wake only to upload new photos.

In late September we noticed heavy battery use on one of our own Android phones. On a normal day of use it synced 13 photos, and the system battery page in Settings showed P-Pass using about 300mAh. For an app that should be idle in the background, that is far too much.

## Why batterystats was empty

The first step was Android's batterystats, to split the drain into wakelocks, CPU and radio.

It came back empty. During our debugging session the phone was on a charger, and while charging, those per-app fields in batterystats stay blank. Unplugged runs needed someone babysitting the phone, and a few minutes of stats would not explain a whole day anyway.

Battery is hard to measure, so we looked at traffic. Android records background mobile data per app. How many photos were sent and how big they were is in the logs on the computer. The two can be checked against each other.

## The traffic did not add up

In the system's `netstats`, P-Pass used about 215MB of background mobile data on September 28 and about 192MB on the 29th.

Ten to fifteen photos a day at a few MB each comes nowhere near 200MB. The logs on the computer agreed: the phone had connected only a handful of times and sent only a few photos. The traffic was not photos.

We triggered a background wake on the phone by hand. The log showed the round ending quickly with `nothing to transfer`. But the process was not frozen, and P-Pass's traffic kept climbing, somewhere between 8 and 20MB an hour.

In logcat, two threads polled the routing table roughly every 20 seconds. They turned out to be the two endpoints described below. The intervals match iroh 1.0.3: it redoes STUN (asking a server for its public address) every 20 to 26 seconds and pings the relay every 15 seconds. A full network report, iroh's probe of the current network conditions, runs every 5 minutes.

## Two endpoints nobody closed

P-Pass uses iroh for transport, which runs on QUIC. When a direct connection is not possible, data goes through a relay server. The phone process has two iroh endpoints: a control channel that talks to the computer, and a provider that serves photo data to it.

Once the control channel's endpoint was bound, nothing in the codebase ever called `close()` on it. The provider was documented as opened once per process, and it bound its endpoint before checking whether there was anything to send.

Background wakes come from many places: a change in the photo library, boot, a fallback job every 5 hours, retry probes when the computer is unreachable. Any one of them brings both endpoints up. After that they stay open and keep talking to the relay on iroh's schedule, whether or not any photos are sent, until the system kills the process.

## The fix: close endpoints after 30 idle seconds

We made the endpoints follow actual need:

- Both endpoints now bind lazily, on first real use.
- A new reaper closes both endpoints when the app is not in the foreground, the backup round has finished, and 30 seconds have passed.
- If the computer is still pulling photos, the reaper backs off and retries every 30 seconds.
- If an endpoint is needed again after closing, it binds again and the timer starts over.

Lazy binding caused one problem with the provider. On the emulator with 300ms of added network latency, the first photo failed once and only succeeded after the endpoint was torn down and rebound. So the provider is now bound ahead of time, right before the phone probes the computer. The phone only probes when it has photos to send, so this never opens a connection while idle.

In the same period we also fixed a retry backoff. When the phone cannot reach the computer, it schedules a few probes to try again later. The old probes ran every 10 minutes, and if the failure happened after a transfer had started, there was no limit. With the computer gone, the phone woke up every 10 minutes indefinitely.

Now one outage gets one set of probes, spaced 10, 20, 40 and 80 minutes apart, about two and a half hours in total, after which the 5-hour fallback job takes over. The set is cleared only when a transfer actually succeeds, and the next outage gets a fresh set.

## Measuring traffic before and after

On the emulator, against the same test desktop, we recorded the app's traffic every 30 seconds for 6 minutes after sending it to the background.

| | Traffic over 6 minutes | Log |
|---|---|---|
| Before | 695KB in, 562KB out, still climbing, about 12.6MB/hour | none |
| After | 0KB | `network idle for 30000ms in background: endpoints parked` |

Then on the same phone, with a release-signed test build on 5G, we swiped the app away from recents and locked the screen.

- A background wake with no new photos logged `nothing to transfer`. Thirty seconds later both endpoints closed, and traffic stayed at 0 for the next several minutes.
- After taking a photo, the app woke within a second, sent it to the Mac, and closed the endpoints again 30 seconds later.

In those 30 seconds before closing, there were still a few hundred KB of traffic. We later traced it to iroh itself connecting to the relay and running network reports. It did not show up in the app logs at the time because the Rust layer's logs were not wired into logcat yet. They are now.

## Results: daily battery use under 30mAh

Same phone, mobile data allowed, about ten new photos a day. The system battery page shows P-Pass using under 30mAh a day.

That is the combined result of the changes above. We did not measure them one at a time, so we cannot say how much each one saved. With nothing to send, the phone now goes network-silent 30 seconds after each wake.
