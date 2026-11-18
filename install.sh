#!/bin/zsh
# Git Tag Sync を入れる・入れ直す。
#   1. アプリ「Git Tag Sync」を作り、~/Applications に入れる。
#   2. launchd のジョブ local.git-tag-sync を作り直し、決まった時刻に git-tag-sync.sh を実行させる。
#   3. 除外先の一覧 excludes.txt がなければ、excludes.example.txt を写して作る。
#
# 使い方: zsh install.sh [--hour 時] [--minute 分]
#         zsh install.sh --build-only 出力先フォルダ   # アプリを作るだけ（入れない・登録しない）
# 時刻を指定すると「毎日その時刻」になる。指定しなければ、前の設定（アプリの「変更…」で決めた間隔や、
# ログインしたときの実行も含む）を引き継ぐ。初回は毎日 10:00。
#
# 署名：キーチェーンにコード署名用の証明書（既定は「Local Code Signing」。GIT_TAG_SYNC_SIGN_ID で変えられる）が
# あればそれで署名する。macOS はアプリを「識別子＋証明書」で見分けるので、入れ直してもフルディスクアクセスが外れない。
# なければアドホック署名にする。その場合は入れ直すたびにフルディスクアクセスを付け直す必要がある（README を参照）。
set -euo pipefail
# メッセージの言語：LC_ALL・LANG → macOS の言語設定の先頭。ja で始まれば日本語、それ以外は英語。
_lang="${LC_ALL:-${LANG:-}}"
[[ -n "$_lang" ]] || _lang="$(/usr/bin/defaults read -g AppleLanguages 2>/dev/null | /usr/bin/awk -F'"' 'NF > 1 { print $2; exit }')"
if [[ "$_lang" == ja* ]]; then JA=1; else JA=0; fi
# t 日本語 英語：言語に合わせて、どちらかの文を返す
t() { if (( JA )); then print -r -- "$1"; else print -r -- "$2"; fi; }

HERE="${0:A:h}"
NAME="Git Tag Sync"
EXE="GitTagSync"
LABEL="local.git-tag-sync"
APP="$HOME/Applications/$NAME.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/git-tag-sync.log"
DOMAIN="gui/$(id -u)"
SIGN_ID="${GIT_TAG_SYNC_SIGN_ID:-Local Code Signing}"
VERSION="$(<"$HERE/VERSION")"

HOUR="" MINUTE="" BUILD_ONLY=""
while (( $# )); do
  case "$1" in
    --hour|--minute|--build-only)
      (( $# >= 2 )) || { t "$1 には値を指定してください。" "$1 needs a value." >&2; exit 2; }
      case "$1" in
        --hour) HOUR="$2" ;;
        --minute) MINUTE="$2" ;;
        --build-only) BUILD_ONLY="$2" ;;
      esac
      shift ;;
    -h|--help)
      print -r -- 'Usage: zsh install.sh [--hour H] [--minute M]'
      print -r -- '       zsh install.sh --build-only DIR'
      t 'アプリ「Git Tag Sync」を作って ~/Applications に入れ、launchd のジョブを登録し直します。' \
        'Builds "Git Tag Sync" into ~/Applications and (re)registers the launchd job.'
      t '時刻を指定すると「毎日その時刻」に同期します。指定しなければ前の設定を引き継ぎます（初回は毎日 10:00）。' \
        'With --hour/--minute it syncs every day at that time. Otherwise the previous schedule is kept (every day at 10:00 at first).'
      t '--build-only を付けると、アプリを作ってそのフォルダに置くだけで、入れたり登録したりはしません。' \
        '--build-only only builds the app into DIR without installing or registering it.'
      exit 0 ;;
    *) t "不明な引数: $1" "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
# 時刻の指定がなければ、前の設定を引き継ぐ（plist を作り直す前に控えておく）。
# OLD_SCHEDULE は StartCalendarInterval の中身（XML）。空なら「自動では同期しない」。
KEEP_SCHEDULE=0 OLD_SCHEDULE="" RUN_AT_LOAD="false"
if [[ -f "$PLIST" ]]; then
  if [[ -z "$HOUR$MINUTE" ]]; then
    KEEP_SCHEDULE=1
    OLD_SCHEDULE=$(plutil -extract StartCalendarInterval xml1 -o - "$PLIST" 2>/dev/null | sed '1,3d;$d' || true)
  fi
  [[ "$(plutil -extract RunAtLoad raw -o - "$PLIST" 2>/dev/null || true)" == "true" ]] && RUN_AT_LOAD="true"
fi
HOUR="${HOUR:-10}" MINUTE="${MINUTE:-0}"
if [[ ! "$HOUR" =~ '^[0-9]+$' ]] || (( HOUR > 23 )) || [[ ! "$MINUTE" =~ '^[0-9]+$' ]] || (( MINUTE > 59 )); then
  print -u2 -r -- "ERROR: $(t "時刻が正しくありません（時 $HOUR、分 $MINUTE）。" "Invalid time (hour $HOUR, minute $MINUTE).")"
  exit 2
fi

# --- 前提の確認 ---
command -v swiftc >/dev/null || { print -u2 -r -- "ERROR: $(t 'swiftc がありません。xcode-select --install で Command Line Tools を入れてください。' 'swiftc is missing. Install the Command Line Tools with: xcode-select --install')"; exit 1; }
if ! command -v tag >/dev/null && [[ ! -x /opt/homebrew/bin/tag && ! -x /usr/local/bin/tag ]]; then
  print -u2 -r -- "WARNING: $(t 'tag コマンドがありません。同期の前に brew install tag を実行してください。' 'The tag command is missing. Run brew install tag before syncing.')"
fi

# --- アプリを作る ---
BUILD="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$BUILD"' EXIT
BUNDLE="$BUILD/$NAME.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
swiftc -O -o "$BUNDLE/Contents/MacOS/$EXE" "$HERE/Sources/main.swift"
# アイコンは Resources/ にある変換済みのもの（Assets.car と GitTagSync.icns）を使う。
# GitTagSync.icon を直したら、tools/build-icon.sh（Xcode が要る）で作り直す。
cp "$HERE/Resources/Assets.car" "$HERE/Resources/GitTagSync.icns" "$BUNDLE/Contents/Resources/"
# 画面の文の訳（正本は英語。漏れは tools/check-strings.py で調べる）
cp -R "$HERE"/Resources/*.lproj "$BUNDLE/Contents/Resources/"
cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIconFile</key><string>GitTagSync</string>
  <key>CFBundleIconName</key><string>GitTagSync</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ja</string></array>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>SyncScript</key><string>$HERE/git-tag-sync.sh</string>
</dict>
</plist>
EOF
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_ID\""; then
  codesign --force -s "$SIGN_ID" "$BUNDLE"
  SIGNED_WITH_CERT=1
else
  codesign --force -s - "$BUNDLE"
  SIGNED_WITH_CERT=0
  print -u2 -r -- "WARNING: $(t "署名用の証明書「$SIGN_ID」がないので、アドホック署名にしました。入れ直すたびにフルディスクアクセスを付け直す必要があります（README の「署名」を参照）。" "No code signing certificate named \"$SIGN_ID\", so the app was signed ad hoc. You will need to grant Full Disk Access again after every reinstall (see Code signing in the README).")"
fi

if [[ -n "$BUILD_ONLY" ]]; then
  mkdir -p "$BUILD_ONLY"
  rm -rf "$BUILD_ONLY/$NAME.app"
  mv "$BUNDLE" "$BUILD_ONLY/"
  t "作りました: $BUILD_ONLY/$NAME.app" "Built: $BUILD_ONLY/$NAME.app"
  exit 0
fi

mkdir -p "$HOME/Applications"
pkill -x "$EXE" 2>/dev/null || true
rm -rf "$APP"
mv "$BUNDLE" "$APP"

# --- 除外先の一覧 ---
if [[ ! -f "$HERE/excludes.txt" ]]; then
  cp "$HERE/excludes.example.txt" "$HERE/excludes.txt"
  t "除外先の一覧を作りました: $HERE/excludes.txt" "Created the exclusion list: $HERE/excludes.txt"
fi

# --- launchd に登録し直す ---
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for i in {1..20}; do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
mkdir -p "${PLIST:h}" "${LOG:h}"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <!-- zsh を直接起動するとフルディスクアクセスが効かないので、アプリを経由する。
       --run：画面を出さずに同期する。--quiet：変化のない KEEP の行をログに出さない -->
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/$EXE</string>
    <string>--run</string>
    <string>--quiet</string>
  </array>
  <key>AssociatedBundleIdentifiers</key><string>$LABEL</string>
  <!-- この時刻に実行する（アプリの「変更…」で変えられる）。スリープ中だった場合は起きたときに実行される -->
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>$((HOUR))</integer>
    <key>Minute</key><integer>$((MINUTE))</integer>
  </dict>
  <!-- 探索中に他の作業の邪魔をしないよう、優先度を下げる -->
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
if (( KEEP_SCHEDULE )); then
  if [[ -n "$OLD_SCHEDULE" ]]; then
    plutil -replace StartCalendarInterval -xml "$OLD_SCHEDULE" "$PLIST"
  else
    plutil -remove StartCalendarInterval "$PLIST"
  fi
fi
plutil -replace RunAtLoad -bool "$RUN_AT_LOAD" "$PLIST"
plutil -lint -s "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"

if (( KEEP_SCHEDULE )); then
  t "入れました: $APP $VERSION（同期の時刻は前の設定のまま）" "Installed: $APP $VERSION (the sync schedule is unchanged)"
else
  WHEN="$(printf '%d:%02d' "$HOUR" "$MINUTE")"
  t "入れました: $APP $VERSION（毎日 $WHEN に同期）" "Installed: $APP $VERSION (syncs every day at $WHEN)"
fi
if (( SIGNED_WITH_CERT )); then
  t "フルディスクアクセスは初回だけ付けてください（システム設定 > プライバシーとセキュリティ > フルディスクアクセス で「$NAME」を追加）。" \
    "Grant Full Disk Access once (System Settings > Privacy & Security > Full Disk Access, add \"$NAME\")."
else
  t "システム設定 > プライバシーとセキュリティ > フルディスクアクセス で「$NAME」を「−」で消してから「＋」で追加し直してください。" \
    "In System Settings > Privacy & Security > Full Disk Access, remove \"$NAME\" with − and add it again with +."
fi
