# Changelog

この形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に、版の付け方は [Semantic Versioning](https://semver.org/lang/ja/) に従います。版の正本は `VERSION` です。

## [0.1.0] - 2026-11-18

最初の公開版。

### 追加

- `git-tag-sync.sh`：ホームフォルダの中の Git のリポジトリに Finder の「Git」タグを付け、Git の管理から外れたフォルダからは外す。`--dry-run`、`--quiet`、`--untag フォルダ`、`--version`。
- 除外先の一覧 `excludes.txt`（例は `excludes.example.txt`）。名前が `.` で始まるフォルダは常に除外する。
- アプリ「Git Tag Sync」：launchd から毎日決まった時刻に同期を実行する（フルディスクアクセスを受け取るため）。開くと「前回の結果」「タグ付きのフォルダ」「除外するフォルダ」の画面を出す。除外に追加すると、そのフォルダと中の「Git」タグを外す。
- `install.sh`（`--hour`・`--minute` で時刻を指定、`--build-only`）と `uninstall.sh`。
- キーチェーンのコード署名用の証明書があれば、それで署名する（入れ直してもフルディスクアクセスが外れない）。なければアドホック署名にする。

[0.1.0]: https://github.com/zerollpaper/git-tag-sync/releases/tag/v0.1.0
