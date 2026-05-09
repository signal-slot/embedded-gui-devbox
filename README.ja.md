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

`make <variant>` を実行すると、Makefile が pin 可能な各コンポーネントの
upstream を問い合わせて (4 つの git リポジトリは `git ls-remote HEAD`、
3 つの npm CLI は npm registry HTTP API、Rust toolchain は GitHub
releases)、結果を ARG として build に流す。upstream が進んだ層だけが
rebuild され、それ以外はキャッシュ維持。なので「upstream に変化なし」の
ケースは end-to-end でキャッシュヒットして数秒、変化があれば該当層
だけ rebuild (mcp-design2gui で約 90 秒、他も同程度)。

キャッシュが信用できないと感じたら、active variant を full rebuild:

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

ホストから `cc-home/` を覗く・バックアップするのは `sudo` も
`docker exec` も不要 (コンテナ内 `dev` ユーザが `HOST_UID` /
`HOST_GID` に合わせて作られるため、ファイル所有者がホスト側と一致
する)。**プライベート** な git リポジトリにバックアップするのは構わない
が、公開リポにはコミットしないこと (`.gitignore` で `cc-home/.gitkeep`
だけが追跡されるよう設定済)。

環境を初期化するには `rm -rf cc-home/*` して `make qt` を再実行する。
Makefile が `cc-home/.mcp.json` をリポジトリのテンプレートから再生成
する。ログイン状態と会話履歴は失われ、image 側の `/home/dev`
デフォルトは復元されない (bind mount なので image の `/home/dev` は
表に出てこない)。

## ホストへの X11 転送

コンテナ内で起動した GUI アプリはホストの X サーバに表示される。
ホストにログインするたびに 1 度だけ次を実行する:

```bash
xhost +SI:localuser:$(id -un)        # 自分のユーザに :0 への接続を許可
```

compose 側で `/tmp/.X11-unix` と `$XAUTHORITY` を bind mount し、
`DISPLAY` はホスト環境から継承される。

注意点:

- `$XAUTHORITY` (なければ `~/.Xauthority`) はホスト側に **ファイル**
  として存在し、有効な cookie が入っている必要がある (`xauth list`
  で 1 件以上表示されること)。両方とも無いと Docker は無言で空の
  **ディレクトリ** を bind mount source に作成し、X11 ハンドシェイク
  が壊れる。
- Codex は MCP サーバを spawn するとき親 env を全部剥がすので、
  `cc-home/.codex/config.toml` と `cc-home/.mcp.json` には `DISPLAY=:0`
  が直書きしてある。`$DISPLAY` がそれ以外の値になるホスト
  (SSH X forwarding は `:10` など、Xwayland はよく `:1`、Wayland 専用
  セッションでは X display が無い) では、両ファイルを書き換えるか、
  ウィンドウが要らないサーバは `QT_QPA_PLATFORM=offscreen` に倒す。

Qt アプリ (qtvncgl platform plugin を使うものを含む) で動作確認済み。
mesa GLX が NVIDIA ドライバ不一致で失敗する場合は
`QT_QUICK_BACKEND=software` でソフトウェアレンダラに切り替えれば動く。

## セキュリティ境界

このコンテナは AI コーディングエージェントの開発環境として、意図的に
緩めの権限で動いている。以下を認識した上で使うこと:

- `network_mode: host` でコンテナが開いたポートはそのままホストに
  露出し、エージェントはホストの `localhost` のあらゆるサービスに
  ファイアウォール無しでアクセスできる。
- `/tmp/.X11-unix` と `$XAUTHORITY` を bind mount しているので、
  コンテナ内のあらゆるプロセスがホストの X11 クライアント全部を
  読めて操作できる (キー入力、スクリーンショット、ウィンドウ内容)。
- `ANTHROPIC_API_KEY` がホストで設定されていればコンテナに転送される。
  エージェントとそこから生まれた子プロセスは全部読める。
- コンテナ内 `dev` ユーザはパスワード無しの `sudo` を持つ。`cc-home/`
  が bind mount なので、エージェントが `sudo` を使うと結果的にホスト
  側の `cc-home/` 内ファイルも書き換えられる。

ホストセッションで触らせたくないものはコンテナにも触らせないこと。
より厳しく分離したい場合は `network_mode: host` を外し、X11 マウントを
外し、`dev` の sudoers エントリを削除する。

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

メンテナ向けの解説 — multi-stage 構成、`qt` ステージのレイヤ順、
`ls-remote` ベースのキャッシュ無効化、`patch-superbuild.sh` の役割
など — は [`docs/internals.ja.md`](docs/internals.ja.md) にまとめて
ある。

## macOS (Apple Silicon / Intel)

Makefile が `uname -s` で Darwin を検出し、Linux の代わりに
`docker-compose.mac.yml` と `.mcp.json.mac` を使うよう自動で切り替える。
Linux 版との主な違い:

- `network_mode: host` を外している (Docker Desktop は Linux VM 越しに
  動くので、`host` は VM のホスト = 仮想マシン内部を指すだけで Mac の
  ホスト網には届かない)。
- X11 関連を全部抜いている (`/tmp/.X11-unix` も `XAUTHORITY` も Mac には
  ない)。claude / codex はターミナルで完結し、MCP サーバは
  `QT_QPA_PLATFORM=offscreen` 起動 (コンテナ内 GUI レンダリング無し)。
- Apple Silicon ではネイティブに `linux/arm64` でビルドされる。Intel
  Mac では `linux/amd64`。Docker Desktop の Rosetta エミュレーションで
  どちらにも倒せる。
- macOS の UID/GID は典型的に `501:20`。ビルド引数は `id -u` / `id -g`
  を拾うので、ファイル所有権はホスト側と自動的に揃う。

使い方は Linux と同じ:

```bash
make qt          # arm64 ネイティブで embedded-gui-devbox:qt をビルド
make claude
make codex
```

Mac 特有の注意点:
- 後からコンテナ内のサービスを Mac 側に露出したくなった場合 (例:
  mcp-vnc を `:5900` でサーバとして公開する) は、`docker-compose.mac.yml`
  に `ports:` ブロックを足す。
- Linux で使っていた `cc-home/` をそのまま Mac に持ち込むと、Linux 用の
  `cc-home/.mcp.json` (`DISPLAY` / `XAUTHORITY` 入り) が残ったままになる。
  `cc-home/.mcp.json` を消して Mac 用テンプレートから再生成するか、
  手で X11 エントリを削るかのどちらかで対応する。

## 環境変数

| 変数名               | デフォルト                   | 用途 |
| -------------------- | ---------------------------- | ---- |
| `VARIANT`            | `qt`                         | `run` / `claude` / `codex` で使う Dockerfile ステージとイメージタグ |
| `HOST_UID`, `HOST_GID` | ホストユーザの `id -u` / `id -g` | コンテナ内の `dev` ユーザに焼き込んでファイル所有者を一致させる |
| `ANTHROPIC_API_KEY`  | 未設定                       | ホスト側で設定しているとコンテナに転送される |

Makefile はこれに加えて pinning 用の knob を自動解決する。デフォルトは
upstream の最新が入るが、特定 rev に固定したい場合は手動で上書き可能:
`MCP_VNC_REV` / `QTVNCGLPLUGIN_REV` / `MCP_DESIGN2GUI_REV` /
`FLUTTER_REV` / `CLAUDE_CODE_VERSION` / `CODEX_VERSION` /
`MCP_PROMPT_BRIDGE_VERSION` / `RUST_TOOLCHAIN_VERSION`。

これらは `make` コマンドにインラインで渡してもいいし、
`docker-compose.yml` の隣に `.env` ファイルを置いてまとめて指定しても
いい。

## トラブルシュート

| 症状                                       | 対処 |
| ------------------------------------------ | ---- |
| MCP の起動がタイムアウトする               | env ブロックに `QT_PLUGIN_PATH` が入っているか確認 (`config.toml` または `.mcp.json`) |
| X11 connection refused                     | ホスト側で `xhost +SI:localuser:$(id -un)` を実行 |
| コンテナを再起動するとログインが消える     | `cc-home/.claude.json` がコンテナ内 `dev` ユーザで書き込み可能であること。`chown -R $(id -u):$(id -g) cc-home/` でビルド時のホスト UID/GID に揃える |
| ビルド中に apt mirror がリトライを繰り返す | resolute (Ubuntu 26.04) のリポジトリは新しく、一部 mirror が不安定。1 つの遅いレイヤで約 10 分待てば通る (キャッシュ後は再発しない) |
| `make codex` が `stdin is not a terminal` で落ちる | 実 TTY のターミナルから起動する (CI パイプライン等からは起動できない) |
