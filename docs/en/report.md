# Reading the report

Every number in the report comes from the model's judgement of 3-second windows and
nothing else. This page explains how each one is computed, and **what cannot be
concluded from it**.

## Snore index

> snoring time ÷ analysed time × 100%

A single number for comparing night to night. It only counts time classified as the
snoring category — breathing, coughing and ambient noise are excluded.

## Sleep sound score

Starts at 100 and deducts, four items in total:

| Item | Max | Full deduction when |
|---|---|---|
| Snore ratio | 60 | snoring reaches **25%** of the night |
| Snore continuity | 15 | 100% of snoring time is in stretches over 2 minutes |
| Disturbances | 15 | coughing / sleep talk / movement reaches **20 per hour** |
| Ambient noise | 10 | ambient sound reaches **40%** of the night |

Where the total lands:

| Score | Grade |
|---|---|
| 85 – 100 | Very quiet |
| 70 – 84 | Fairly quiet |
| 55 – 69 | Some noise |
| 35 – 54 | Notable snoring |
| 0 – 34 | Heavy snoring |

Nights shorter than **90 minutes** are not scored at all — a "night score" computed
from a short recording is not worth showing.

!!! warning "This score measures how noisy the night was, not how well you slept"

    Sleep staging (deep / light / REM) and awakenings need an accelerometer or heart
    rate; a microphone cannot see them. A quiet night that you slept badly through
    still scores high here.

It deducts rather than averages because an average bottoms out around 40 for a night
of nothing but snoring: the other three items score full marks for lack of other
sounds, flattering heavy snoring. Deducting from 100 has no such problem, and you can
check the arithmetic yourself: `100 − 60 − 15 = 25`.

## Possible apnoea signals

This section has exactly one sound in it: the **gasp**.

It is not apnoea detection. It does one thing only: shows the gasps the model
**actually recognised**, with a timestamp and playback, and does no inference
about their timing.

!!! danger ""Hearing a sound" is not "finding a condition""

    A few gasps in a night may mean nothing, or may mean the airway was working.
    A microphone cannot tell those apart. Deciding whether it is apnoea requires a
    sleep study (oxygen saturation, airflow, chest and abdomen effort), not a
    recording. If you snore heavily, have woken up choking, or are sleepy during
    the day, take the report to a doctor.

    **The model also reads "heavy breathing" as a gasp** (measured at 0.68–0.89),
    so this section is not specifically the gasp that follows an apnoea.

### Why only the gasp

On 2026-10-07 five candidates were tested against CC0 audio, using exactly the same
criterion as the app (argmax of 527 dimensions, score ≥ 0.5 — the app's own bar is
0.25):

| Wanted label | Clips tried | Passed | What the model actually said |
|---|---|---|---|
| `Gasp` | 4 | **1** | Gasp |
| `Wheeze` | 37 | 0 | Screaming / Groan / Cough / Throat clearing |
| `Pant` | 40 | 0 | **Gasp** / Breathing / Groan |
| `Snort` | 40 | 0 | Oink / Sneeze / Horse / Fart |

This does not prove the model cannot recognise them: the clips were searched from
public-domain material, and "Wheeze 1.mp3" is often not a wheeze at all. The accurate
statement is **they could not be demonstrated on the CC0 material that was findable**.

But "could not be demonstrated" was enough to decide. This section tells the user
which sounds we are watching for; listing one we cannot demonstrate would lend
credibility to a "nothing detected" that it has not earned.

### Records from before the upgrade say "not collected"

This section needs an AudioSet label stored on each event, which older versions did
not record. So old reports show it empty — but empty for a different reason than
"nothing was recognised that night". The UI says which. Without that distinction you
could take a report that has **no data** as evidence that you are fine.

## Detailed view

That row on the report opens the **raw AudioSet labels** the model produced, sorted by
count, with a Chinese translation, the category each maps into, and its share.

| Column | Meaning |
|---|---|
| Count | Windows in which that label won (one window = 3 seconds) |
| Label | The model's own words |
| Category | Which category we map it into |
| Unmapped | Only 47 of the 527 labels are mapped; the rest belong to no category |

Its purpose is **assigning blame**: when something in the report looks off, this page
tells you whether the **model was wrong** (the raw label is absurd) or whether
**we mapped it wrong** (right label, wrong category).

The "unmapped" column is the one to watch: windows where those labels won produce no
event at all and appear nowhere else in the report — this page is the only place they show up.

!!! note "This page is what the model said, not a conclusion"

    A label that maps to no category is not thereby unimportant, and one that does
    map somewhere was not thereby judged correctly.

## The nine categories

| Category | Roughly includes |
|---|---|
| Snoring | Snoring, snort, sniff |
| Breathing | Breathing, wheeze, gasp, sigh, pant |
| Coughing | Cough, throat clearing |
| Sneezing | Sneeze |
| Sleep talk | Speech, whispering, laughter, crying, groaning |
| Movement | Rustling, paper, tapping, clicking |
| Ambient noise | Environmental noise, white noise, traffic, wind, rain, door, music |
| Appliance noise | Fans, air conditioning, motors, charger hum, wind noise |
| Silence | Quiet windows |

Appliance noise is split out for one reason: **false positives**. The low-frequency hum
of a fan or air conditioner looks very much like snoring in the spectrum and is the
biggest source of snoring false positives. Mixed into "ambient noise", the interface
could only say "there was ambient noise" — never the sentence that matters, "that was
the fan, not you".

## The other charts

- **The night in sound**: a timeline. Taller bars are more prominent events (snoring
  highest, breathing and ambient lowest).
- **Hourly distribution**: hour of the night against total sound duration in that hour.
- **Snore durations**: how long each snoring stretch was, bucketed from under 15
  seconds to over 5 minutes.
- **All events**: time, category and confidence for every event, playable where a clip
  exists. Low-confidence ones are marked — a 0.93 snore and a 0.21 snore should not
  look alike.
