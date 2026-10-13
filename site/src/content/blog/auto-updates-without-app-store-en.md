---
title: "Auto-Updates Without an App Store: Tauri and Android APKs"
description: "Five rules from shipping signed auto-updates for a Tauri macOS app and a self-updating Android APK through GitHub Releases, without an app store."
date: 2026-10-13
tags: [engineering, release, auto-update, CI]
lang: en
draft: false
---

P-Pass is an open-source tool that backs up the photos and videos on your phone to your own computer. It has a macOS client and an Android client, and neither goes through an app store. New versions are published on GitHub Releases. The Mac app uses the Tauri updater and the Android app updates its own APK. Each client reads an update manifest we maintain, tells the user when a new version is out, and after they confirm, downloads it, verifies the signature and installs it.

Without an app store, hosting, version checks and update prompts are all on you. We spent a month on this pipeline, from 0.8.x through 0.9.0 to today's `v2026.10.x` releases, and what broke along the way became five rules. The goal: users only install what we signed, and a platform with no changes never shows an update prompt.

1. Version each platform separately and use the git tag as a batch number. A change that only touches Android should not ask Mac users to update.
2. Before changing the manifest format, ship a bridge release, then freeze the old format. A frozen manifest must point at files that are never overwritten, or its signatures stop matching.
3. Keep an ordered list of update sources and move on when one fails. If none of them answer, report "check failed".
4. Test signature verification with real production signatures, and actually run `apksigner` in CI. Our app once failed verification on every update attempt while its unit tests stayed green.
5. Make the release pipeline fail when an expected artifact is missing. We once shipped a release that Mac clients could not see, and the release page looked fine.

## Per-platform versioning with tauri-plugin-updater (rule 1)

At first both clients shared one version number. One batch of changes only touched Android. The Mac binary was byte-for-byte identical, but its version went up anyway, so Mac users were asked to update. On days when we shipped several releases, the same person got that prompt several times.

Our first idea was a flag in the manifest that told the unchanged platform to skip. The desktop client uses tauri-plugin-updater 2.10.1. In its source, the manifest has one version field at the top level. Each platform entry only has `url` and `signature`. The update decision is one line: `release.version > self.current_version`. There is nowhere to say "this platform has no update this time" without forking the plugin.

So we split versioning into two layers.

- The git tag is a batch number like `v2026.10.5`: year, month, and which batch of the month. A batch is one release that may carry new builds for one or both platforms. The number only moves forward. Users still see a single entry point on GitHub, and the latest release always contains both platforms.
- Each platform's own version lives in `release/versions.json`, and each client compares only against its own number. `androidVersionCode` is the integer Android's installer uses to decide which build is newer, and it only goes up.

```json
{
  "desktop": "0.9.7",
  "android": "0.9.12",
  "androidVersionCode": 65
}
```

The release pipeline decides which version must move based on which paths changed, and blocks the release if it did not:

| Changed paths | Version that must move |
|---|---|
| `apps/desktop/`, the Rust core in `crates/`, `Cargo.lock` and other code shipped in the desktop app | desktop |
| `apps/android/` | Android |
| only docs, the website, `.github/`, `tools/` | neither |

The check looks at paths only, not at what the change means. Editing a comment counts as a code change. We'd rather ship an unneeded release than skip a needed one.

One small trap: the second batch in a month is `v2026.10.2`, not `v2026.10.1-2`. In semver, `-2` is a pre-release suffix, so it sorts below `2026.10.1`. Anything in the pipeline that compares releases gets it wrong.

`v2026.10.5`, shipped on October 12, only fixed a first-launch issue on the Mac. The Mac went to 0.9.7, Android stayed at 0.9.12, and phones showed no update prompt.

## Changing the update manifest format: freeze the old one (rule 2)

A client already installed on someone's device has its manifest location and parsing logic baked into that version. When we change the format, it has no way of knowing.

We did it in three steps.

1. Before switching formats, ship a bridge release, 0.9.0: a version old clients can still read, which carries the new client code, with the same version on both platforms, so old clients can upgrade to it using the old format.
2. Freeze the old-format manifest from then on. Its content stays at 0.9.0.
3. New clients read per-platform manifests, one per platform: `manifest-android.json` and `manifest-macos.json`.

Skip step 1 and old clients break in one of two ways. Either they cannot parse the new format, every check fails, and they never get another update. Or the new top-level version is higher than theirs, so they prompt, install, still report the old version, and prompt again next time.

The `signature` in the manifest is computed over the file that `url` points to:

```json
{
  "version": "0.9.12",
  "platforms": {
    "android-arm64": {
      "url": "https://github.com/hawkeye-xb/P-Pass/releases/download/v2026.10.5/P-Pass_0.9.12_android.apk",
      "signature": "dW50cnVzdGVkIGNvbW1lbnQ6…",
      "sha256": "950f1f85…"
    }
  }
}
```

Early on, the frozen manifest's `url` pointed at `P-Pass-latest.apk`. That file was overwritten with every release, so as soon as the next one shipped, the signature in the frozen manifest no longer matched and the update failed. The frozen manifest now points at a versioned copy that is never overwritten. Manifests that are rewritten on every release can still point at a latest file, because the manifest and the package are replaced together.

## Update source fallback: "no answer" is not "up to date" (rule 3)

We used to have one source, GitHub Releases. When we tried updating from a phone on 5G, the download crawled. And if a client treats a failed check as "no new version", the user stays on an old build while the app says it is up to date. Swapping in a different single source would not fix that either, because any one source can go down. Clients already in the field also only know the GitHub URL, so it has to stay.

Clients now get an ordered list. On desktop it lives in the endpoints in `tauri.conf.json`:

```
https://p-pass-dl.hawkeye-xb.com/manifest-macos.json
https://github.com/hawkeye-xb/P-Pass/releases/latest/download/manifest-macos.json
```

The first is a mirror on Cloudflare R2 and the second is GitHub. The mirror holds the installers too, and its manifests point at them. The Android client walks the list the same way, and every case below has a test:

| What this source returned | What the client does |
|---|---|
| a newer version | prompt to update, stop |
| already up to date | stop, do not ask the next source |
| 404 | the mirror may be behind, ask the next source |
| content that does not parse | the mirror may be half-written, ask the next source |
| every source tried, at least one failure, no answer | report "check failed" |

Right after a release, the mirror can serve the previous manifest for a short while, so a client may see "up to date" until the mirror job finishes. That clears on its own once the mirror catches up. A failed check is different: the client only reports "up to date" when a source actually answered.

The mirror only carries stable releases. We also have a test channel that installs pre-release builds on test devices. While reviewing changes, we found that publishing a test build would make the mirror job treat it as the newest release and overwrite the stable package and manifest on the mirror. Test builds are signed with the same key, so verification would pass and stable users would be offered a test build. We caught it before it happened, and the mirror job now skips any tag containing `-test.`.

## minisign verification on Android: test with real signatures, run apksigner in CI (rule 4)

This happened in 0.8.x, before the versioning change. An update goes through two signature checks. Before installing, the Android app verifies the package with a built-in minisign public key. When the pipeline builds the APK, it confirms the APK was signed with the release certificate. Both checks had bugs.

First, the app. The first time we ran the full update flow on a phone was going from 0.8.1 to 0.8.2. The check, the prompt and the download all worked, and the last step said the package failed verification. Retrying gave the same result. The manifest's `signature` field holds the base64 of the whole `.minisig` file, which decodes to four lines of text. The app parsed it as a raw 74-byte structure, and when the length did not match it failed.

The unit tests had been green all along because their test vectors were built the same way the code read them. The fix put the actual signature from the live v0.8.2 manifest into the tests. We also verified it independently with Node's built-in crypto. Both were correct; the app was parsing the file wrong.

Then the pipeline. It used to decide whether the APK was signed by checking whether `app-release.apk` existed. That file exists even when the APK is unsigned, signed with a scheme the minimum Android version does not accept, or signed with the wrong certificate. Now it actually runs `apksigner`:

- `apksigner verify --min-sdk-version 26` must pass;
- the signer must be the release certificate;
- if `apksigner` cannot be found on the machine, that is a failure too.

We tried it on three packages. The real release build passed. An unsigned package and one re-signed with a debug certificate were both rejected.

## GitHub Actions release gates: a missing artifact fails the build (rule 5)

- The night we shipped the 0.9.0 bridge release, the desktop client updated and the phone did nothing. The job that syncs the mirror called a script from the repository, but that job had never checked out the repository. The installers were uploaded and none of the manifests were synced.
- After the next batch, Macs could not see the update. The macOS build had been cancelled, so the upload was skipped, and the manifest step saw no Mac artifact and skipped the Mac manifest as well.
- The batch after that uploaded the Android manifest with an empty signature. The signing step's condition was still looking for a file that was no longer produced, so the whole step was skipped.

Now a missing artifact, or an empty signature when the signing key is available, fails the pipeline outright. Here is the Mac artifact check, trimmed from `tools/release/compose-desktop.sh` (message paraphrased):

```bash
case "${PLATFORMS:-all}" in
  *macos*|*all*|"")
    [ -n "$MAC_UPD" ] || {
      echo "::error::this release should include a macOS update package but it is missing; refusing to publish a manifest without a Mac source"
      exit 1
    } ;;
esac
```

We also added a repair workflow. It takes the artifacts already attached to a published tag, regenerates and re-signs every manifest, and does not rebuild anything or move the tag. A broken release can be fixed in a few minutes.

Most of these problems only show up when a real tag is pushed. A GitHub Actions release event runs the workflow from the commit the tag points to. A local dry run and CI on pull requests never reach the branches that only run at release time. And a bug in the pipeline cannot be fixed by re-running an old tag.

The last step was to put the test channel on the same path as stable releases. Test builds now decide per platform whether to build, write per-platform manifests the same way, and the Mac test build updates in-app through the same plugin as the stable one. We shipped a test build that only changed Android. The pipeline built Android and skipped macOS. The Mac got no prompt, and the test phone updated in-app.

## Where the code is

P-Pass is open source, and everything above is in the [GitHub repository](https://github.com/hawkeye-xb/P-Pass).

- Per-platform version checks: `tools/check-version-bump.sh`, `tools/release/plan-builds.sh`
- Manifest generation: `tools/make-update-manifest.mjs`
- Release and manifest repair: `.github/workflows/release.yml`, `.github/workflows/repair-manifests.yml`
