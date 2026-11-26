# Posture belt: recording how you lie

Sleep Secret currently has only a microphone: it can tell you how noisy a night was, but not whether you were on your back or your side. **SleepPosture** is a companion hardware prototype — an IMU worn on the sternum that streams four sleep postures over BLE.

![SleepPosture 3D visualizer](assets/images/posture-belt/web-app.png)

## Why posture

Snoring depends on body position: for many people it is worse supine and lighter on the side. Audio alone can say "this night was noisy", but not "it was noisier while you were on your back". Aligning a posture timeline with the sound timeline is what makes that comparison possible.

This is not a diagnosis. Positional OSA needs sleep monitoring (airflow, oxygen saturation, arousals); a belt alone cannot establish it.

## Hardware

| Item | Specification |
|---|---|
| Sensor | Sternal/upper-abdominal IMU (BMI220; BMI270 and LSM6DS3TR-C are drop-in alternatives) |
| MCU | ESP32-C3 SuperMini |
| Sampling and streaming | 50 Hz sampling, 25 Hz BLE notifications |
| Power | 500 mAh pouch cell + TP4056 charger + TPS63031 regulator |
| Carrier board | 30.7 × 50.8 mm, 1.0 mm two-layer PCB, four M2 mounting holes |
| Wearing | 35–40 mm elastic chest strap, component side facing out, `TOP` silkscreen towards the head |

![PCB](assets/images/posture-belt/pcb.jpg)
![Enclosure](assets/images/posture-belt/enclosure.jpg)

## Posture classes

The firmware runs a gravity-vector threshold plus a hysteresis state machine on the device:

- Supine / prone / left lateral / right lateral
- Moving / turning
- Unknown

Classification is based on **torso orientation**, not head orientation. The head can rotate relative to the torso; a headband would classify "lying on the side with the head turned towards the ceiling" as supine. That is why the sensor sits on the sternum, not on the head.

Snoring is not only about the torso: head rotation and neck flexion/extension also change the upper airway. But the supine/lateral axis refers to the torso; a headband can measure head rotation, not torso position. Studying both at once would need two sensors — one on the chest and one on the head.

## Where it stands

| Module | Status |
|---|---|
| Hardware | First board hand-assembled and powered; Gerber / BOM / CPL ready to order; charging, enclosure and all-night capture not yet validated |
| Firmware | Auto-detects BMI220 / BMI270 / LSM6DS3TR-C; 50 Hz sampling with stable 25 Hz BLE |
| Web | Direct Web Bluetooth connection with live 3D rendering; deployed |
| Validation | Flat/supine 99%; prone / left / right four-point test and all-night test not yet run |

> This is a personal sleep-research prototype, not a medical device. Do not use it to diagnose or treat any condition.

## Relationship to Sleep Secret

**It is not connected to the app yet.** The next step is to bring the belt in over BLE, record posture alongside audio, and add a body-position timeline to the report. Until that happens there is no posture data in this page or in the app — do not mistake this prototype for a shipped feature.

## Links

- Hardware project: <https://github.com/14790897/sleep-posture>
- Live 3D demo: <https://sleep-posture-3d.vercel.app>
- BLE protocol: <https://github.com/14790897/sleep-posture/blob/main/protocol/ble-protocol.md>
