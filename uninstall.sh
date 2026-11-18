#!/bin/zsh
# Git Tag Sync を取り除く。launchd のジョブ、アプリ、前回の結果を消す。
# このフォルダ（スクリプト・excludes.txt）とログ（~/Library/Logs/git-tag-sync.log）、付いている「Git」タグは残す。
# タグも外したいときは、先に「git-tag-sync.sh --untag ~」を実行する。
set -euo pipefail
# メッセージの言語：LC_ALL・LANG → macOS の言語設定の先頭。ja で始まれば日本語、それ以外は英語。
_lang="${LC_ALL:-${LANG:-}}"
[[ -n "$_lang" ]] || _lang="$(/usr/bin/defaults read -g AppleLanguages 2>/dev/null | /usr/bin/awk -F'"' 'NF > 1 { print $2; exit }')"
if [[ "$_lang" == ja* ]]; then JA=1; else JA=0; fi
# t 日本語 英語：言語に合わせて、どちらかの文を返す
t() { if (( JA )); then print -r -- "$1"; else print -r -- "$2"; fi; }
LABEL="local.git-tag-sync"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x GitTagSync 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Git Tag Sync.app" "$HOME/Library/Application Support/Git Tag Sync"
t '取り除きました。システム設定のフルディスクアクセスの一覧に「Git Tag Sync」が残っていたら、「−」で消してください。' \
  'Uninstalled. If "Git Tag Sync" is still in the Full Disk Access list in System Settings, remove it with −.'
