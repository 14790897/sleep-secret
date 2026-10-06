#!/usr/bin/env bash
#
# 把 semantic-release 算出来的版本写进 app/pubspec.yaml。
#
#   scripts/set_version.sh 1.4.2 [pubspec 路径]
#
# pubspec 的 version 格式是 `X.Y.Z+N`：
#   X.Y.Z  -> versionName，用户看到的
#   N      -> versionCode，Android 靠它判断"这是不是更新版本"，**必须单调递增**
#
# 所以不能只写 X.Y.Z 就完事——不写 +N 的话 Flutter 会默认 versionCode=1，
# 装新版会被当成"没有更新"。这里用 major*10000 + minor*100 + patch 换算：
# 单调、可读、一眼能看出对应哪个版本，而且远低于 Android 的上限 2100000000。
set -euo pipefail

VERSION="${1:?用法: set_version.sh <x.y.z> [pubspec 路径]}"
PUBSPEC="${2:-app/pubspec.yaml}"

if [[ ! -f "$PUBSPEC" ]]; then
  echo "找不到 $PUBSPEC" >&2
  exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
for part in "$MAJOR" "$MINOR" "$PATCH"; do
  if [[ ! "$part" =~ ^[0-9]+$ ]]; then
    echo "版本号 '$VERSION' 里有非数字段，期望 x.y.z 形式" >&2
    exit 1
  fi
done

CODE=$(( MAJOR * 10000 + MINOR * 100 + PATCH ))

# 写临时文件再改名，而不是 `sed -i`——后者的 -i 参数在 GNU 和 BSD 上语法不同，
# 这个脚本在 CI（Linux）和本地（Windows git-bash）都要能跑。
sed -E "s|^version: .*|version: ${VERSION}+${CODE}|" "$PUBSPEC" > "${PUBSPEC}.tmp"
mv "${PUBSPEC}.tmp" "$PUBSPEC"

if ! grep -qE "^version: ${VERSION}\+${CODE}$" "$PUBSPEC"; then
  echo "回写失败，$PUBSPEC 里没有出现 version: ${VERSION}+${CODE}" >&2
  exit 1
fi

echo "pubspec.yaml -> version: ${VERSION}+${CODE}  (versionCode=${CODE})"
