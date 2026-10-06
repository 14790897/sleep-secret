#!/usr/bin/env bash
#
# 构建 release APK（按 ABI 分包），**并校验签名**。
#
#   scripts/build_release_apk.sh
#
# 由 semantic-release 的 prepareCmd 调用，跑在发布之前——
# 这样签名不对时能在 publish 之前就失败，不会发出一个装不上的包。
#
# ## 为什么按 ABI 分包
#
# 通用包含全部三种 ABI，约 140MB；分包后每个约 50MB。走流量下载差别很大。
# 代价是安装的人要选对架构——现代手机基本都是 arm64-v8a。
#
# ## 为什么非要校验签名
#
# 签名配置在 key.properties 缺失时会**静默退回 debug 签名**
# （见 app/android/app/build.gradle.kts）。那是个有意的降级——
# 保证 clone 下来就能构建——但对发版来说是灾难：
# debug 签名每个 CI runner 都不一样，用户装过 release 版之后
# 就再也覆盖安装不了新版，只能卸载重装，那会清掉所有睡眠历史。
# Gradle 不会为此报错，所以必须自己查。
set -euo pipefail

APK_DIR="app/build/app/outputs/flutter-apk"

echo "构建 release APK（按 ABI 分包）…"
(cd app && flutter build apk --release --split-per-abi)

# 三种 ABI 都要在。缺一个说明 Gradle 配置被动过。
EXPECTED=(
  "app-armeabi-v7a-release.apk"
  "app-arm64-v8a-release.apk"
  "app-x86_64-release.apk"
)
for f in "${EXPECTED[@]}"; do
  if [[ ! -f "$APK_DIR/$f" ]]; then
    echo "缺少 $APK_DIR/$f —— --split-per-abi 没生效？" >&2
    exit 1
  fi
done

if [[ -z "${EXPECTED_CERT_SHA256:-}" ]]; then
  echo "⚠️ 没有设置 EXPECTED_CERT_SHA256，跳过签名校验。" >&2
  echo "   发版流程里应当设置它——否则签名错了也没人知道。" >&2
  exit 0
fi

# 找 apksigner：优先用 SDK 的 build-tools，取版本号最大的那个
find_apksigner() {
  local candidates=()
  [[ -n "${ANDROID_HOME:-}" ]] && candidates+=("$ANDROID_HOME/build-tools")
  [[ -n "${ANDROID_SDK_ROOT:-}" ]] && candidates+=("$ANDROID_SDK_ROOT/build-tools")
  # 常见的默认安装位置。
  #
  # 本地开发时 ANDROID_HOME 往往没设，但 SDK 就在这些地方——
  # 漏了它们会导致**本地跑不了这个脚本**，而本地跑不了就意味着
  # 这道签名校验只在 CI 上生效、手改签名时没人拦得住。
  candidates+=(
    "$HOME/AppData/Local/Android/sdk/build-tools"  # Windows
    "$HOME/Library/Android/sdk/build-tools"        # macOS
    "$HOME/Android/Sdk/build-tools"                # Linux
    "/usr/local/lib/android/sdk/build-tools"       # GitHub 托管的 runner
  )
  local dir found name
  for dir in "${candidates[@]}"; do
    [[ -d "$dir" ]] || continue
    # Windows 的 build-tools 里只有 apksigner.bat，没有不带扩展名的 apksigner；
    # Linux/macOS 两个都有，要优先选不带扩展名的那个（.bat 在那边跑不了）。
    for name in apksigner apksigner.bat; do
      found=$(find "$dir" -name "$name" -type f 2>/dev/null | sort -V | tail -1)
      if [[ -n "$found" ]]; then
        echo "$found"
        return
      fi
    done
  done
  command -v apksigner || true
}

SIGNER=$(find_apksigner)
if [[ -z "$SIGNER" ]]; then
  echo "找不到 apksigner，无法校验签名。ANDROID_HOME=${ANDROID_HOME:-未设置}" >&2
  exit 1
fi

echo
echo "签名校验（期望 $EXPECTED_CERT_SHA256）"
for f in "${EXPECTED[@]}"; do
  actual=$("$SIGNER" verify --print-certs "$APK_DIR/$f" 2>/dev/null \
    | grep -i "SHA-256 digest" | head -1 | awk '{print $NF}')

  if [[ "$actual" != "$EXPECTED_CERT_SHA256" ]]; then
    cat >&2 <<EOF

✗ $f 的签名和预期不一致，发版中止。
  实际: ${actual:-（读不出来）}

  如果实际值是 debug 签名，多半是 key.properties 没还原成功——
  检查 workflow 里「还原签名用的 keystore」那一步，以及
  ANDROID_KEYSTORE_BASE64 等几个 Secrets 是否齐全。

  如果确实是有意换密钥，先想清楚：**换密钥等于换应用身份**，
  已经装过旧版的用户无法覆盖安装，只能卸载重装，会丢掉全部睡眠历史。
  确认要换，再用新的指纹更新 workflow 里的 EXPECTED_CERT_SHA256。

EOF
    exit 1
  fi
  echo "  ✓ $f"
done

echo
echo "产物："
for f in "${EXPECTED[@]}"; do
  # 用 awk 而不是 bc：git bash 里默认没有 bc，本地就跑不了这个脚本
  size=$(stat -c%s "$APK_DIR/$f" | awk '{printf "%.1f", $1/1048576}')
  printf '  %-32s %s MB\n' "$f" "$size"
done
