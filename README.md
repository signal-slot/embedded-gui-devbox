# embedded-gui-devbox

English | [日本語](README.ja.md)

Ubuntu 26.04 dev container for AI-assisted embedded GUI development.
Bundles two CLI coding agents (Claude Code + OpenAI Codex), a stack of
MCP servers tuned for design-to-code workflows, and Qt 6 build tooling.
A multi-stage Dockerfile carves out per-framework variants
(`qt` / `slint` / `flutter` / `lvgl`) so you only pull what you need.

> The Qt 6 runtime is in every variant. `mcp-vnc`, `mcp-design2gui`,
> and `qtvncglplugin` are all Qt 6 binaries, so Qt 6 is a hard runtime
> dependency for the MCP infrastructure even when your target
> framework is Slint, Flutter, or LVGL.

## Build variants

Each variant is a separate stage in the Dockerfile, all extending the
common `qt` base. Pick one with `make <variant>`:

| Variant | Image size | Adds |
| --- | --- | --- |
| `qt` | ~2.9 GB | base — Qt 6, claude/codex, MCP servers, qtvncgl |
| `slint` | ~3.5 GB | + Rust toolchain (rustup, system-wide) |
| `flutter` | ~4.8 GB | + Flutter stable + Linux desktop precache + Dart |
| `lvgl` | ~3.0 GB | + SDL2 dev libs for the LVGL desktop simulator |

```bash
make qt          # the base everyone shares
make slint       # for Slint Rust output from mcp-design2gui
make flutter     # for Flutter output
make lvgl        # for LVGL simulator builds
```

`run` / `claude` / `codex` default to the `qt` variant; override with
`VARIANT=...` to use a different one.

## What's in the `qt` base

- Qt 6 dev tools (`qt6-base-dev`, `qt6-declarative-dev`, `qml6-module-*`,
  `libxcb-cursor0`, `fonts-noto-cjk`)
- Node.js 22 LTS
- Claude Code CLI (`claude`) and OpenAI Codex CLI (`codex`)
- MCP servers
  - [`mcp-design2gui`](https://github.com/signal-slot/mcp-design2gui) —
    PSD / Figma → QML / Slint / Flutter exporter
  - [`mcp-vnc`](https://github.com/signal-slot/mcp-vnc) — VNC client
    driving Qt apps via the MCP protocol
  - [`mcp-prompt-bridge`](https://www.npmjs.com/package/mcp-prompt-bridge) —
    re-exposes upstream MCP prompts as MCP tools
- [`qtvncglplugin`](https://github.com/signal-slot/qtvncglplugin) —
  GPU-accelerated VNC platform plugin for Qt
- X11 forwarding to the host display

## Quick start

```bash
# one-time: clone mcp-design2gui where MCP_DESIGN2GUI_SRC points
# (default: $HOME/src/mcp-design2gui)
git clone --recursive https://github.com/signal-slot/mcp-design2gui $HOME/src/mcp-design2gui

# from this repo's root:
make qt          # build the qt variant
make run         # interactive bash inside the container
make claude      # launch Claude Code
make codex       # launch OpenAI Codex CLI
```

Switch variants on the fly with `VARIANT`:

```bash
VARIANT=slint make claude       # claude inside the slint variant
VARIANT=flutter make run        # interactive shell inside flutter
```

`make <variant>` resolves `MCP_DESIGN2GUI_REV` from the git HEAD of
`$MCP_DESIGN2GUI_SRC`. Bumps to that hash invalidate just the COPY +
cmake layers (~90s rebuild). Untouched layers (apt, Node, mcp-vnc,
qtvncgl, codex, prompt-bridge, plus per-variant tooling) stay cached.

When the `git rev-parse` cache key isn't enough (e.g. uncommitted local
changes), force a full rebuild of the active variant:

```bash
make rebuild     # docker compose build --no-cache (~10 min)
```

## Persistent state (`cc-home/`)

`cc-home/` is bind-mounted as `/home/dev` inside the container.
Everything the container writes to `$HOME` persists here:

| Path | Contents |
| --- | --- |
| `cc-home/.claude/` | claude code projects, history, credentials |
| `cc-home/.claude.json` | claude code main config |
| `cc-home/.mcp.json` | MCP server registrations (claude reads this) |
| `cc-home/.codex/` | codex config + sessions |

Drop any input artefacts (PSDs, screenshots, etc.) directly into
`cc-home/` to make them available at `~/...` inside the container.

Inspect or back up this directory directly from the host — no `sudo`
or `docker exec` needed (the in-container `dev` user is built to match
`HOST_UID` / `HOST_GID`, so file ownership lines up). Backing it up
into a *private* git repo is fine; never commit it to the public repo
(`.gitignore` is set up so this is hard to do by accident — only the
`cc-home/.gitkeep` placeholder is tracked).

To reset the env, `rm -rf cc-home/*` and run `make qt` again — the
Makefile recreates `cc-home/.mcp.json` from the repo template on the
next build. Login state and conversation history are gone, and the
`/home/dev` defaults from the image are *not* restored (bind-mounted
host directory, so the container's image-side `/home/dev` is shadowed
out).

## X11 forwarding to the host

GUI apps launched inside the container show up on the host's X server.
Required once per host login:

```bash
xhost +SI:localuser:$(id -un)        # allow this user to reach :0
```

The compose file bind-mounts `/tmp/.X11-unix` and `$XAUTHORITY`
automatically, and `DISPLAY` is inherited from the host's environment.

Caveats:

- `$XAUTHORITY` (or `~/.Xauthority`) must already exist on the host as
  a *file* with valid cookies (`xauth list` should print at least one
  entry). If neither exists, Docker silently creates an empty
  *directory* at the bind-mount source and the X11 handshake breaks.
- Codex strips parent env when it spawns MCP servers, so
  `cc-home/.codex/config.toml` and `cc-home/.mcp.json` hard-code
  `DISPLAY=:0`. On hosts where `$DISPLAY` is something else (SSH X
  forwarding gives you `:10` etc., Xwayland often `:1`, Wayland-only
  sessions have no X display at all), edit those two files to match,
  or fall back to `QT_QPA_PLATFORM=offscreen` per server if you don't
  need windows.

Verified to work for Qt apps, including those using the qtvncgl platform
plugin. Software fallback (`QT_QUICK_BACKEND=software`) handles the
NVIDIA-driver-mismatch case where mesa GLX fails.

## Security boundary

This container is a developer playground for AI coding agents — it's
deliberately permissive. Be aware that:

- `network_mode: host` exposes every port the container opens directly
  on the host, and lets the agents reach any service on `localhost`
  with no firewall in between.
- `/tmp/.X11-unix` and `$XAUTHORITY` are bind-mounted in. Anything
  inside the container can see and drive every X11 client on the
  host's display (keystrokes, screenshots, window contents).
- `ANTHROPIC_API_KEY` is forwarded if set on the host. The agents and
  any tool they spawn can read it.
- The in-container `dev` user has passwordless `sudo`. Combined with
  the bind-mounted `cc-home/`, an agent that decides to run `sudo` can
  modify any file inside `cc-home/` from the host's perspective too.

Don't run anything in here that you wouldn't trust on the host
session. If you want stricter isolation, drop `network_mode: host`,
remove the X11 mounts, and revoke the `dev` sudoers entry.

## MCP servers

Three MCP servers ship in every variant (`/usr/local/bin/`):

| Binary | Source | Role |
| --- | --- | --- |
| `mcp-design2gui` | [signal-slot/mcp-design2gui](https://github.com/signal-slot/mcp-design2gui) | PSD / Figma → QML / Slint / Flutter exporter |
| `mcp-vnc` | [signal-slot/mcp-vnc](https://github.com/signal-slot/mcp-vnc) | VNC client driving Qt apps via the MCP protocol |
| `mcp-prompt-bridge` | [npm: mcp-prompt-bridge](https://www.npmjs.com/package/mcp-prompt-bridge) | Re-exposes upstream MCP prompts as MCP tools |

They are wired in through two config files (kept in sync manually if you
edit one):

- `cc-home/.mcp.json` — consumed by `claude`
- `cc-home/.codex/config.toml` — consumed by `codex`

Both have the same essentials per-server (`DISPLAY`, `XAUTHORITY`, and
`QT_PLUGIN_PATH` for the QtMcpServer stdio plugin in
`/usr/local/lib/qt6`). Without `QT_PLUGIN_PATH`, mcp-vnc and
mcp-design2gui die at startup with `"stdio" not found` and the MCP
client times out — codex strips the parent env on spawn, so the explicit
env block is mandatory there.

## Internals

For maintainers / contributors: see [`docs/internals.md`](docs/internals.md)
for the multi-stage layout, `qt` layer ordering, the `additional_contexts`
plumbing for mcp-design2gui, and the role of `patch-superbuild.sh`.

## macOS (Apple Silicon / Intel)

The Makefile auto-detects Darwin via `uname -s` and swaps in
`docker-compose.mac.yml` + `.mcp.json.mac` instead of the Linux
defaults. Key differences from the Linux setup:

- No `network_mode: host` (Docker Desktop on Mac runs in a Linux VM,
  so `host` would scope to the VM, not the Mac).
- No X11 plumbing — claude / codex run in your terminal, MCP servers
  start with `QT_QPA_PLATFORM=offscreen` (no GUI rendering inside the
  container).
- Apple Silicon images build natively as `linux/arm64`; Docker
  Desktop's Rosetta-backed emulation handles the Intel path if you
  ever need it.
- macOS UID/GID is typically `501:20`; the build args follow `id -u`
  / `id -g` so file ownership lines up automatically.

Usage is the same as on Linux:

```bash
git clone --recursive https://github.com/signal-slot/mcp-design2gui $HOME/src/mcp-design2gui

make qt          # builds embedded-gui-devbox:qt natively for arm64
make claude
make codex
```

Caveats specific to Mac:
- If you later need to expose a service from the container (e.g. mcp-vnc
  acting as a server on `:5900`), add a `ports:` block to
  `docker-compose.mac.yml`.
- If you bring an existing `cc-home/` over from a Linux host, the
  Linux-flavoured `cc-home/.mcp.json` (with `DISPLAY` / `XAUTHORITY`)
  will still be there. Either delete `cc-home/.mcp.json` so the Mac
  template seeds a fresh one, or hand-edit it to drop the X11 entries.

## Knobs

| Env var | Default | Purpose |
| --- | --- | --- |
| `VARIANT` | `qt` | Selects the Dockerfile stage / image tag for `run` / `claude` / `codex` |
| `HOST_UID`, `HOST_GID` | `id -u` / `id -g` of the host user | Baked into the image so file ownership matches |
| `MCP_DESIGN2GUI_SRC` | `$HOME/src/mcp-design2gui` | Path to local mcp-design2gui clone |
| `MCP_DESIGN2GUI_REV` | HEAD of the above clone, or `dev` | Build-arg used as cache key for design2gui |
| `ANTHROPIC_API_KEY` | unset | Forwarded to the container if set on the host |

All of these can be passed inline or set in a `.env` file next to
`docker-compose.yml`.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| MCP startup timeout | check `QT_PLUGIN_PATH` is in the env block (`config.toml` or `.mcp.json`) |
| X11 connection refused | run `xhost +SI:localuser:$(id -un)` on the host |
| Login forgotten on container restart | `cc-home/.claude.json` must be writable by the in-container `dev` user; `chown -R $(id -u):$(id -g) cc-home/` to match the host user the image was built for |
| apt mirror retries during build | resolute repos are fresh, mirrors flake; let the build ride out the retries (one slow layer of ~10 min, cached afterwards) |
| `make codex` fails with `stdin is not a terminal` | run from a real interactive terminal, not from a tool / CI pipe |
