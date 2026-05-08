cc-qt6-mcp — Ubuntu 26.04 / Qt 6 / Claude Code & Codex / MCP servers
=====================================================================

Containerized dev environment with:
  - Qt 6 dev tools (qt6-base-dev, qt6-declarative-dev, qml6-module-*,
    libxcb-cursor0, fonts-noto-cjk)
  - Node.js 22 LTS
  - Claude Code CLI (`claude`) and OpenAI Codex CLI (`codex`)
  - MCP servers: mcp-design2gui, mcp-vnc, mcp-prompt-bridge
  - qtvncglplugin (GPU-accelerated VNC platform plugin for Qt)
  - X11 forwarding to the host display (DISPLAY=:0)


Quick start
-----------

    cd docker/
    make build       # cache-aware rebuild
    make run         # interactive bash inside the container
    make claude      # launch Claude Code
    make codex       # launch OpenAI Codex CLI

`make build` resolves MCP_DESIGN2GUI_REV from the git HEAD of
`$MCP_DESIGN2GUI_SRC`; bumps to that hash invalidate just the COPY+cmake
layers (~90s rebuild). Untouched layers (apt, Node, mcp-vnc, qtvncgl,
codex, prompt-bridge) stay cached.

When a `git rev-parse` cache key isn't enough (e.g. uncommitted local
changes), force a full rebuild:

    make rebuild     # docker compose build --no-cache (~10 min)


Persistent state (cc-home/)
---------------------------

`cc-home/` is bind-mounted as `/home/dev` inside the container. Everything
the container writes to $HOME persists here:

    cc-home/.claude/         claude code projects, history, credentials
    cc-home/.claude.json     claude code main config
    cc-home/.mcp.json        MCP server registrations (claude reads this)
    cc-home/.codex/          codex config + sessions

Drop any input artefacts (PSDs, screenshots, etc.) directly into
`cc-home/` to make them available at `~/...` inside the container.

Inspect / back up / git-track this directory directly from the host —
no `sudo` or `docker exec` needed (the in-container `dev` user is built
to match `HOST_UID` / `HOST_GID`, so file ownership lines up).
Wipe the env with `rm -rf cc-home/` (the container repopulates HOME defaults
on next start, but you lose login state and conversation history).


X11 forwarding to the host
--------------------------

GUI apps launched inside the container show up on the host's X server.
Required once per host login:

    xhost +SI:localuser:$(id -un)        # allow this user to reach :0

The compose file bind-mounts /tmp/.X11-unix and $XAUTHORITY automatically,
and DISPLAY is inherited from the host's environment.

Verified to work for Qt apps, including those using the qtvncgl platform
plugin. Software fallback (`QT_QUICK_BACKEND=software`) handles the
NVIDIA-driver-mismatch case where mesa GLX fails.


MCP servers
-----------

Three MCP servers ship in the image (`/usr/local/bin/`):

    mcp-design2gui     PSD/Figma → QML/Slint/Flutter exporter
    mcp-vnc            VNC client driving Qt apps via the MCP protocol
    mcp-prompt-bridge  Re-exposes upstream MCP prompts as MCP tools

They are wired in through two config files (kept in sync manually if you
edit one — see below):

    cc-home/.mcp.json          consumed by claude
    cc-home/.codex/config.toml consumed by codex

Both have the same essentials per-server (DISPLAY, XAUTHORITY, and
QT_PLUGIN_PATH for the QtMcpServer stdio plugin in /usr/local/lib/qt6).
Without QT_PLUGIN_PATH, mcp-vnc and mcp-design2gui die at startup with
'"stdio" not found' and the MCP client times out — codex strips the parent
env on spawn, so the explicit env block is mandatory there.


Layer ordering (Dockerfile)
---------------------------

Layers are ordered from "rarely changes" to "changes most":

    1. apt: system + Qt6 dev (longest, very stable)
    2. apt: libxcb-cursor0 + fonts-noto-cjk
    3. Node.js + claude-code
    4. patch-superbuild.sh COPY
    5. mcp-vnc clone + cmake build
    6. qtvncglplugin clone + cmake build
    7. codex + mcp-prompt-bridge npm install
    --- ARG MCP_DESIGN2GUI_REV pivot ------------------------
    8. mcp-design2gui COPY (from build context) + cmake build
    9. user setup (matches host UID/GID)

Bumping `MCP_DESIGN2GUI_REV` invalidates only steps 8-9.


Updating mcp-design2gui from local commits
------------------------------------------

mcp-design2gui sources are injected from the local clone via BuildKit's
`additional_contexts` (configured in docker-compose.yml). Commit the change
in the local clone, then:

    make build       # the Makefile picks up the new HEAD via git rev-parse

Uncommitted changes are not picked up by the cache key. Either commit, or
override the rev manually for one-shot testing:

    MCP_DESIGN2GUI_REV=dev-$(date +%s) make build


Updating mcp-vnc / qtvncglplugin
--------------------------------

Both are cloned over HTTPS at build time (no local-source pattern). To pick
up an upstream push:

    git push           # in the upstream repo
    make rebuild       # full --no-cache rebuild (the only way to re-clone)


Knobs
-----

  HOST_UID, HOST_GID         baked into the image so file ownership matches
                             (default: id -u / id -g of the host user)
  MCP_DESIGN2GUI_SRC         path to local mcp-design2gui clone
                             (default: $HOME/src/mcp-design2gui)
  MCP_DESIGN2GUI_REV         build-arg used as cache key for design2gui
                             (default: HEAD of the above clone, or "dev")
  ANTHROPIC_API_KEY          forwarded to the container if set on the host

All of these can be passed inline or set in a `.env` file next to
docker-compose.yml.


Troubleshooting
---------------

  MCP startup timeout      → check QT_PLUGIN_PATH is in the env block
                             (config.toml or .mcp.json)
  X11 connection refused   → run `xhost +SI:localuser:$(id -un)` on the host
  Login forgotten on
  container restart        → cc-home/.claude.json must be writable by
                             UID 1000; `chown -R 1000:100 cc-home/`
  apt mirror retries
  during build             → resolute repos are fresh, mirrors flake; let
                             `make build` ride out the retries (one slow
                             layer of ~10 min, cached afterwards)
  `make codex` fails with
  "stdin is not a terminal" → run from a real interactive terminal, not
                             from a tool/CI pipe
