#!/bin/zsh
# GitTagSync.icon（Icon Composer の形式）を、アプリに入れる形（Assets.car と GitTagSync.icns）に変換して
# Resources/ に置く。アイコンを直したときだけ実行する。Xcode（/Applications/Xcode.app）の actool が要る
# （Command Line Tools には actool がない）。
set -euo pipefail
HERE="${0:A:h:h}"
DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -d "$DEV" ]] || { print -u2 -r -- "ERROR: Xcode がありません（$DEV）。"; exit 1; }
OUT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$OUT"' EXIT
DEVELOPER_DIR="$DEV" xcrun actool "$HERE/GitTagSync.icon" \
  --compile "$OUT" --platform macosx --target-device mac \
  --minimum-deployment-target 14.0 --app-icon GitTagSync --include-all-app-icons \
  --output-partial-info-plist "$OUT/partial.plist" >/dev/null
mkdir -p "$HERE/Resources"
cp "$OUT/Assets.car" "$OUT/GitTagSync.icns" "$HERE/Resources/"
echo "作りました: $HERE/Resources/Assets.car, GitTagSync.icns"
