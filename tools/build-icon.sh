#!/bin/zsh
# GitTagSync.icon（Icon Composer の形式）を、アプリに入れる形（Assets.car と GitTagSync.icns）に変換して
# Resources/ に置く。アイコンを直したときだけ実行する。Xcode（/Applications/Xcode.app）の actool が要る
# （Command Line Tools には actool がない）。
set -euo pipefail
# メッセージの言語：LC_ALL・LANG → macOS の言語設定の先頭。ja で始まれば日本語、それ以外は英語。
_lang="${LC_ALL:-${LANG:-}}"
[[ -n "$_lang" ]] || _lang="$(/usr/bin/defaults read -g AppleLanguages 2>/dev/null | /usr/bin/awk -F'"' 'NF > 1 { print $2; exit }')"
if [[ "$_lang" == ja* ]]; then JA=1; else JA=0; fi
# t 日本語 英語：言語に合わせて、どちらかの文を返す
t() { if (( JA )); then print -r -- "$1"; else print -r -- "$2"; fi; }
HERE="${0:A:h:h}"
DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -d "$DEV" ]] || { print -u2 -r -- "ERROR: $(t "Xcode がありません（$DEV）。" "Xcode is missing ($DEV).")"; exit 1; }
OUT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$OUT"' EXIT
DEVELOPER_DIR="$DEV" xcrun actool "$HERE/GitTagSync.icon" \
  --compile "$OUT" --platform macosx --target-device mac \
  --minimum-deployment-target 14.0 --app-icon GitTagSync --include-all-app-icons \
  --output-partial-info-plist "$OUT/partial.plist" >/dev/null
mkdir -p "$HERE/Resources"
cp "$OUT/Assets.car" "$OUT/GitTagSync.icns" "$HERE/Resources/"
t "作りました: $HERE/Resources/Assets.car, GitTagSync.icns" "Built: $HERE/Resources/Assets.car, GitTagSync.icns"
