#!/bin/zsh
# Git Tag Sync を取り除く。launchd のジョブ、アプリ、前回の結果を消す。
# 除外先の一覧（~/Library/Application Support/Git Tag Sync/excludes.txt）とログ（~/Library/Logs/git-tag-sync.log）は残す。
# 使い方: zsh uninstall.sh [--remove-tags]
#   --remove-tags：先に、ホームフォルダの中の「Git」タグをすべて外す（アプリを消す前に、アプリで外す）。
set -euo pipefail
# メッセージの言語：LC_ALL・LANG → macOS の言語設定の先頭。ja で始まれば日本語、それ以外は英語。
_lang="${LC_ALL:-${LANG:-}}"
[[ -n "$_lang" ]] || _lang="$(/usr/bin/defaults read -g AppleLanguages 2>/dev/null | /usr/bin/awk -F'"' 'NF > 1 { print $2; exit }')"
if [[ "$_lang" == ja* ]]; then JA=1; else JA=0; fi
# t 日本語 英語：言語に合わせて、どちらかの文を返す
t() { if (( JA )); then print -r -- "$1"; else print -r -- "$2"; fi; }

REMOVE_TAGS=0
for arg in "$@"; do
  case "$arg" in
    --remove-tags) REMOVE_TAGS=1 ;;
    *) t "不明な引数: $arg" "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done
LABEL="local.git-tag-sync"
APP="$HOME/Applications/Git Tag Sync.app"
SUPPORT="$HOME/Library/Application Support/Git Tag Sync"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x GitTagSync 2>/dev/null || true
if (( REMOVE_TAGS )); then
  if [[ -x "$APP/Contents/MacOS/GitTagSync" ]]; then
    "$APP/Contents/MacOS/GitTagSync" --untag "$HOME" | tail -1
  else
    t 'アプリがないので、タグは外せませんでした。' 'The app is not installed, so the tags were not removed.' >&2
  fi
fi
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$SUPPORT/last-run.json"
rm -rf "$APP"
t "取り除きました。除外先の一覧（$SUPPORT/excludes.txt）とログは残しています。" \
  "Uninstalled. The exclusion list ($SUPPORT/excludes.txt) and the log are kept."
t 'システム設定のフルディスクアクセスの一覧に「Git Tag Sync」が残っていたら、「−」で消してください。' \
  'If "Git Tag Sync" is still in the Full Disk Access list in System Settings, remove it with −.'
