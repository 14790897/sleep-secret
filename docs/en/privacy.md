# Data & privacy

The app's claim is that **audio stays on the device by default**. This page unpacks
that sentence: what exactly is stored, where, when anything leaves the phone, and
what the app **cannot** promise.

## By default, nothing leaves the device

- No account, no sign-in
- No server — this project has no backend and does not plan to have one
- No analytics, crash reporting or ad SDKs (check `app/pubspec.yaml` and see for yourself)
- All analysis happens on the phone, using a local ONNX model

The only place in the code that opens a network connection is the Nutstore / WebDAV
client you configure yourself. Never configured, never online.

## What is stored locally

A single SQLite database (`sleep_secret.db`) holding **analysis results**:

| Table | Contents |
|---|---|
| `sessions` | Start and end time, analysed duration, window counts (total / sent to model / skipped / low-confidence), event count, snoring duration, whether signal collection was active, raw label counts |
| `events` | Category, start second, duration, confidence, snore probability, loudest window level, and (for snoring and high-risk signals) the path to an audio clip |
| `settings` | The app's own settings |

**The night's raw audio is not stored.** Eight hours of 16 kHz mono is about 920 MB,
and storing it would be pointless anyway — "when was there sound, and what was it"
is fully captured by timestamps.

## Audio clips

Toggleable on the *About* tab. When on (the default):

- Only **snore events and high-risk signals** are written; sleep talk and coughing are not
- They live in the app's private directory:
  `<app data>/clips/<session start>/<start second>.wav`
- Other apps **cannot read** that directory (Android app-private storage)
- Deleting a night's record deletes its clips; uninstalling clears everything

A private directory rather than the gallery or public music folders, because sleep
recordings are sensitive: they should not sit where you might stumble across them,
and other apps should not be able to read them.

## The one exception: Nutstore / WebDAV

Under *About* → *Export data* you can enter a WebDAV address (for Nutstore:
`https://dav.jianguoyun.com/dav/`), and from then on **each night is uploaded after
recording finishes**.

- The destination is **your own** cloud storage. The data goes from your phone to
  that service over HTTPS; this project has no server in the middle.
- Use a Nutstore **app password** (web → Account → Security → Add app password),
  not your login password — an app password can be revoked separately.

!!! warning "Where the credentials live, and what that does not guarantee"

    Address, username and password are stored in the app's private database (the same
    one as your sleep data). **It is not encrypted storage**: other apps on a
    non-rooted phone cannot read it, but **anyone who obtains the database file can**.

    That is exactly why you should use a revocable app password. If that is not good
    enough for you, skip WebDAV and use the cloud-sync-folder export below — that way
    the app never touches your cloud credentials at all.

## The other option: export to a cloud-sync folder

Instead of WebDAV, point the export directory at an iCloud / OneDrive / Nutstore
local folder. In that mode **the app never goes online**; your cloud client syncs
those files.

The contents are the same either way: one JSON per night (event timings, categories,
confidence, nightly statistics) plus the audio clips (WAV) — **that part is the
sound itself**.

## What the permissions are for

| Permission | Used for |
|---|---|
| Microphone | Recording all night. Without it the app does nothing |
| Notifications | The persistent notification during recording; denying it does not stop recording but makes the app easier for the system to kill |
| Foreground service (microphone) | Keeps recording alive in the background instead of being reclaimed |

No storage permission is requested — export folders are granted through the system
file picker, and the app can only reach the folder you picked.
