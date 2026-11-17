#!/bin/zsh
# Git Tag Sync を入れる・入れ直す。
#   1. アプリ「Git Tag Sync」を作り、~/Applications に入れる。
#   2. launchd のジョブ local.git-tag-sync を作り直し、毎日決まった時刻に git-tag-sync.sh を実行させる。
#   3. 除外先の一覧 excludes.txt がなければ、excludes.example.txt を写して作る。
#
# 使い方: zsh install.sh [--hour 時] [--minute 分]
#         zsh install.sh --build-only 出力先フォルダ   # アプリを作るだけ（入れない・登録しない）
# 時刻を指定しなければ、前に登録した時刻（初回は 10:00）のまま。
#
# 署名：キーチェーンにコード署名用の証明書（既定は「Local Code Signing」。GIT_TAG_SYNC_SIGN_ID で変えられる）が
# あればそれで署名する。macOS はアプリを「識別子＋証明書」で見分けるので、入れ直してもフルディスクアクセスが外れない。
# なければアドホック署名にする。その場合は入れ直すたびにフルディスクアクセスを付け直す必要がある（README を参照）。
set -euo pipefail

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
    --hour) HOUR="${2:?--hour には 0〜23 を指定してください}"; shift ;;
    --minute) MINUTE="${2:?--minute には 0〜59 を指定してください}"; shift ;;
    --build-only) BUILD_ONLY="${2:?--build-only には出力先のフォルダを指定してください}"; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 -r -- "不明な引数: $1"; exit 2 ;;
  esac
  shift
done
# 時刻の指定がなければ、今の登録から引き継ぐ。
if [[ -z "$HOUR" ]]; then
  HOUR=$(/usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval:Hour' "$PLIST" 2>/dev/null || echo 10)
fi
if [[ -z "$MINUTE" ]]; then
  MINUTE=$(/usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval:Minute' "$PLIST" 2>/dev/null || echo 0)
fi
if [[ ! "$HOUR" =~ '^[0-9]+$' ]] || (( HOUR > 23 )) || [[ ! "$MINUTE" =~ '^[0-9]+$' ]] || (( MINUTE > 59 )); then
  print -u2 -r -- "ERROR: 時刻が正しくありません（時 $HOUR、分 $MINUTE）。"
  exit 2
fi

# --- 前提の確認 ---
command -v swiftc >/dev/null || { print -u2 -r -- 'ERROR: swiftc がありません。xcode-select --install で Command Line Tools を入れてください。'; exit 1; }
if ! command -v tag >/dev/null && [[ ! -x /opt/homebrew/bin/tag && ! -x /usr/local/bin/tag ]]; then
  print -u2 -r -- 'WARNING: tag コマンドがありません。同期の前に brew install tag を実行してください。'
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
  print -u2 -r -- "WARNING: 署名用の証明書「$SIGN_ID」がないので、アドホック署名にしました。入れ直すたびにフルディスクアクセスを付け直す必要があります（README の「署名」を参照）。"
fi

if [[ -n "$BUILD_ONLY" ]]; then
  mkdir -p "$BUILD_ONLY"
  rm -rf "$BUILD_ONLY/$NAME.app"
  mv "$BUNDLE" "$BUILD_ONLY/"
  echo "作りました: $BUILD_ONLY/$NAME.app"
  exit 0
fi

mkdir -p "$HOME/Applications"
pkill -x "$EXE" 2>/dev/null || true
rm -rf "$APP"
mv "$BUNDLE" "$APP"

# --- 除外先の一覧 ---
if [[ ! -f "$HERE/excludes.txt" ]]; then
  cp "$HERE/excludes.example.txt" "$HERE/excludes.txt"
  echo "除外先の一覧を作りました: $HERE/excludes.txt"
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
  <!-- 毎日この時刻に実行する。スリープ中だった場合は起きたときに実行される -->
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
plutil -lint -s "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"

printf '入れました: %s %s（毎日 %d:%02d に同期）\n' "$APP" "$VERSION" "$HOUR" "$MINUTE"
if (( SIGNED_WITH_CERT )); then
  echo "フルディスクアクセスは初回だけ付ける（システム設定 > プライバシーとセキュリティ > フルディスクアクセス で「$NAME」を追加）。"
else
  echo "システム設定 > プライバシーとセキュリティ > フルディスクアクセス で「$NAME」を「−」で消してから「＋」で追加し直してください。"
fi
