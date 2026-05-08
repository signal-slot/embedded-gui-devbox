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
| 3  | NodeSource + apt + npm     | Node.js 22 + claude-code |
| 4  | COPY                       | patch-superbuild.sh helper |
| 5  | git + cmake                | mcp-vnc clone + cmake build |
| 6  | git + cmake                | qtvncglplugin clone + cmake build |
| 7  | npm                        | codex + mcp-prompt-bridge |
| **8** | **ARG MCP_DESIGN2GUI_REV** | **cache-bust boundary** |
| 9  | COPY + cmake               | mcp-design2gui sources + cmake build |
| 10 | adduser                    | UID / GID-aware user setup |

Bumping `MCP_DESIGN2GUI_REV` invalidates steps 9–10 only (~90 s). Every
other change (apt, Node, mcp-vnc, qtvncgl, codex / prompt-bridge,
`patch-superbuild.sh`) sits above the boundary and is shared across all
variant stages.

## mcp-design2gui via BuildKit `additional_contexts`

mcp-design2gui sources are *not* cloned at build time — they are
injected from a local clone via BuildKit's `additional_contexts`:

```yaml
# docker-compose.yml
build:
  additional_contexts:
    mcp-design2gui-src: ${MCP_DESIGN2GUI_SRC:-${HOME}/src/mcp-design2gui}
```

The Dockerfile then COPYs from that named context:

```dockerfile
COPY --from=mcp-design2gui-src CMakeLists.txt /opt/mcp-design2gui/
COPY --from=mcp-design2gui-src src /opt/mcp-design2gui/src
COPY --from=mcp-design2gui-src external /opt/mcp-design2gui/external
```

Two implications:

1. The COPY layer's cache is keyed by source content. In principle
   BuildKit hashes file contents, so committed changes propagate
   automatically.
2. In practice, BuildKit's hashing of local-path `additional_contexts`
   isn't always reliable. The `ARG MCP_DESIGN2GUI_REV` placed
   immediately above the COPY guarantees an explicit cache-bust: the
   Makefile resolves it from the local clone's `git rev-parse HEAD`, so
   a new HEAD always invalidates the COPY layer regardless of what
   BuildKit thinks.

Uncommitted changes are not picked up by this mechanism — they share a
HEAD with the parent commit and so map to the same cache key. For
one-off testing of a dirty tree, override the rev manually:

```bash
MCP_DESIGN2GUI_REV=dev-$(date +%s) make qt
```

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
