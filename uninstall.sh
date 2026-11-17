#!/bin/zsh
# Git Tag Sync を取り除く。launchd のジョブ、アプリ、前回の結果を消す。
# このフォルダ（スクリプト・excludes.txt）とログ（~/Library/Logs/git-tag-sync.log）、付いている「Git」タグは残す。
# タグも外したいときは、先に「git-tag-sync.sh --untag ~」を実行する。
set -euo pipefail
LABEL="local.git-tag-sync"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x GitTagSync 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Git Tag Sync.app" "$HOME/Library/Application Support/Git Tag Sync"
echo "取り除きました。システム設定のフルディスクアクセスの一覧に「Git Tag Sync」が残っていたら、「−」で消してください。"
