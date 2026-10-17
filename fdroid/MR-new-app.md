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
* [x] Enable Reproducible Builds — the build server confirms the output matches our signed APKs byte-for-byte.
* [x] ABI split is set up (three APKs: `armeabi-v7a`, `arm64-v8a`, `x86_64`).
* [x] Only the latest version is kept in the metadata.
* [x] No disabled versions.
* [x] `commit` is the full hash, not a tag or branch.

### Pipeline

* [x] All pipelines pass (verified locally with `readmeta`, `lint`, `rewritemeta`, `checkupdates` and the metadata schema).
* [x] Warnings/errors in the Reports tab are fixed or explained below.

---

## Note on the remaining unchecked item

**srclibs instead of a Flutter git submodule.** The official
`templates/build-flutter.yml` documents both methods. I used the srclib method
(`srclibs: [flutter@stable]` plus a `git checkout` of the exact version extracted from the
project's own CI workflow), so that the application repository does not need to carry a
large Flutter SDK submodule purely to satisfy the build. The Flutter version built is
pinned to 3.47.6, read from `.github/workflows/ci.yml`, which is the same version used for
the upstream CI and the release builds. If a submodule is required for acceptance, I am
happy to add one — it just seemed backwards to change the upstream repo's structure for
the packager's convenience.

**Reproducible builds: done, and the build server confirms it byte-for-byte.** The pipeline's
`fdroid build` job now reports `compared built binary to supplied reference binary successfully`
for all three ABIs, with both the supplied and the signature-copied APKs verifying against
`AllowedAPKSigningKeys`. So F-Droid will publish our own signed APKs and users can move between
the GitHub and F-Droid builds without reinstalling.

Getting there took three changes, each fixing one observed difference (they are recorded here
because the first two are non-obvious for Flutter apps):

1. **Build all ABIs in one invocation** (no `--target-platform` per build block). Upstream runs a
   single `--split-per-abi`; building one ABI at a time makes `NativeAssetsManifest.json` list
   only that ABI, so the file can never match.
2. **Build from the same absolute path as upstream** (`/home/runner/work/sleep-secret/sleep-secret`).
   The Dart AOT snapshot (`libapp.so`) embeds the build path. This is the `mv` dance in `prebuild`/
   `build`.
3. **Clear the ELF build ID before packaging.** After the first two, the only remaining difference
   was `libdartjni.so`: same size, and identical everywhere except the 20-byte
   `.note.gnu.build-id`. That value is a hash over the link inputs, so it moves with the toolchain
   path. Passing `-Wl,--build-id=none`, `-ffile-prefix-map` or `-fdebug-compilation-dir` did not
   work — the NDK driver appends its own `--build-id=sha1` after the user flags. The app's Gradle
   file therefore zeroes the ID in every `.so` right before packaging, so both sides produce the
   same bytes regardless of where or with which toolchain path they were built. Verified locally
   first: building the same source in two directories gave byte-identical libraries.

**Local verification.** `fdroid readmeta`, `fdroid lint` (no warnings),
`fdroid rewritemeta` (byte-identical output), `fdroid checkupdates --auto` (reports
"up to date" and computes 219001/219002/219003 from the real repository) and the metadata
JSON schema check all pass. `fdroid build` needs the build server, so instead the recipe's
exact commands were run against a clean checkout of the tagged commit, and the resulting
APK's version code was read with `aapt`.


