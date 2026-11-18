#!/usr/bin/env zsh
# Finder の「Git」タグを同期する。対象には付け、Git管理から外れた対象からは外す。
# 除外先には、タグの追加・削除とも行わない。除外先は同じフォルダの excludes.txt に書く（アプリの画面からも編集できる）。
# 毎日10:00に launchd（local.git-tag-sync）から専用アプリ経由で実行している。同じフォルダの README.md を参照。
# 使用例: git-tag-sync.sh --dry-run
#         git-tag-sync.sh
#         git-tag-sync.sh --quiet   # KEEP（変化なし）の行を出さない。launchd からの実行で使う
#         git-tag-sync.sh --untag ~/ComfyUI-Installs   # そのフォルダ（と中）の「Git」タグを外す。除外に足したときに使う
emulate -LR zsh
set -euo pipefail

ROOT="${HOME:A}"
TAGNAME="Git"
# 除外先の一覧。1行に1フォルダ（~ で始めてよい）。空行と # で始まる行は読み飛ばす。
# ここに書いたフォルダの配下は、探索・タグ操作の両方から除外する。
EXCLUDES_FILE="${0:A:h}/excludes.txt"
# メッセージの言語：GIT_TAG_SYNC_LANG（アプリが画面と同じ言語を渡す）→ LC_ALL・LANG → macOS の言語設定の先頭。
# ja で始まれば日本語、それ以外は英語。
_lang="${GIT_TAG_SYNC_LANG:-${LC_ALL:-${LANG:-}}}"
[[ -n "$_lang" ]] || _lang="$(/usr/bin/defaults read -g AppleLanguages 2>/dev/null | /usr/bin/awk -F'"' 'NF > 1 { print $2; exit }')"
if [[ "$_lang" == ja* ]]; then JA=1; else JA=0; fi
# t 日本語 英語：言語に合わせて、どちらかの文を返す
t() { if (( JA )); then print -r -- "$1"; else print -r -- "$2"; fi; }
DRY_RUN=0
QUIET=0
UNTAG_DIR=""
while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --quiet) QUIET=1 ;;
    --untag)
      (( $# >= 2 )) || { t '--untag にはフォルダを指定してください。' '--untag needs a folder.' >&2; exit 2; }
      UNTAG_DIR="$2"; shift ;;
    --version)
      print -r -- "git-tag-sync $(<"${0:A:h}/VERSION")"
      exit 0 ;;
    -h|--help)
      print -r -- 'Usage: git-tag-sync.sh [--dry-run] [--quiet]'
      print -r -- "       git-tag-sync.sh [--dry-run] --untag $(t 'フォルダ' 'FOLDER')"
      print -r -- '       git-tag-sync.sh --version'
      t '対象のGitフォルダにタグを付け、Git管理から外れた対象からは外します。除外先には触れません。' \
        'Adds the Finder "Git" tag to Git folders and removes it from folders that are no longer repositories. Excluded folders are left alone.'
      t "除外先は $EXCLUDES_FILE に書きます。" "Excluded folders are listed in $EXCLUDES_FILE."
      t '--dry-run を付けると、タグを変えずに、変わる予定のものだけを出します。' '--dry-run shows what would change without changing any tags.'
      t '--quiet を付けると、KEEP（変化なし）の行を出しません。' '--quiet does not print unchanged (KEEP) folders.'
      t '--untag を付けると、同期はせず、そのフォルダとその中の「Git」タグを外します。' '--untag only removes the "Git" tag from the folder and everything inside it.'
      exit 0 ;;
    *) t "不明な引数: $1" "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

EXCLUDE_DIRS=()
if [[ -f "$EXCLUDES_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" && "$line" != \#* ]] || continue
    [[ "$line" == "~" || "$line" == "~/"* ]] && line="$ROOT${line#\~}"
    if [[ "$line" != /* ]]; then
      print -u2 -r -- "WARNING: $(t "excludes.txt の行を読み飛ばしました（/ か ~ で始まっていません）: $line" "Skipped a line in excludes.txt (it does not start with / or ~): $line")"
      continue
    fi
    EXCLUDE_DIRS+=( "${line:A}" )
  done < "$EXCLUDES_FILE"
else
  print -u2 -r -- "WARNING: $(t "除外先の一覧 $EXCLUDES_FILE がありません。除外先なしで続けます。" "$EXCLUDES_FILE does not exist. Continuing without excluded folders.")"
fi

# Finder のタグを操作する tag コマンド（https://github.com/jdberry/tag 、Homebrew で入る）。
# launchd から動くときは PATH に Homebrew が入っていないので、決まった場所も探す。
TAG_BIN=""
for candidate in "$(command -v tag 2>/dev/null || true)" /opt/homebrew/bin/tag /usr/local/bin/tag; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then TAG_BIN="$candidate"; break; fi
done
if [[ -z "$TAG_BIN" ]]; then
  print -u2 -r -- "ERROR: $(t 'tag コマンドがありません。brew install tag を実行してください。' 'The tag command is missing. Run: brew install tag')"
  exit 1
fi

is_excluded() {
  local target="$1" base relative component
  for base in "${EXCLUDE_DIRS[@]}"; do
    [[ "$target" != "$base" && "$target" != "$base/"* ]] || return 0
  done
  [[ "$target" == "$ROOT/"* ]] || return 0
  relative="${target#"$ROOT/"}"
  for component in "${(@s:/:)relative}"; do
    # 従来どおり隠しフォルダ内は対象外。
    [[ "$component" != .* ]] || return 0
  done
  return 1
}

has_tag() {
  local target="$1"
  /usr/bin/mdls -raw -name kMDItemUserTags "$target" |
    /usr/bin/awk -v t="$TAGNAME" '
      { gsub(/^[[:space:]]+|[[:space:]]+$/, "");
        sub(/,$/, ""); sub(/^"/, ""); sub(/"$/, "");
        if ($0 == t) found=1 }
      END { exit !found }'
}

TMP_DIR="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_DIR"' EXIT

# --untag：そのフォルダ自身と、その中で「Git」タグが付いているものからタグを外す。
if [[ -n "$UNTAG_DIR" ]]; then
  target="${UNTAG_DIR:A}"
  if [[ ! -d "$target" || ( "$target" != "$ROOT" && "$target" != "$ROOT/"* ) ]]; then
    print -u2 -r -- "ERROR: $(t "ホームフォルダか、その中にあるフォルダを指定してください: $UNTAG_DIR" "Specify your home folder or a folder inside it: $UNTAG_DIR")"
    exit 2
  fi
  /usr/bin/mdfind -0 -onlyin "$target" 'kMDItemUserTags == "Git"' > "$TMP_DIR/untag"
  typeset -i COUNT_UNTAG=0
  { print -rn -- "$target"; print -rn -- $'\0'; /bin/cat "$TMP_DIR/untag"; } |
  while IFS= read -r -d '' item; do
    [[ "$item" == "$target" || "$item" == "$target/"* ]] || continue
    [[ -e "$item" && ! -L "$item" ]] || continue
    has_tag "$item" || continue
    if (( ! DRY_RUN )); then
      "$TAG_BIN" --remove "$TAGNAME" "$item"
    fi
    print -r -- "UNTAG : $item"
    (( ++COUNT_UNTAG ))
  done
  (( ! DRY_RUN )) || print -r -- "DRY RUN: $(t 'タグの変更は行っていません。' 'no tags were changed.')"
  print -r -- "SUMMARY -> UNTAG: $COUNT_UNTAG"
  exit 0
fi
find_args=( "$ROOT" )
for excluded in "${EXCLUDE_DIRS[@]}"; do
  find_args+=( -path "$excluded" -prune -o )
done
# .git の中へは降りず、ファイル形式の .git も収集する。
find_args+=( '(' -name .git '(' -type d -o -type f ')' -print0 -prune ')' -o
             '(' -type d -name '.*' -prune ')' )
SCAN_OK=1
if ! /usr/bin/find "${find_args[@]}" > "$TMP_DIR/repos" 2> "$TMP_DIR/find-errors"; then
  SCAN_OK=0
  print -u2 -r -- "WARNING: $(t '探索できない場所があります。確認できる対象の同期を続けますが、全体の同期は未完了です。' 'Some folders could not be searched. The folders that could be checked are synced, but the sync is incomplete.')"
  /bin/cat "$TMP_DIR/find-errors" >&2
fi
GIT_DIRS=()
while IFS= read -r -d '' git_marker; do
  GIT_DIRS+=( "${git_marker:h}" )
done < "$TMP_DIR/repos"
GIT_DIRS=( "${(@ou)GIT_DIRS}" )

# 削除候補の検索が失敗した場合も、変更前に停止する。
/usr/bin/mdfind -0 -onlyin "$ROOT" 'kMDItemUserTags == "Git"' > "$TMP_DIR/tagged"

typeset -i COUNT_KEEP=0 COUNT_ADD=0 COUNT_REMOVE=0
for repo in "${GIT_DIRS[@]}"; do
  if has_tag "$repo"; then
    (( QUIET )) || print -r -- "KEEP  : $repo"
    (( ++COUNT_KEEP ))
  else
    if (( ! DRY_RUN )); then
      "$TAG_BIN" --add "$TAGNAME" "$repo"
    fi
    print -r -- "ADD   : $repo"
    (( ++COUNT_ADD ))
  fi
done

while IFS= read -r -d '' repo; do
  is_excluded "$repo" && continue
  [[ -d "$repo" && -r "$repo" && -x "$repo" && ! -L "$repo" ]] || continue
  # 探索リストの欠落を理由にせず、現物の .git を再確認する。
  [[ ! -e "$repo/.git" && ! -L "$repo/.git" ]] || continue
  has_tag "$repo" || continue
  if (( ! DRY_RUN )); then
    "$TAG_BIN" --remove "$TAGNAME" "$repo"
  fi
  print -r -- "REMOVE: $repo"
  (( ++COUNT_REMOVE ))
done < "$TMP_DIR/tagged"
(( ! DRY_RUN )) || print -r -- "DRY RUN: $(t 'タグの変更は行っていません。' 'no tags were changed.')"
print -r -- "SUMMARY -> KEEP: $COUNT_KEEP, ADD: $COUNT_ADD, REMOVE: $COUNT_REMOVE"

# 探索エラーを成功扱いにしない。
(( SCAN_OK ))
