#!/usr/bin/env bash
#
# 为当前版本生成 F-Droid 要的更新日志。
#
#   bash scripts/make_fastlane_changelog.sh <x.y.z> <<'EOF'
#   <semantic-release 的 release notes>
#   EOF
#
# ## 为什么需要这个脚本
#
# F-Droid 的更新日志**按 versionCode 命名**，而 `--split-per-abi` 让一个版本有
# 三个 versionCode，于是每发一版要写 6 个文件（2 语言 × 3 个 code）。
# 漏掉**不会报错**，只是这个应用不再出现在 F-Droid 客户端的「最新」标签里——
# 静默失效，所以交给脚本。
#
# ## 两个规则
#
# **1. 已经存在的文件不动。** 想给某个语言手写一份（比如把中文的 release notes
# 翻译成英文），就提前把文件提交进仓库，脚本会让开。
#
# **2. versionCode 从 fdroid 元数据里读**，不在这里重写一遍 ABI 偏移。
# 偏移是 Flutter 定的（`abiVersionCode * 1000`，见 FlutterPlugin.kt），
# 元数据里的 `VercodeOperation` 已经是它的表达；这里再抄一份迟早会跟它不一致。
set -euo pipefail

VERSION="${1:?用法: make_fastlane_changelog.sh <x.y.z>（release notes 从 stdin 读）}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${ROOT}/fdroid/com.sleepsecret.sleep_secret.yml"
FASTLANE="${ROOT}/app/fastlane/metadata/android"

# 和 set_version.sh 同一个换算：major*10000 + minor*100 + patch
IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
for part in "$MAJOR" "$MINOR" "$PATCH"; do
  [[ "$part" =~ ^[0-9]+$ ]] || { echo "版本号 '$VERSION' 不是 x.y.z" >&2; exit 1; }
done
CODE=$(( MAJOR * 10000 + MINOR * 100 + PATCH ))

# ---- 从元数据读 VercodeOperation，算出这个版本真正的 versionCode ----
# 元数据的 VercodeOperation 可能是加法（'%c + 1000'）也可能是乘法
# （'%c * 10 + 1'），所以不能只抠数字再加——要把 %c 换成真值后
# 整条表达式交给 shell 求值，和 fdroidserver 的做法一致。
[[ -f "$META" ]] || { echo "找不到 $META" >&2; exit 1; }
mapfile -t OPS < <(
  sed -n '/^VercodeOperation:/,/^[A-Za-z]/p' "$META" \
    | grep -oE "'[^']+'" | tr -d "'"
)
if [[ ${#OPS[@]} -eq 0 ]]; then
  echo "没能从 $META 的 VercodeOperation 里读出算式" >&2
  exit 1
fi

CODES=()
for op in "${OPS[@]}"; do
  # 只允许 %c、数字、四则运算符和空格——这个字符串会进算术求值。
  # `-` 必须放在字符类末尾，否则会被当成范围（写 `/-\ ` 会变成
  # 「从 / 到 \ 的所有字符」，`%` 不在其中，算式就被误拒了）。
  if [[ "$op" =~ [^0-9%c[:space:]+*/-] ]]; then
    echo "VercodeOperation 里有意料之外的字符，拒绝求值: $op" >&2
    exit 1
  fi
  CODES+=( $(( ${op//%c/$CODE} )) )
done
echo "版本 ${VERSION} → pubspec versionCode ${CODE}；各 ABI 的 code: ${CODES[*]}"

# ---- 把 release notes 洗成人能读的一段 ----
# 去标题行、去 markdown 链接只留文字、去掉行末残留的 commit 短 hash
# （原来是 `说明 ([abc1234](url))`，剥掉链接后剩下 `说明 (abc1234)`，
#  对用户是噪音）。
NOTES="$(
  sed -E \
    -e '/^#/d' \
    -e 's/\[([^]]*)\]\([^)]*\)/\1/g' \
    -e 's/ \([0-9a-f]{7,}\)$//' \
    -e 's/^\* */· /' \
    -e 's/[[:space:]]+$//' \
  | grep -v '^[[:space:]]*$' || true
)"

if [[ -z "$NOTES" ]]; then
  # 没有可用条目时不能留空——F-Droid 会当成「这个版本没有更新说明」，
  # 应用就掉出「最新」标签。宁可给一句话。
  NOTES="维护性更新，改动详见 https://github.com/14790897/sleep-secret/releases/tag/v${VERSION}"
fi

# F-Droid 的上限是 500 字符，超了会被截断（而且是静默截断）
NOTES="${NOTES:0:500}"

wrote=0; skipped=0
for locale in en-US zh-CN; do
  dir="${FASTLANE}/${locale}/changelogs"
  mkdir -p "$dir"
  for c in "${CODES[@]}"; do
    f="${dir}/${c}.txt"
    if [[ -e "$f" ]]; then
      skipped=$(( skipped + 1 ))
      continue
    fi
    printf '%s\n' "$NOTES" > "$f"
    wrote=$(( wrote + 1 ))
  done
done

echo "写入 ${wrote} 个更新日志，跳过 ${skipped} 个已存在的"
if [[ $wrote -eq 0 ]]; then
  echo "⚠️  一个都没写——如果这不是有意的，检查一下 code 是不是算错了" >&2
fi
