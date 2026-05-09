# Internals

[English](internals.md) | [日本語](internals.ja.md)

Implementation notes for maintainers and contributors. End users of the
container don't need any of this — `make <variant> && make claude` is
the whole interface.

## Multi-stage layout

The Dockerfile is one base stage `qt` plus three siblings, each
`FROM qt`:

```
ubuntu:26.04 ─→ qt ─┬─→ slint
                    ├─→ flutter
                    └─→ lvgl
```

BuildKit caches per stage, so the heavy work inside `qt` (apt, Node.js,
the mcp-vnc and mcp-design2gui cmake builds, etc.) is computed once and
reused by every variant. Adding tooling on top of `qt` only invalidates
the new stage's own steps, not the base.

## `qt` stage layer order

Inside `qt`, steps are sequenced from "rarely changes" to "changes most
often", so the day-to-day work cycle (= a fresh mcp-design2gui commit)
only rebuilds the bottom of the stage:

| #  | Step                       | What it builds |
| -- | -------------------------- | -------------- |
| 1  | apt                        | system + Qt 6 dev (largest, very stable) |
| 2  | apt                        | libxcb-cursor0 + fonts-noto-cjk |
| 3  | ARG `CLAUDE_CODE_VERSION` + npm | Node.js 22 + claude-code |
| 4  | COPY                       | patch-superbuild.sh helper |
| 5  | ARG `MCP_VNC_REV` + git + cmake | mcp-vnc clone + cmake build |
| 6  | ARG `QTVNCGLPLUGIN_REV` + git + cmake | qtvncglplugin clone + cmake build |
| 7  | ARG `CODEX_VERSION` / `MCP_PROMPT_BRIDGE_VERSION` + npm | codex + mcp-prompt-bridge |
| 8  | ARG `MCP_DESIGN2GUI_REV` + git + cmake | mcp-design2gui clone + cmake build |
| 9  | adduser                    | UID / GID-aware user setup |

Each ARG above its layer is a cache-bust knob. The Makefile resolves
each one before invoking `docker compose build` (`git ls-remote HEAD`
for the four git repos; the npm registry HTTP API for the three CLI
packages). When upstream advances, the corresponding ARG value changes,
BuildKit invalidates that layer + everything below, and the layer is
re-fetched from upstream. When upstream is unchanged, the cache holds
end-to-end and the build finishes in seconds.

The `flutter` and `slint` variant stages each get the same treatment:
`FLUTTER_REV` (`git ls-remote refs/heads/stable`) and
`RUST_TOOLCHAIN_VERSION` (the latest GitHub release on rust-lang/rust).
The `lvgl` variant only adds a small apt step, no rev to track.

## How the per-component cache-bust works

For a git-hosted component (here: mcp-vnc; mcp-design2gui /
qtvncglplugin / flutter follow the same pattern):

```dockerfile
ARG MCP_VNC_REV=main
RUN git clone --recursive https://github.com/signal-slot/mcp-vnc /opt/mcp-vnc \
 && cd /opt/mcp-vnc \
 && git checkout "${MCP_VNC_REV:-main}" \
 && git submodule update --init --recursive
```

The Makefile passes the latest commit SHA from upstream:

```makefile
MCP_VNC_REV ?= $(shell git ls-remote https://github.com/signal-slot/mcp-vnc HEAD | cut -f1)
```

`MCP_VNC_REV` is referenced in the RUN command, so BuildKit folds the
ARG value into the layer's cache key. A new upstream HEAD ⇒ different
ARG value ⇒ cache miss ⇒ fresh clone + checkout. An unchanged HEAD ⇒
identical ARG ⇒ cache hit, no work.

For npm-hosted components (claude-code / codex / mcp-prompt-bridge):

```dockerfile
ARG CLAUDE_CODE_VERSION=
RUN npm install -g @anthropic-ai/claude-code${CLAUDE_CODE_VERSION:+@${CLAUDE_CODE_VERSION}}
```

```makefile
CLAUDE_CODE_VERSION ?= $(shell curl -sfL https://registry.npmjs.org/@anthropic-ai/claude-code/latest | ...)
```

Same idea: the version queried by the Makefile is interpolated into the
RUN string, so BuildKit's cache key changes whenever a new version is
published.

The Makefile only runs these queries when a build target is on the
command line (`make qt|slint|flutter|lvgl|rebuild`); `make help` /
`clean` / `run` / `claude` / `codex` skip the network round-trips
entirely.

## `patch-superbuild.sh`

Both `mcp-vnc` and `mcp-design2gui` are CMake superbuilds that vendor
small Qt modules (`qtmcp`, `qtpsd`, `qtvncclient`) as ExternalProject
sub-builds. Those sub-builds expect Qt to live at upstream-style paths
such as `lib/qt6/` and `include/qt6/`.

Ubuntu (and other Debian derivatives) installs the system Qt at
multiarch paths instead — `lib/x86_64-linux-gnu/` and
`include/x86_64-linux-gnu/qt6/`. `patch-superbuild.sh` rewrites the
superbuild's path expectations to match, and aligns each submodule's
`QT_REPO_MODULE_VERSION` with the system Qt version so the
qtmcp / qtpsd configures don't bail on a version mismatch.

Without these patches the inner ExternalProject builds can't locate
their host Qt headers or cmake configs.

## Picking up upstream changes

For any pinnable component (git or npm), the workflow is the same:

1. Push / publish upstream.
2. Run `make qt` (or whichever variant you use day-to-day).
3. The Makefile re-queries `ls-remote HEAD` (or the npm registry's
   `latest`) and threads the new value into the build as an ARG.
4. BuildKit invalidates only the affected layer, fetches the new
   commit / version, and rebuilds downstream.

If you want to pin to a specific revision instead of tracking upstream,
override the corresponding env var:

```bash
MCP_DESIGN2GUI_REV=abc123 make qt
CLAUDE_CODE_VERSION=2.1.126 make qt
```

If something feels wrong with the cache (e.g. a corrupted layer or a
component the cache machinery doesn't track), do a full rebuild:

```bash
make rebuild      # docker compose build --no-cache
```
