---
title: Android content triggers without gaps, using JobScheduler instead of WorkManager
description: "Burst shots were only partly backed up because Android content triggers fire once. Why our own queue dropped photos and JobScheduler did not."
date: 2026-08-19
tags: [engineering, android, debugging]
lang: en
draft: false
---

The P-Pass phone app has a simple job: when you take a photo, it gets copied to the computer at home.

How does the app know you took a photo? Android has a mechanism called a content trigger. You tell the system which content URI you care about (the photo library, in our case), and when that content changes, the system wakes up your job. There is no polling and no long-running service, so it is cheap on battery. We had been using it from the start.

Then a user reported a bug: **during burst shooting, the first few photos were backed up and the rest were not.**

## A patch that looked reasonable

The cause was easy to find. A content trigger fires once. After the system wakes you, that observer is used up, and you have to register a new one.

Our job was doing two things at once. It was the observer that got woken up, and it was also the worker that ran the backup. So the timeline looked like this:

```
photo taken → job wakes up → observer consumed, backup starts
                                  ↓
                        backup runs for 2 minutes   ← no observer during these 2 minutes
                                  ↓
                        backup finishes, observer re-registered
```

For as long as the backup ran, nothing was watching the photo library. The second half of a burst landed right in that gap.

So we wrote a patch. It cut the re-registration delay from 15 seconds to 1 second, and added a fallback: if the previous run found photos, do one extra scan afterward. The gap got smaller and there was a way to catch up. Tests passed, and we reported it as fixed.

The user replied with one sentence:

> "Making the decision based on timing isn't really appropriate."

They were right. We had made the gap shorter, but the gap was still there, and you can take a photo in one second. The "extra scan only if the previous run found photos" condition was worse. If a wakeup came from a messaging app saving an image (we don't back up that app's folder), the scan would come back empty, no extra scan would happen, and a photo you actually took during that window would wait five hours.

The patch rested on two guesses: that nobody takes a photo within one second, and that an empty previous scan means the next one has nothing to catch up on. Both guesses fail in practice.

## The user suggested a different model

After a few rounds of back-and-forth, the user lost patience:

> "Can't we just model this on the Node or JS event loop? An event comes in, we finish handling it, then we release. Wouldn't that work?"

Our first instinct was to explain why that was impossible. The observer fires once, so re-registering means giving up the current one, and the current one is in the middle of uploading photos.

Before writing that explanation, we went back to the AOSP source comments. Here is the documentation for `JobInfo.Builder#addTriggerContentUri`, read word by word:

> To continually monitor for content changes, you need to schedule a new JobInfo using the same job ID and observing the same URIs in place of calling `jobFinished()`. […] Following this pattern will ensure you do not lose any content changes: while your job is running, the system will continue monitoring for content changes, and propagate any changes it sees over to the next job you schedule, so you do not have to worry about missing new changes.

That describes the same model the user had just proposed:

- The system is the event queue. It keeps collecting and never stops.
- We are the worker. When an event arrives, we handle it.
- When we're done, we call `schedule(same job ID)` instead of `jobFinished()`. That call is the "release."
- At the moment of release, the system hands the new job every change it collected while we were working.

The gap is zero, so there is no need for a catch-up scan or for guessing at timing.

We had spent several hours building a leaky queue outside the system, when the system already had a working one inside it.

## Why we weren't getting this behavior

One phrase in that documentation carries the weight: same job ID. The system hands pending changes over by matching on job ID.

We had WorkManager (Android's official job scheduling library) sitting in between. Its `REPLACE` policy creates a new work record each time, and the underlying job ID changes with it. Once the ID changes, the changes the system collected have nowhere to go, and they are dropped along with the old job.

WorkManager handles retries, backoff, constraints, and promotion to a foreground service for us, and all of that is worth having. It also hid this capability from us.

So the fix was to move only the observer out of WorkManager and use JobScheduler directly, with the job ID hard-coded as a constant. The backup itself stays in WorkManager, with not a single line changed.

## After the change

The observer job now does two things when it wakes up, and takes under ten milliseconds:

```
onStartJob:
    1. dispatch: enqueue a backup job, hand it to WorkManager to run async
    2. release:  schedule(same job ID)
    return
```

The backup runs on its own. Whether it takes two minutes or twenty, the observer stays registered the whole time. If you keep taking photos during that time, the system keeps notifying us and we keep dispatching backup work.

Newly enqueued work waits in line. Dropping it would lose the event. Preempting the running job would interrupt a photo mid-upload. Running both in parallel would have two jobs scanning the same photos and uploading the same bytes twice. So the next job starts when the previous one finishes.

A lot of code went away with this: the whole re-registration mechanism, the catch-up logic, and three time constants that had been picked by trial and error. The file shrank by six thousand bytes, and no time constants are left in it.

## A worse bug we found along the way

While making the change, we came across this in the old code:

```kotlin
Constraints.Builder()
    .setRequiredNetworkType(UNMETERED)        // must be on Wi-Fi
    .setRequiresBatteryNotLow(true)           // battery must not be low
    .addContentUriTrigger(photoLibrary, true) // ...and the observer is attached here too
```

The constraints and the observer were attached to the same object. That means **when the phone is not on Wi-Fi, the trigger is never delivered.**

Say you spend a day out on 4G and take two hundred photos. We receive none of the photo library change notifications from that day. Connecting to Wi-Fi at home doesn't replay them either. The photos wait for the five-hour periodic fallback, or until you open the app.

This bug was much worse than the burst-shooting one, and nobody had ever reported it. Its symptom was "photos sync a little while after I get home," which looks completely normal.

Splitting the two fixed it as a side effect. The observer has no constraints and is always registered. The Wi-Fi and battery requirements moved to the backup job it dispatches. We learn about new photos immediately. Whether they can be uploaded right now is a separate question.

## What the new approach costs

A few lines further down in the same documentation: trigger URIs and `setPersisted` are mutually exclusive. In practice, **the observer job can't be persisted, so it disappears on every reboot.**

The platform enforces this, and there is no way around it.

Photos still don't get lost. Each backup run scans for everything added since the last successful backup, so we don't need the system to tell us which specific photos changed. A missed notification only delays the backup; the photos are still picked up on the next run. After a reboot, the periodic job starts the process and re-registers the observer as part of that.

What we lose is immediacy during that window. Getting it to zero would mean registering our own boot broadcast receiver: one more always-registered component in exchange for lower latency after a reboot. Whether that trade is worth it depends on how long the gap actually is, which we will measure on a real device before deciding.

We logged it as an open question instead of guessing.

## Two lessons

**First, read the primary documentation.** We wrote three versions of a fix for this problem, and the first two worked around the system from the outside. The real answer was in a source comment we should have read at the start. The AOSP source was already on our machines, and looking it up would have taken a few minutes.

**Second, before saying "that's impossible," figure out which layer it's impossible at.** What we originally wanted to explain was "the observer fires once, so continuous monitoring can't be done." That statement is true at the WorkManager layer and false at the JobScheduler layer. The user doesn't know these Android details, but they know what an event loop should look like, so they asked a question we thought had no answer.

The answer was in the documentation comment for `addTriggerContentUri`.
