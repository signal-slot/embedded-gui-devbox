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
| 3  | NodeSource + apt + npm      | Node.js 22 + claude-code |
| 4  | COPY                        | patch-superbuild.sh ヘルパ |
| 5  | git + cmake                 | mcp-vnc clone + cmake build |
| 6  | git + cmake                 | qtvncglplugin clone + cmake build |
| 7  | npm                         | codex + mcp-prompt-bridge |
| **8** | **ARG MCP_DESIGN2GUI_REV** | **cache-bust の境界** |
| 9  | COPY + cmake                | mcp-design2gui のソース + cmake build |
| 10 | adduser                     | ホスト UID / GID に揃えたユーザ作成 |

`MCP_DESIGN2GUI_REV` を bump すると 9〜10 だけが invalidate される
(約 90 秒)。それ以外の変更 (apt、Node、mcp-vnc、qtvncgl、codex /
prompt-bridge、`patch-superbuild.sh`) は境界より上にあり、すべての
バリアントステージとキャッシュを共有したまま。

## mcp-design2gui を BuildKit `additional_contexts` で取り込む

mcp-design2gui のソースはビルド時に clone するのではなく、BuildKit の
`additional_contexts` でローカル clone から取り込んでいる:

```yaml
# docker-compose.yml
build:
  additional_contexts:
    mcp-design2gui-src: ${MCP_DESIGN2GUI_SRC:-${HOME}/src/mcp-design2gui}
```

Dockerfile はその名前付きコンテキストから COPY する:

```dockerfile
COPY --from=mcp-design2gui-src CMakeLists.txt /opt/mcp-design2gui/
COPY --from=mcp-design2gui-src src /opt/mcp-design2gui/src
COPY --from=mcp-design2gui-src external /opt/mcp-design2gui/external
```

ここには 2 つの含意がある:

1. COPY レイヤのキャッシュキーはソースの内容ハッシュ。原理的には
   BuildKit がファイル内容をハッシュするので、コミット済の変更は自動で
   反映される。
2. 実際には、ローカルパスの `additional_contexts` に対する BuildKit の
   ハッシュ計算は変更を確実に拾わないことがある。COPY のすぐ上に置いた
   `ARG MCP_DESIGN2GUI_REV` が確実な cache-bust を保証する: Makefile が
   ローカル clone の `git rev-parse HEAD` を渡すので、HEAD 値が変われば
   BuildKit の判定がどうであれ COPY レイヤが invalidate される。

未コミットの変更はこの仕組みでは検出されない (HEAD は親コミットと同じ
ままなのでキャッシュキーが変わらない)。ダーティな作業ツリーをそのまま
試したいときは、cache key を手動で 1 回 bump する:

```bash
MCP_DESIGN2GUI_REV=dev-$(date +%s) make qt
```

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
