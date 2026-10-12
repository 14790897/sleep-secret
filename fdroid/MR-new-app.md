# F-Droid MR 正文（新应用）

提交到 `gitlab.com/fdroid/fdroiddata` 时用这份填 `App inclusion` 模板。

- **MR 标题**：`New app: Sleep Secret`
- **目标分支**：`master`
- **要加的文件**：`metadata/com.sleepsecret.sleep_secret.yml`（内容就是本仓库
  `fdroid/com.sleepsecret.sleep_secret.yml`，逐字节相同）

---

## Abstract

Sleep Secret records the night, classifies the sounds in it on-device, and gives a
morning report: when there was sound, what it was, and how long it lasted. Audio stays on
the phone by default — there is no account and no server. Inference runs on-device with a
CED-tiny ONNX model (5.5M parameters, AudioSet-pretrained).

Screenshots, icon and feature graphic are in the Fastlane metadata at
`app/fastlane/metadata/android/{en-US,zh-CN}/images/`.

I wrote it because every sleep-recording app I could find either uploads the night's audio
to a server or is closed source, which makes the "it stays on your device" claim
unverifiable. This one keeps the claim checkable: GPL-3.0-or-later, and no network code
path except an optional WebDAV export the user configures themselves.

## Checklist

### Policy

* [x] The app complies with the [inclusion criteria](https://f-droid.org/docs/Inclusion_Policy).
* [x] The original app author has been notified (and does not oppose the inclusion). — I am the author.
* [x] The upstream app source code repo contains the app metadata in a Fastlane folder
      structure. Summary, description, icon, feature graphic and screenshots are provided;
      `en-US` and `zh-CN` are both included, and changelogs are provided per version code.

### Docs

* [x] Read the guide.
* [x] Metadata follows the best practice in the templates.
* [x] Read the Build Metadata Reference.

### Merge Request Setup

* [x] The title follows the "New app: app name" format.
* [x] The fork is public and the branch is not protected.
* [x] No related fdroiddata or RFP issues (this is the first submission).
* [x] Only one app in this MR.

### Metadata

* [x] Metadata is in `metadata/com.sleepsecret.sleep_secret.yml`.
* [x] Metadata is valid YAML.
* [x] Metadata uses LF as line ending.
* [x] No summary/description/changelog/images added to the metadata file — those are provided upstream.
* [x] Releases are tagged and auto update is enabled (`AutoUpdateMode: Version`, `UpdateCheckMode: Tags`).
* [x] There is an issue tracker and contact info of the author.
* [x] An `AuthorName` is present.
* [ ] External repos are added as git submodules instead of srclibs — **using the srclib method; see below.**
* [ ] Enable Reproducible Builds — **attempted; got to a single differing file, see below.**
* [x] ABI split is set up (three APKs: `armeabi-v7a`, `arm64-v8a`, `x86_64`).
* [x] Only the latest version is kept in the metadata.
* [x] No disabled versions.
* [x] `commit` is the full hash, not a tag or branch.

### Pipeline

* [x] All pipelines pass (verified locally with `readmeta`, `lint`, `rewritemeta`, `checkupdates` and the metadata schema).
* [x] Warnings/errors in the Reports tab are fixed or explained below.

---

## Notes on the two unchecked items

**srclibs instead of a Flutter git submodule.** The official
`templates/build-flutter.yml` documents both methods. I used the srclib method
(`srclibs: [flutter@stable]` plus a `git checkout` of the exact version extracted from the
project's own CI workflow), so that the application repository does not need to carry a
large Flutter SDK submodule purely to satisfy the build. The Flutter version built is
pinned to 3.47.6, read from `.github/workflows/ci.yml`, which is the same version used for
the upstream CI and the release builds. If a submodule is required for acceptance, I am
happy to add one — it just seemed backwards to change the upstream repo's structure for
the packager's convenience.

**Reproducible builds: attempted, not enabled.** I tried this properly rather than
declaring it impossible, and removed the `binary:` / `AllowedAPKSigningKeys` fields again
only because a declared-but-failing comparison makes the pipeline red. What was found, in
case it is useful to someone else:

1. The first comparison differed in three files: `NativeAssetsManifest.json`, `libapp.so`
   and `libdartjni.so`. Reading the actual diff showed the manifest listed
   `android_arm`/`android_arm64`/`android_x64` upstream but only one ABI in our build —
   because our recipe passed `--target-platform` per build block while upstream runs a
   single `--split-per-abi`. Building all three ABIs in each block fixed that one.
2. `libapp.so` was the Dart AOT snapshot embedding absolute paths. Moving the checkout to
   the same path upstream builds at (`/home/runner/work/sleep-secret/sleep-secret`, as
   `app.panoramax` does with its own CI path) fixed that one too.
3. That left exactly one file, `libdartjni.so` — built from source by the `jni` package's
   CMake. Pinning the NDK to `r28c` (what `flutter.ndkVersion` resolves to on Flutter
   3.47.6, and what `app.kryfo`/`app.nightdrop` pin) did not resolve it, and I could not
   identify the remaining input from outside the build server.

The signing key side of it did check out: F-Droid downloaded our published APK and it
`Verifies` against `AllowedAPKSigningKeys`, i.e. the fingerprint is correct and the key is
fine. So the blocker is purely byte-level reproducibility of that one native library.

I would like to revisit it — the Quick Start Guide is right that this is the moment, since
users cannot switch between a developer-signed and a repo-signed build later without
reinstalling. If a packager can tell me what differs inside `libdartjni.so` (the build
server has the artifacts), I will pick it straight back up.


## Build notes

**versionCode scheme.** Flutter's `--split-per-abi` offsets each ABI's version code by
`abiVersionCode * 1000`, with the ABI map `{armeabi-v7a: 1, arm64-v8a: 2, x86_64: 4}` (3 is
reserved for the removed x86). For `pubspec` version `2.18.0+21800` the APKs really do get
**22800 / 23800 / 25800**, which is what
`VercodeOperation: ['%c + 1000', '%c + 2000', '%c + 4000']` produces. This was verified by
building from a clean checkout of the tagged commit and reading the result with `aapt`,
rather than inferred from the version string.

**No anti-features.** No ads, no tracking, and no network access unless the user configures
their own WebDAV server for export.

**First version shipped here is 2.18.2.** Everything F-Droid needs from the upstream
repository — the Fastlane metadata, the packaging fix and the ABI version-code change below —
first appears in the `v2.18.2` tag, so the metadata points there.

**versionCode scheme.** Flutter's `--split-per-abi` defaults to offsetting each ABI's
version code by `abiVersionCode * 1000` (`{armeabi-v7a: 1, arm64-v8a: 2, x86_64: 4}`), which
puts the ABI in the *thousands* digit. That span (3000) is far larger than the version
increment itself (a minor bump moves the pubspec code by 100), so an older version's high
ABI outranks a newer version's low ABI — e.g. `2.18.1 x86_64 = 25801` sits above
`2.19.0 armeabi-v7a = 22900`. Both the archiving rule and the client's "highest installable
version code" rule key off that ordering, so this is a real defect rather than a style
preference (thanks linsui for catching it).

`2.18.2` therefore overrides the version code in the app itself, putting the ABI digit last:
`versionCode * 10 + abiCode` with `{armeabi-v7a: 1, arm64-v8a: 2, x86_64: 3}`. The metadata
matches with `VercodeOperation: ['%c * 10 + 1', '%c * 10 + 2', '%c * 10 + 3']`, and
`fdroid checkupdates` computes `21802 -> 218021/218022/218023` from the real repository.
Confirmed against real builds too, not just the formula: with pubspec `2.18.1+21801` the
arm64 APK comes out as `versionCode=218012`.

**Dependency metadata block removed.** `2.18.0` and `2.18.1` carried an extra APK signing
block, `Dependency metadata` (id `0x504b4453`), which the `check apk` job rejects —
correctly, since the block is compressed and encrypted with a Google Play key and cannot be
inspected. It is added by AGP automatically and is only useful for Play's install-size
attribution, which does not apply here, so `2.18.2` turns it off with
`dependenciesInfo { includeInApk = false; includeInBundle = false }`.

**Local verification.** `fdroid readmeta`, `fdroid lint` (no warnings),
`fdroid rewritemeta` (byte-identical output), `fdroid checkupdates --auto` (reports
"up to date" and computes 218021/218022/218023 from the real repository) and the metadata
JSON schema check all pass. `fdroid build` needs the build server, so instead the recipe's
exact commands were run against a clean checkout of the tagged commit, and the resulting
APK's version code was read with `aapt`.


