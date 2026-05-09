# Internals

[English](internals.md) | 日本語

メンテナとコントリビュータ向けの実装メモ。コンテナを使うだけのユーザは
読まなくてよい (`make <variant> && make claude` で完結する)。

## マルチステージ構成

Dockerfile は `qt` ベースステージと、それを継承する 3 つの兄弟ステージで
構成されている:

```
ubuntu:26.04 ─→ qt ─┬─→ slint
                    ├─→ flutter
                    └─→ lvgl
```

BuildKit はステージごとにキャッシュするので、`qt` の重い処理 (apt、
Node.js セットアップ、mcp-vnc と mcp-design2gui の cmake ビルドなど) は
1 度だけ計算され、すべてのバリアントで再利用される。`qt` の上にツールを
追加したぐらいでは新ステージの段だけが invalidate されるだけで、ベース
までは遡らない。

## `qt` ステージのレイヤ順

`qt` の中身は「変わりにくい」→「変わりやすい」の順に積んである。日常の
開発サイクル (= mcp-design2gui の新コミットを取り込む) で再ビルドされる
のはステージの末尾だけになる:

| #  | 段                          | 内容 |
| -- | --------------------------- | ---- |
| 1  | apt                         | システム + Qt 6 開発パッケージ (最大・最安定) |
| 2  | apt                         | libxcb-cursor0 + fonts-noto-cjk |
| 3  | ARG `CLAUDE_CODE_VERSION` + npm | Node.js 22 + claude-code |
| 4  | COPY                        | patch-superbuild.sh ヘルパ |
| 5  | ARG `MCP_VNC_REV` + git + cmake | mcp-vnc clone + cmake build |
| 6  | ARG `QTVNCGLPLUGIN_REV` + git + cmake | qtvncglplugin clone + cmake build |
| 7  | ARG `CODEX_VERSION` / `MCP_PROMPT_BRIDGE_VERSION` + npm | codex + mcp-prompt-bridge |
| 8  | ARG `MCP_DESIGN2GUI_REV` + git + cmake | mcp-design2gui clone + cmake build |
| 9  | adduser                     | ホスト UID / GID に揃えたユーザ作成 |

各レイヤの上に置いた ARG が、そのレイヤの cache-bust スイッチになって
いる。Makefile は `docker compose build` を起動する前に ARG をそれぞれ
解決する (4 つの git リポジトリは `git ls-remote HEAD`、3 つの npm
パッケージは npm registry の HTTP API)。upstream が進むと該当 ARG の値
が変わり、BuildKit はそのレイヤとそれより下を invalidate して再取得
する。upstream が動いていなければキャッシュは末尾まで効いて、ビルドは
数秒で終わる。

`flutter` と `slint` の各バリアントステージも同じ仕組み:
`FLUTTER_REV` (`git ls-remote refs/heads/stable`) と
`RUST_TOOLCHAIN_VERSION` (rust-lang/rust の最新 GitHub release)。
`lvgl` バリアントは小さな apt 段の追加だけで、追跡対象の rev はない。

## コンポーネント別 cache-bust の仕組み

git ホスティングのコンポーネント (例として mcp-vnc; mcp-design2gui /
qtvncglplugin / flutter も同じ要領):

```dockerfile
ARG MCP_VNC_REV=main
RUN git clone --recursive https://github.com/signal-slot/mcp-vnc /opt/mcp-vnc \
 && cd /opt/mcp-vnc \
 && git checkout "${MCP_VNC_REV:-main}" \
 && git submodule update --init --recursive
```

Makefile は upstream の最新コミット SHA を渡す:

```makefile
MCP_VNC_REV ?= $(shell git ls-remote https://github.com/signal-slot/mcp-vnc HEAD | cut -f1)
```

`MCP_VNC_REV` は RUN コマンドから参照されているので、BuildKit はこの
ARG 値をレイヤのキャッシュキーに織り込む。upstream の HEAD が変わる ⇒
ARG 値が変わる ⇒ キャッシュミス ⇒ clone と checkout がやり直される。
HEAD が同じ ⇒ ARG が同じ ⇒ キャッシュヒット、何も走らない。

npm ホスティングのコンポーネント (claude-code / codex /
mcp-prompt-bridge):

```dockerfile
ARG CLAUDE_CODE_VERSION=
RUN npm install -g @anthropic-ai/claude-code${CLAUDE_CODE_VERSION:+@${CLAUDE_CODE_VERSION}}
```

```makefile
CLAUDE_CODE_VERSION ?= $(shell curl -sfL https://registry.npmjs.org/@anthropic-ai/claude-code/latest | ...)
```

考え方は同じ: Makefile が引いてきたバージョン文字列が RUN 行に
埋め込まれるので、新バージョンが publish されるたびに BuildKit の
キャッシュキーが変わる。

これらのクエリは Makefile がビルド系のターゲット (`make qt` /
`slint` / `flutter` / `lvgl` / `rebuild`) を実行するときだけ走る。
`make help` / `clean` / `run` / `claude` / `codex` ではネットワーク
往復は一切発生しない。

## `patch-superbuild.sh`

`mcp-vnc` と `mcp-design2gui` はどちらも CMake superbuild で、小ぶりな
Qt モジュール (`qtmcp`, `qtpsd`, `qtvncclient`) を ExternalProject
として同梱している。これらのサブビルドは `lib/qt6/` や `include/qt6/`
といった、upstream Qt の標準的なパスを前提にしている。

ところが Ubuntu (ほか Debian 系) のシステム Qt は multiarch パスに
入る (`lib/x86_64-linux-gnu/` と `include/x86_64-linux-gnu/qt6/`)。
`patch-superbuild.sh` は superbuild のパス前提を multiarch レイアウトに
書き換え、各 submodule の `QT_REPO_MODULE_VERSION` をシステム Qt の
バージョンに揃える (バージョン不一致で qtmcp / qtpsd の configure が
失敗するのを防ぐ)。

このパッチがないと内側の ExternalProject ビルドがホスト Qt のヘッダや
cmake configs を見つけられず、ビルドが落ちる。

## upstream の変更を取り込む

git ・ npm のいずれにしても、追跡対象コンポーネントの更新フローは同じ:

1. upstream に push / publish する。
2. `make qt` (普段使っているバリアントでよい)。
3. Makefile が `ls-remote HEAD` (または npm registry の `latest`) を
   引き直し、新しい値を ARG としてビルドに渡す。
4. BuildKit は影響のあるレイヤだけ invalidate し、新しいコミット /
   バージョンを取得して下流まで再ビルドする。

upstream を追わずに特定リビジョンに pin したいときは、対応する環境
変数を上書きする:

```bash
MCP_DESIGN2GUI_REV=abc123 make qt
CLAUDE_CODE_VERSION=2.1.126 make qt
```

キャッシュ周りで何かおかしいとき (壊れたレイヤ、cache-bust 機構が
追えていないコンポーネントなど) はフルリビルドで強制的に作り直す:

```bash
make rebuild      # docker compose build --no-cache
```
