---
name: cmds
description: cmds（ネイティブ macOS のターミナルワークスペースアプリ）の中で作業しているときに、ペイン分割・アプリ内ブラウザ・ファイルのプレビュー・サイドバー表示・通知を `cmds` CLI で使う手順。環境変数 CMDS_PANE_ID が設定されているとき（cmds のターミナル内）に、開発サーバーを動かす、Web 画面を確認・撮影する、生成した画像・レポート・差分をユーザーに見せる、長い作業の状況を表示する、別ペインの出力を読むときに使う。CMDS_PANE_ID がなければ使わない。
---

# cmds の中での作業

cmds のターミナルでは `cmds` CLI が PATH にあり、`CMDS_PANE_ID` / `CMDS_WORKSPACE_ID` が自分のペインを指す。
まず `[ -n "$CMDS_PANE_ID" ] && cmds ping` で使えるか確かめる。失敗したらこのスキルは使わない。

## 守ること

- **入力を送るのは、自分がこのセッションで作ったペインだけ。** ユーザーや他のエージェントのペインに `cmds send` しない。
  ペイン ID はアプリの再起動で振り直されるので決め打ちしない。`cmds split` / `cmds browser open` / `cmds open` が返した ID を使う。
- 自分が作っていないペイン・ワークスペースを閉じない。`cmds read` で他のペインを読むのは、ユーザーに頼まれたときだけ。
- ペインを開くときは `--no-focus` を付ける。付けないと、ユーザーが打っているキーボードの入力先が移ってしまう。
- 終わったら、自分が起動したサーバーやウォッチャーを止め（`cmds send --pane <id> $'\x03'`）、ペインを閉じる（`cmds close-pane --pane <id>`）。

## よく使う手順

開発サーバーを下のペインで動かし、ログを読む:

```sh
P=$(cmds split down --no-focus -- npm run dev)    # 新しいペインの ID が出力される
sleep 5; cmds read --pane "$P" --scrollback 100    # 起動ログを確認
```

Web 画面を開いて確認する（スクリーンショットは Read ツールで見る）:

```sh
B=$(cmds browser open --no-focus http://localhost:3000)
cmds browser snapshot --pane "$B" -o /tmp/cmds-page.png
cmds browser eval --pane "$B" 'document.title'
cmds browser eval --pane "$B" 'await fetch("/api/health").then(r => r.status)'
cmds browser navigate --pane "$B" http://localhost:3000/settings
```

作ったファイル（画像・PDF・Markdown のレポート・差分）をユーザーに見せる（右にプレビューペインが開き、ファイルが変わると自動で再読み込みされる）:

```sh
V=$(cmds open --no-focus out/chart.png)            # 画像・PDF・動画・Office・テキストを表示
cmds open --pane "$V" REPORT.md                    # 同じプレビューペインで別のファイルを表示（Markdown は整形される）
git diff | cmds open --no-focus --diff -           # 差分を色付きで表示（.diff / .patch はそのまま開ける）
```

- `cmds open` はこの Mac 上のファイルだけ開ける。SSH ペイン（サーバー上）からは使えない。
- 見せ終わったら、自分が開いたプレビューペインを閉じる（`cmds close-pane "$V"`）。

長い作業の状況をサイドバーに出す（リングは光らない）:

```sh
cmds status "テスト実行中 (3/10)"
cmds status ""                                     # 消す
```

- 入力待ち・完了の通知は Claude Code のフック（`cmds hook claude`）が自動で出す。自分で `cmds notify` を使うのは、
  途中でユーザーの判断が要る出来事（長いビルドの失敗など）があるときだけにする。
- 状態を機械的に読むときは `--json` を付ける（例: `cmds ls --json`、`cmds stats --json`）。
- 詳しい使い方: `cmds --help`、`cmds <command> --help`。
