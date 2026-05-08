# embedded-gui-devbox

[English](README.md) | 日本語

AI コーディングエージェントを使って組み込み GUI を開発するための
Ubuntu 26.04 ベース dev container。CLI エージェント 2 種 (Claude Code
と OpenAI Codex) に加えて、デザインからコードへの変換を支える MCP
サーバ群を同梱している。multi-stage Dockerfile で `qt` / `slint` /
`flutter` / `lvgl` の 4 つのバリアントに分けてあるので、使うフレームワーク
に合わせて必要なものだけビルドすればよい。

> Qt 6 のランタイムは全バリアントに含まれる。`mcp-vnc` /
> `mcp-design2gui` / `qtvncglplugin` がいずれも Qt 6 製なので、Slint・
> Flutter・LVGL を出力先にする場合でも Qt 6 は必須依存になる。

## バリアント

各バリアントは Dockerfile の独立したステージで、すべて `qt` ベースを
継承する。`make <variant>` で選択する:

| バリアント | イメージサイズ | `qt` から追加されるもの |
| ---------- | -------------- | ----------------------- |
| `qt`       | 約 2.9 GB      | (ベース) Qt 6 / claude / codex / MCP サーバ / qtvncgl |
| `slint`    | 約 3.5 GB      | Rust toolchain (rustup を `/usr/local/cargo` に system-wide install) |
| `flutter`  | 約 4.8 GB      | Flutter stable + Dart + Linux desktop 用 engine の precache |
| `lvgl`     | 約 3.0 GB      | LVGL の desktop simulator 向け SDL2 開発パッケージ |

```bash
make qt          # 全バリアント共通のベース
make slint       # mcp-design2gui の Slint (Rust) 出力を扱う場合
make flutter     # 同 Flutter 出力を扱う場合
make lvgl        # LVGL の simulator build を扱う場合
```

`run` / `claude` / `codex` は既定で `qt` バリアントを使う。別バリアント
に切り替えるときは `VARIANT=...` を前置する。

## `qt` ベースに入っているもの

- Qt 6 開発ツール (`qt6-base-dev`, `qt6-declarative-dev`,
  `qml6-module-*`, `libxcb-cursor0`, `fonts-noto-cjk`)
- Node.js 22 LTS
- Claude Code CLI (`claude`) と OpenAI Codex CLI (`codex`)
- MCP サーバ
  - [`mcp-design2gui`](https://github.com/signal-slot/mcp-design2gui) —
    PSD / Figma を QML / Slint / Flutter に書き出すエクスポータ
  - [`mcp-vnc`](https://github.com/signal-slot/mcp-vnc) — Qt アプリを
    MCP プロトコル経由で操作する VNC クライアント
  - [`mcp-prompt-bridge`](https://www.npmjs.com/package/mcp-prompt-bridge) —
    上流 MCP サーバの prompt を MCP tool として再公開するブリッジ
- [`qtvncglplugin`](https://github.com/signal-slot/qtvncglplugin) —
  GPU アクセラレーションする Qt 用 VNC platform plugin
- ホスト X サーバへの画面転送

## 使い方

```bash
# 一度だけ: MCP_DESIGN2GUI_SRC が指す場所に mcp-design2gui を clone する
# (デフォルト: $HOME/src/mcp-design2gui)
git clone --recursive https://github.com/signal-slot/mcp-design2gui $HOME/src/mcp-design2gui

# このリポジトリのルートで:
make qt          # qt バリアントをビルド
make run         # コンテナ内で対話 bash
make claude      # Claude Code を起動
make codex       # OpenAI Codex CLI を起動
```

別バリアントを使うときは `VARIANT` で上書きする:

```bash
VARIANT=slint make claude       # slint バリアントで claude を起動
VARIANT=flutter make run        # flutter バリアントの対話 shell
```

`make <variant>` を実行すると、Makefile が `$MCP_DESIGN2GUI_SRC` の git
HEAD から `MCP_DESIGN2GUI_REV` を解決して BuildKit に渡す。HEAD が
変わると COPY と cmake の段だけ invalidate され (約 90 秒のリビルド)、
それ以外 (apt、Node.js、mcp-vnc、qtvncgl、codex、prompt-bridge、
バリアント固有の追加ツール) はキャッシュが効いたままになる。

git rev-parse をキャッシュキーにするだけで足りない場合 — たとえば
mcp-design2gui の未コミット変更を反映したいとき — はキャッシュ無しの
フルビルドを使う:

```bash
make rebuild     # docker compose build --no-cache (約 10 分)
```

## コンテナ内 `$HOME` の永続化 (`cc-home/`)

`cc-home/` はコンテナ内の `/home/dev` に bind mount される。コンテナが
`$HOME` 配下に書いた内容はすべてここに残る:

| パス                  | 内容 |
| --------------------- | ---- |
| `cc-home/.claude/`    | Claude Code のプロジェクト履歴・認証情報 |
| `cc-home/.claude.json` | Claude Code のメイン設定 |
| `cc-home/.mcp.json`   | MCP サーバ登録 (Claude Code が読む) |
| `cc-home/.codex/`     | Codex の設定とセッション |

入力素材 (PSD / スクリーンショットなど) は `cc-home/` に直接置くと、
コンテナ内から `~/...` でそのまま参照できる。

ホストから `cc-home/` を覗く・バックアップする・git で管理する、
どれも `sudo` も `docker exec` も不要。コンテナ内の `dev` ユーザは
`HOST_UID` / `HOST_GID` に合わせて作られるので、ファイル所有者がホスト
側と一致する。環境を一旦リセットしたいときは `rm -rf cc-home/` でよい
(次回起動時にデフォルトの `$HOME` がコンテナ側で再生成されるが、
ログイン状態と会話履歴は失われる)。

## ホストへの X11 転送

コンテナ内で起動した GUI アプリはホストの X サーバに表示される。
ホストにログインするたびに 1 度だけ次を実行する:

```bash
xhost +SI:localuser:$(id -un)        # 自分のユーザに :0 への接続を許可
```

compose 側で `/tmp/.X11-unix` と `$XAUTHORITY` を bind mount し、
`DISPLAY` はホスト環境から継承される。

Qt アプリ (qtvncgl platform plugin を使うものを含む) で動作確認済み。
mesa GLX が NVIDIA ドライバ不一致で失敗する場合は
`QT_QUICK_BACKEND=software` でソフトウェアレンダラに切り替えれば動く。

## MCP サーバ

3 つの MCP サーバが全バリアントに同梱されていて、`/usr/local/bin/` に
インストールされている:

| バイナリ            | upstream | 役割 |
| ------------------- | -------- | ---- |
| `mcp-design2gui`    | [signal-slot/mcp-design2gui](https://github.com/signal-slot/mcp-design2gui) | PSD / Figma を QML / Slint / Flutter に書き出すエクスポータ |
| `mcp-vnc`           | [signal-slot/mcp-vnc](https://github.com/signal-slot/mcp-vnc) | Qt アプリを MCP 経由で操作する VNC クライアント |
| `mcp-prompt-bridge` | [npm: mcp-prompt-bridge](https://www.npmjs.com/package/mcp-prompt-bridge) | 上流 MCP サーバの prompt を MCP tool として再公開するブリッジ |

設定ファイルは 2 つあり、片方を編集したらもう片方も手で同期する:

- `cc-home/.mcp.json` — Claude Code が読む
- `cc-home/.codex/config.toml` — Codex が読む

どちらの設定でも各サーバごとに同じ環境変数 (`DISPLAY`, `XAUTHORITY`,
`QT_PLUGIN_PATH=/usr/local/lib/qt6/plugins`) を渡す必要がある。
`QT_PLUGIN_PATH` は QtMcpServer の stdio plugin を Qt が見つけるために
必須で、設定し忘れると `mcp-vnc` と `mcp-design2gui` は起動時に
`"stdio" not found` で死に、MCP クライアントがタイムアウトする。Codex
は子プロセス起動時に親 env を全部剥がす実装なので、env ブロックを明示
しないと環境変数が伝わらない。

## Internals (内部仕様)

メンテナ向けの解説 — レイヤ順序、キャッシュ戦略、`additional_contexts`
の挙動、`patch-superbuild.sh` の役割など — は
[`docs/internals.ja.md`](docs/internals.ja.md) にまとめてある。

## 環境変数

| 変数名               | デフォルト                   | 用途 |
| -------------------- | ---------------------------- | ---- |
| `VARIANT`            | `qt`                         | `run` / `claude` / `codex` で使う Dockerfile ステージとイメージタグ |
| `HOST_UID`, `HOST_GID` | ホストユーザの `id -u` / `id -g` | コンテナ内の `dev` ユーザに焼き込んでファイル所有者を一致させる |
| `MCP_DESIGN2GUI_SRC` | `$HOME/src/mcp-design2gui`   | mcp-design2gui のローカル clone のパス |
| `MCP_DESIGN2GUI_REV` | 上記 clone の HEAD、または `dev` | design2gui 用キャッシュキー (build-arg) |
| `ANTHROPIC_API_KEY`  | 未設定                       | ホスト側で設定しているとコンテナに転送される |

これらは `make` コマンドにインラインで渡してもいいし、
`docker-compose.yml` の隣に `.env` ファイルを置いてまとめて指定しても
いい。

## トラブルシュート

| 症状                                       | 対処 |
| ------------------------------------------ | ---- |
| MCP の起動がタイムアウトする               | env ブロックに `QT_PLUGIN_PATH` が入っているか確認 (`config.toml` または `.mcp.json`) |
| X11 connection refused                     | ホスト側で `xhost +SI:localuser:$(id -un)` を実行 |
| コンテナを再起動するとログインが消える     | `cc-home/.claude.json` が UID 1000 で書き込み可能であること。`chown -R 1000:100 cc-home/` で直す |
| ビルド中に apt mirror がリトライを繰り返す | resolute (Ubuntu 26.04) のリポジトリは新しく、一部 mirror が不安定。1 つの遅いレイヤで約 10 分待てば通る (キャッシュ後は再発しない) |
| `make codex` が `stdin is not a terminal` で落ちる | 実 TTY のターミナルから起動する (CI パイプライン等からは起動できない) |
