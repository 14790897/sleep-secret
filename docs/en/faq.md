# FAQ

## There's no record of last night

The usual cause is **the system killed the app** in the small hours — not a crash,
just the battery manager deciding it had to go.

In Android's Settings → Apps → Sleep Secret, check three things: battery policy set
to **unrestricted**, **autostart** allowed, and the app **locked** in the recent-apps
list. Grant notification permission too — an app with no persistent notification is
a likelier target for background cleanup.

## There is a record, but it's nearly all "Ambient noise"

Check the **input level** on the recording screen: if it was low all night, the phone
was probably covered by bedding or pillow, or too far away. Put it by your pillow,
screen up, nothing on top.

The "Recording quality" section of the report says so directly when that is what happened.

## The report says the snore ratio is abnormally high

Real snoring usually runs 10–40% of a night. Above half often means **a continuous
low-frequency noise was classified as snoring** — fans, air conditioning and
dehumidifiers are the usual culprits. If you really did snore all night, ignore this;
otherwise look at the appliances nearby.

Those sounds are now mostly reported separately as "Appliance noise", but the boundary
cannot be perfect.

## The score is high, but I slept badly

The score **only listens**: snoring, how continuous it was, how often you were
disturbed, ambient noise. It says nothing about your sleep stages or how often you
woke — those need movement or heart rate, which a microphone cannot see.

A quiet night you slept badly through still scores high. Conversely, a night with a
blocked nose costs a few points. Read it as "how noisy was this night", not as sleep quality.

## Why is there no deep / light / REM sleep

Those need EEG, eye movement or heart rate — or at least an accelerometer.
**Audio alone cannot do it.** Rather than show a number that sounds scientific but is
really a guess, the app shows nothing.

## Can it detect sleep apnoea?

**No.**

All it can do is show the **gasps** the model recognised overnight, with timestamps and
playback. "Hearing a sound" is not "finding a condition": a few gasps may mean nothing,
or may mean the airway was working, and a microphone cannot tell those apart.

Judging whether it is apnoea needs a sleep study (oxygen saturation, airflow, chest and
abdomen effort). If you snore heavily, have woken up choking, or are sleepy during the
day, take the report to a doctor.

See [Possible apnoea signals](report.md#possible-apnoea-signals).

## How much battery does a night use? Can I charge while recording?

Charging while recording is fine.

Measured: on a Redmi K80, 6.5 hours recording with the screen off used **9%** of the
battery (default settings). That is roughly 14% for ten hours — no need for mains power.

⚠️ One phone, one night. Other models, other ROMs and the clip setting can all change it.

## Why is a snore clip only 20 seconds long?

Very long snoring stretches keep only their **most representative segment**, taken
backwards from the end — a five-minute snore stored in full would be a multi-megabyte
file for no reason. The event's duration in the report is complete; only the audio you
play back is trimmed.

## How do I move my history to a new phone?

*About* → *Export data*. Export to a folder (a cloud-sync folder, or Nutstore / WebDAV),
then import on the new phone. Imports are de-duplicated by **start time**, so a night
never lands twice.

**Don't uninstall and reinstall to "clear data"** — that takes the history with it, and
there is no cloud backup to restore from.

## Is there an iPhone version?

No. Android only, plus a Windows desktop build for testing.

## Will it stay this limited?

Unknown. The app's boundaries are deliberately narrow: **it only reports what can be
verified.** The "Possible apnoea signals" section once had five candidates; only one
survived — the other four could not be shown to be recognisable on any public-domain
audio that was findable, and listing them would have lent a "nothing detected" a
credibility it had not earned.
