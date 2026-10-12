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
* [ ] Enable Reproducible Builds — **not enabled for this first version; see below.**
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

**Reproducible builds are not enabled.** I did not attempt to match the upstream build
paths in this first version, so the APK will be signed with F-Droid's key, and I understand
that this cannot be changed later without a key change. I would rather have the recipe
reviewed first and revisit reproducibility as a separate change; a large part of the
obstacle is the Flutter toolchain's own path handling.

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

**First version shipped here is 2.18.1.** Everything F-Droid needs from the upstream
repository — the Fastlane metadata and the packaging fix below — first appears in the
`v2.18.1` tag, so the metadata points there rather than at `v2.18.0`.

**Dependency metadata block removed.** `2.18.0` (and every release built with the current
Android Gradle Plugin) carried an extra APK signing block, `Dependency metadata`
(id `0x504b4453`), which the `check apk` job rejects — correctly, since the block is
compressed and encrypted with a Google Play key and cannot be inspected. It is added by AGP
automatically and is only useful for Play's install-size attribution, which does not apply
here, so `2.18.1` turns it off with `dependenciesInfo { includeInApk = false;
includeInBundle = false }`. Verified with a red/green comparison against fdroidserver's own
list of forbidden block IDs: the 2.18.0 build has three signing blocks including the
forbidden one, the 2.18.1 build has two and neither is forbidden.

**Local verification.** `fdroid readmeta`, `fdroid lint` (no warnings),
`fdroid rewritemeta` (byte-identical output), `fdroid checkupdates --auto` (reports
"up to date" and computes 22801/23801/25801 from the real repository) and the metadata JSON
schema check all pass. `fdroid build` needs the build server, so instead the recipe's exact
commands were run against a clean checkout of the tagged commit: `flutter pub get
--enforce-lockfile` and `flutter build apk --release --split-per-abi
--target-platform=android-arm64` both succeed and produce the APK at the path given in
`output:`, with `versionCode=23801`.

