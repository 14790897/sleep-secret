# Guide

## Installing

Download the latest APK from
[Releases](https://github.com/14790897/sleep-secret/releases):

| File | For |
|---|---|
| `app-arm64-v8a-release.apk` | **Almost every phone.** Pick this if unsure |
| `app-armeabi-v7a-release.apk` | Older 32-bit devices |
| `app-x86_64-release.apk` | Emulators |

The app is not on any app store, so Android will ask you to allow installing
from unknown sources. The APKs are split per CPU architecture for size: one
universal APK would be about 140 MB, each split is about 50 MB.

The Windows build is in the same release, but it is **for testing only** —
desktop has no foreground-service keep-alive, so overnight recording requires
mains power and a power plan that never sleeps.

## First launch: three things

!!! tip "Skip these and you will probably get an empty report tomorrow"

### 1. Allow microphone access

Without it the app cannot do anything at all.

### 2. Allow notifications — don't skip this one

A persistent notification shows while recording. Denying notifications does not
stop the recording itself, but **the system is much more likely to kill the app
during background cleanup**:

> Notification permission denied. No persistent notification will be shown while
> recording. Recording itself is unaffected, but the system is more likely to
> kill the app during background cleanup.

### 3. Set the battery policy to "unrestricted"

Xiaomi, Huawei and similar Android skins are aggressive about background apps.
Besides the battery policy you usually also need to:

- allow **autostart**
- **lock** the app in the recent-apps list (so "clear all" doesn't kill it)
- exclude it from battery optimisation

Without this, the phone may kill your recording in the small hours. The app itself
has no way to prevent that.

## How a night goes

1. **Before bed**: on the *Sleep* tab, tap the big button to start recording.
2. **Overnight**: you can turn the screen off. A persistent notification stays in
   the shade. If you want to check the microphone is working, the level meter is
   on the recording screen. Put the phone by your pillow, screen up, nothing on top.
3. **In the morning**: tap the button again to stop. The analysis is generated
   automatically and appears on the *Reports* tab.

## The numbers on the recording screen

| Label | Meaning |
|---|---|
| Windows processed | How many 3-second analysis windows were cut |
| Sent to model | How many of them were actually run through the model |
| Skipped | Skipped by the energy gate (quiet stretches) |
| Input level | Current and peak level — use it to check the mic isn't covered |

!!! note "There is no detection threshold line by default"

    The app does **not** run energy gating by default: every window goes to the
    model, quiet ones included. That is a measured decision — gating's only real
    effect is saving compute; it was not filtering false positives, the model was.
    So "Skipped" stays at 0 and there is no red line on the level meter.

## "Audio clips"

On the *About* tab. On by default: a few MB of audio per night is written into the
app's private directory, and only snore events and high-risk signals (gasps) are
kept — sleep talk and coughing are not. Those events can be played back from the report.

Turn it off and the app writes no audio files at all, keeping only event timing and
category — which also means no playback in history.

!!! warning "With this on, exported files contain audio"

    That part of the export **is the sound itself**. If your export folder is inside
    a cloud-sync folder, it will be uploaded to the cloud. Turn the switch off first
    if that bothers you. See [Data & privacy](privacy.md).

## Moving your history to another device

*About* → *Export data*. You can export to a cloud-sync folder (your cloud client does
the syncing) or configure Nutstore / WebDAV and let the app upload by itself.

Imports are de-duplicated by **start time**, so the same night never lands twice:
export first, let the folder sync, then import on the new device.

## Updating

There is no auto-update. When a new version appears in
[Releases](https://github.com/14790897/sleep-secret/releases), download the APK for
your architecture and install it over the old one — **your history is kept**.

!!! danger "Don't uninstall to start over"

    Uninstalling takes the private database and audio clips with it, and
    **history cannot be recovered**. Export before switching phones.
