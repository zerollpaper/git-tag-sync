# Changelog

この形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に、版の付け方は [Semantic Versioning](https://semver.org/lang/ja/) に従います。版の正本は `VERSION` です。

## [0.3.0] - 2026-11-18

### 追加

- 英語に対応した。アプリの画面・メニュー、自動の同期のログ、スクリプト（`git-tag-sync.sh`・`install.sh`・`uninstall.sh`）のメッセージが、英語と日本語で出る。文の正本は英語で、日本語の訳は `Resources/ja.lproj/Localizable.strings` にある。
- 言語の設定：既定は macOS の言語設定に合わせる。ウインドウ右上の地球儀のボタンか、メニューバーの「言語」で、このアプリだけ「English」「日本語」に切り替えられる（その場で切り替わり、自動の同期のログもその言語になる）。ターミナルから実行したスクリプトは `LANG`（空なら macOS の言語設定）に従う。
- `tools/check-strings.py`：訳の漏れ、使われていない訳、埋め込み（`%@` など）の食い違いを調べる。
- README に画面の写真を載せた。

### 変更

- `excludes.example.txt` のコメントを英語と日本語の両方にした。

## [0.2.0] - 2026-11-18

### 追加

- アプリの下の段の「変更…」から、自動で同期する時刻を設定できるようにした。「毎日（時刻）」「一定の間隔（1・2・3・4・6・8・12時間ごと、起点の時刻）」「しない」から選べる。「N時間ごと」は、スリープ中に時刻を過ぎたときも起きたときに実行されるよう、時刻を並べて launchd に登録する。
- 「ログインしたときにも同期する」を選べるようにした。

### 変更

- `install.sh` を実行し直したとき、時刻を指定しなければ、アプリで決めた設定（間隔・停止・ログイン時の実行）を引き継ぐ。`--hour`・`--minute` を指定すると「毎日その時刻」になる。

## [0.1.0] - 2026-11-18

最初の公開版。

### 追加

- `git-tag-sync.sh`：ホームフォルダの中の Git のリポジトリに Finder の「Git」タグを付け、Git の管理から外れたフォルダからは外す。`--dry-run`、`--quiet`、`--untag フォルダ`、`--version`。
- 除外先の一覧 `excludes.txt`（例は `excludes.example.txt`）。名前が `.` で始まるフォルダは常に除外する。
- アプリ「Git Tag Sync」：launchd から毎日決まった時刻に同期を実行する（フルディスクアクセスを受け取るため）。開くと「前回の結果」「タグ付きのフォルダ」「除外するフォルダ」の画面を出す。除外に追加すると、そのフォルダと中の「Git」タグを外す。
- `install.sh`（`--hour`・`--minute` で時刻を指定、`--build-only`）と `uninstall.sh`。
- キーチェーンのコード署名用の証明書があれば、それで署名する（入れ直してもフルディスクアクセスが外れない）。なければアドホック署名にする。

[0.3.0]: https://github.com/zerollpaper/git-tag-sync/releases/tag/v0.3.0
[0.2.0]: https://github.com/zerollpaper/git-tag-sync/releases/tag/v0.2.0
[0.1.0]: https://github.com/zerollpaper/git-tag-sync/releases/tag/v0.1.0
