# embedded-gui-devbox

[English](README.md) | 日本語

組み込み GUI 開発を AI エージェントで支援する Ubuntu 26.04 dev
container。2 つの CLI コーディングエージェント (Claude Code + OpenAI
Codex)、デザイン→コード変換用の MCP サーバ群、Qt 6 ビルドツールを同梱。
multi-stage Dockerfile でフレームワーク別の variant (`qt` / `slint` /
`flutter` / `lvgl`) を切り出してあり、必要なものだけ pull できる。

## ビルド variant

各 variant は Dockerfile の独立したステージで、すべて `qt` ベースを継承。
`make <variant>` で選択:

| Variant | イメージサイズ | 追加内容 |
| --- | --- | --- |
| `qt` | ~2.9 GB | ベース — Qt 6、claude/codex、MCP サーバ、qtvncgl |
| `slint` | ~3.5 GB | + Rust toolchain (rustup、システム全体) |
| `flutter` | ~4.8 GB | + Flutter stable + Linux desktop precache + Dart |
| `lvgl` | ~3.0 GB | + LVGL デスクトップ simulator 用 SDL2 dev libs |

```bash
make qt          # 全 variant 共通のベース
make slint       # mcp-design2gui の Slint Rust 出力用
make flutter     # Flutter 出力用
make lvgl        # LVGL simulator ビルド用
```

`run` / `claude` / `codex` は既定で `qt` variant を使う。`VARIANT=...`
で別 variant に切り替え可能。

## `qt` ベースの中身

- Qt 6 開発ツール (`qt6-base-dev`, `qt6-declarative-dev`, `qml6-module-*`,
  `libxcb-cursor0`, `fonts-noto-cjk`)
- Node.js 22 LTS
- Claude Code CLI (`claude`) と OpenAI Codex CLI (`codex`)
- MCP サーバ
  - `mcp-design2gui` — PSD / Figma → QML / Slint / Flutter エクスポータ
  - `mcp-vnc` — Qt アプリを MCP プロトコル経由で操作する VNC クライアント
  - `mcp-prompt-bridge` — 上流 MCP サーバの prompt を MCP tool として再公開
- `qtvncglplugin` — Qt 用 GPU アクセラレート VNC プラットフォームプラグイン
- ホストディスプレイへの X11 フォワーディング

## クイックスタート

```bash
# 一度だけ: MCP_DESIGN2GUI_SRC が指す場所に mcp-design2gui を clone
# (デフォルト: $HOME/src/mcp-design2gui)
git clone https://github.com/signal-slot/mcp-design2gui $HOME/src/mcp-design2gui

# このリポジトリのルートから:
make qt          # qt variant をビルド
make run         # コンテナ内で対話 bash
make claude      # Claude Code を起動
make codex       # OpenAI Codex CLI を起動
```

別 variant を一時的に使うなら `VARIANT` で上書き:

```bash
VARIANT=slint make claude       # slint variant 内で claude
VARIANT=flutter make run        # flutter variant の対話 shell
```

`make <variant>` は `$MCP_DESIGN2GUI_SRC` の git HEAD から
`MCP_DESIGN2GUI_REV` を解決する。HEAD が変わると COPY + cmake レイヤ
だけが invalidate される (約 90 秒の rebuild)。それ以外 (apt、Node、
mcp-vnc、qtvncgl、codex、prompt-bridge、各 variant の追加ツール) は
キャッシュ維持。

`git rev-parse` ベースのキャッシュキーで足りない場合 (uncommitted な
変更を取り込みたい等) はフルリビルド:

```bash
make rebuild     # docker compose build --no-cache (~10 分)
```

## 永続状態 (`cc-home/`)

`cc-home/` はコンテナ内の `/home/dev` に bind mount される。コンテナが
`$HOME` に書いたものはすべてここに残る:

| パス | 内容 |
| --- | --- |
| `cc-home/.claude/` | claude code のプロジェクト・履歴・認証情報 |
| `cc-home/.claude.json` | claude code のメイン設定 |
| `cc-home/.mcp.json` | MCP サーバ登録 (claude が読む) |
| `cc-home/.codex/` | codex の設定とセッション |

入力ファイル (PSD・スクリーンショット等) は `cc-home/` に直接置けば、
コンテナ内から `~/...` でアクセスできる。

ホストから `cc-home/` を直接見る・バックアップする・git で管理する、
すべて `sudo` も `docker exec` も不要 (コンテナ内 `dev` ユーザは
`HOST_UID` / `HOST_GID` に揃えて作られるので所有権が一致する)。環境を
初期化するなら `rm -rf cc-home/` (次回起動時にコンテナがホーム
デフォルトを再生成するが、ログイン状態と会話履歴は失われる)。

## ホスト X への画面転送

コンテナ内の GUI アプリはホストの X サーバに表示される。ホストに
ログインするたびに以下を 1 回:

```bash
xhost +SI:localuser:$(id -un)        # 自分のユーザに :0 への接続を許可
```

compose ファイルが `/tmp/.X11-unix` と `$XAUTHORITY` を bind mount し、
`DISPLAY` はホスト環境から継承される。

Qt アプリ (qtvncgl プラットフォームプラグインを含む) で動作確認済み。
mesa GLX が NVIDIA ドライバ不一致で失敗する場合は
`QT_QUICK_BACKEND=software` のソフトウェアフォールバックで対応。

## MCP サーバ

3 つの MCP サーバが全 variant に同梱される (`/usr/local/bin/`):

| バイナリ | 役割 |
| --- | --- |
| `mcp-design2gui` | PSD / Figma → QML / Slint / Flutter エクスポータ |
| `mcp-vnc` | Qt アプリを MCP 経由で操作する VNC クライアント |
| `mcp-prompt-bridge` | 上流 MCP サーバの prompt を MCP tool として再公開 |

設定は 2 ファイル (片方を編集したら手動で同期):

- `cc-home/.mcp.json` — `claude` が読む
- `cc-home/.codex/config.toml` — `codex` が読む

両方とも各サーバ用に同じ必須環境変数 (`DISPLAY`, `XAUTHORITY`,
`/usr/local/lib/qt6` の QtMcpServer stdio plugin 用 `QT_PLUGIN_PATH`)
を持たせる。`QT_PLUGIN_PATH` がないと mcp-vnc と mcp-design2gui は
起動時に `"stdio" not found` で死に、MCP クライアント側がタイムアウト
する。codex は子プロセス起動時に親 env を全部剥がすため、env ブロック
の明示記述は必須。

## Dockerfile レイヤ順序

`qt` ステージは「変わりにくい」→「変わりやすい」の順:

1. `apt` — システム + Qt 6 dev (最重・安定)
2. `apt` — `libxcb-cursor0` + `fonts-noto-cjk`
3. Node.js + claude-code
4. `patch-superbuild.sh` の COPY
5. mcp-vnc clone + cmake build
6. qtvncglplugin clone + cmake build
7. codex + mcp-prompt-bridge npm install
8. **`ARG MCP_DESIGN2GUI_REV` ピボット**
9. mcp-design2gui COPY (build context から) + cmake build
10. ユーザ設定 (ホスト UID / GID 反映)

`MCP_DESIGN2GUI_REV` の bump は 9〜10 だけを invalidate する。

`slint` / `flutter` / `lvgl` の各 variant は `FROM qt` で派生し、自分
の toolchain を上に追加。1〜10 のキャッシュは全 variant で共有される。

## ローカルコミットを取り込んで mcp-design2gui を更新する

mcp-design2gui のソースは BuildKit の `additional_contexts` 経由で
ローカル clone から注入される (`docker-compose.yml` で設定)。ローカル
clone でコミットしてから:

```bash
make qt          # Makefile が git rev-parse で新 HEAD を拾う
                 # (もしくは普段使っている variant)
```

uncommitted な変更はキャッシュキーに反映されない。コミットするか、
一時的にキャッシュキーを手動で bump:

```bash
MCP_DESIGN2GUI_REV=dev-$(date +%s) make qt
```

## mcp-vnc / qtvncglplugin の更新

両方ともビルド時に HTTPS で git clone (ローカルソースパターンなし)。
upstream への push を取り込むには:

```bash
git push          # upstream リポジトリ側で
make rebuild      # 再 clone のためフル --no-cache rebuild
```

## ノブ

| 環境変数 | デフォルト | 用途 |
| --- | --- | --- |
| `VARIANT` | `qt` | `run` / `claude` / `codex` で使う Dockerfile ステージ・イメージタグ |
| `HOST_UID`, `HOST_GID` | ホストユーザの `id -u` / `id -g` | イメージに焼き込んでファイル所有権を一致させる |
| `MCP_DESIGN2GUI_SRC` | `$HOME/src/mcp-design2gui` | mcp-design2gui ローカル clone のパス |
| `MCP_DESIGN2GUI_REV` | 上記 clone の HEAD、無ければ `dev` | design2gui のキャッシュキー用 build-arg |
| `ANTHROPIC_API_KEY` | 未設定 | ホストで設定されていればコンテナへ転送 |

これらはインライン指定でも、`docker-compose.yml` の隣に `.env` ファイル
で設定してもよい。

## トラブルシュート

| 症状 | 対応 |
| --- | --- |
| MCP の起動タイムアウト | env ブロックに `QT_PLUGIN_PATH` があるか確認 (`config.toml` か `.mcp.json`) |
| X11 connection refused | ホスト側で `xhost +SI:localuser:$(id -un)` を実行 |
| コンテナ再起動でログインが消える | `cc-home/.claude.json` が UID 1000 で書ける必要あり; `chown -R 1000:100 cc-home/` |
| ビルド中に apt mirror retry | resolute リポジトリは新しく mirror が一時的に不安定。1 つ重いレイヤで約 10 分待つ (キャッシュ後は再発しない) |
| `make codex` が `stdin is not a terminal` で落ちる | 実 TTY のターミナルから起動 (CI パイプライン等からは不可) |
