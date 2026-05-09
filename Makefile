# Build / run helpers for the embedded-gui-devbox Docker environment.
#
# Build variants (each maps to a Dockerfile stage of the same name):
#
#   make qt         Qt 6 only (base image, ~2.9 GB)
#   make slint      qt + Rust toolchain for Slint
#   make flutter    qt + Flutter SDK (Linux desktop precached, ~+1.9 GB)
#   make lvgl       qt + SDL2 dev libs for the LVGL desktop simulator
#
# Run / use the active variant (defaults to qt; override with VARIANT=...):
#
#   make run                    interactive bash inside the container
#   make claude                 launch Claude Code
#   make codex                  launch OpenAI Codex CLI
#   VARIANT=slint make claude   same, in the Slint variant
#
# Misc:
#
#   make rebuild    full --no-cache build of the active variant
#   make clean      remove all built variant images
#
# Each build resolves the latest upstream rev / npm version for every
# pinnable component (mcp-vnc, qtvncglplugin, mcp-design2gui, claude-code,
# codex, mcp-prompt-bridge, rust-toolchain, flutter) and threads it
# through to the Dockerfile as an ARG. Layers whose ARG value didn't move
# stay cached; layers whose upstream advanced rebuild automatically.

VARIANT ?= qt

export HOST_UID := $(shell id -u)
export HOST_GID := $(shell id -g)
export VARIANT

# Pick the compose file and the .mcp.json bootstrap template based on
# the host OS. macOS skips X11 / host networking and runs MCP servers
# with QT_QPA_PLATFORM=offscreen.
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
COMPOSE_FILE := docker-compose.mac.yml
MCP_TEMPLATE := .mcp.json.mac
else
COMPOSE_FILE := docker-compose.yml
MCP_TEMPLATE := .mcp.json
endif

COMPOSE := docker compose -f $(COMPOSE_FILE)
IMAGE_NAME := embedded-gui-devbox
TARGETS := qt slint flutter lvgl

# Only hit the network for upstream-rev queries when an actual build is
# requested — make help / clean / run / claude / codex shouldn't trigger
# external lookups. We use `:=` (immediate, one-time eval) for the
# shell calls; `$(or $(VAR),$(shell ...))` on the RHS preserves any
# value the user passed in via env / command line. With recursive `?=`,
# each `export` and each sub-shell make spawns would re-run the shell
# call, which compounds badly across 8 components.
NEED_REV_QUERY := $(filter $(TARGETS) rebuild,$(MAKECMDGOALS))
ifneq ($(NEED_REV_QUERY),)

# Latest commit on the default branch for each git-hosted component.
# Empty (network failure) falls back to the Dockerfile's "main" default.
MCP_VNC_REV        := $(or $(MCP_VNC_REV),$(shell git ls-remote https://github.com/signal-slot/mcp-vnc HEAD 2>/dev/null | cut -f1))
QTVNCGLPLUGIN_REV  := $(or $(QTVNCGLPLUGIN_REV),$(shell git ls-remote https://github.com/signal-slot/qtvncglplugin HEAD 2>/dev/null | cut -f1))
MCP_DESIGN2GUI_REV := $(or $(MCP_DESIGN2GUI_REV),$(shell git ls-remote https://github.com/signal-slot/mcp-design2gui HEAD 2>/dev/null | cut -f1))
FLUTTER_REV        := $(or $(FLUTTER_REV),$(shell git ls-remote https://github.com/flutter/flutter refs/heads/stable 2>/dev/null | cut -f1))

# Latest published version of each npm-hosted CLI / package, queried
# directly from the npm registry HTTP API (avoids requiring the npm CLI
# on the host).
CLAUDE_CODE_VERSION       := $(or $(CLAUDE_CODE_VERSION),$(shell curl -sfL https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4))
CODEX_VERSION             := $(or $(CODEX_VERSION),$(shell curl -sfL https://registry.npmjs.org/@openai/codex/latest 2>/dev/null | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4))
MCP_PROMPT_BRIDGE_VERSION := $(or $(MCP_PROMPT_BRIDGE_VERSION),$(shell curl -sfL https://registry.npmjs.org/mcp-prompt-bridge/latest 2>/dev/null | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4))

# Latest tagged Rust release (rust-lang/rust uses semver tags like 1.95.0
# on its release tarballs; the GitHub releases API surface them). Note
# that GitHub's API JSON has a space after the colon, so the extractor
# tolerates it.
RUST_TOOLCHAIN_VERSION    := $(or $(RUST_TOOLCHAIN_VERSION),$(shell curl -sfL https://api.github.com/repos/rust-lang/rust/releases/latest 2>/dev/null | grep -o '"tag_name":[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4))

endif

export MCP_VNC_REV QTVNCGLPLUGIN_REV MCP_DESIGN2GUI_REV FLUTTER_REV
export CLAUDE_CODE_VERSION CODEX_VERSION MCP_PROMPT_BRIDGE_VERSION
export RUST_TOOLCHAIN_VERSION

.PHONY: help $(TARGETS) rebuild run claude codex clean

help:
	@echo "Build variants:"
	@for t in $(TARGETS); do echo "  make $$t"; done
	@echo ""
	@echo "Run (defaults to VARIANT=$(VARIANT); override with e.g. VARIANT=slint):"
	@echo "  make run     interactive shell"
	@echo "  make claude  launch Claude Code"
	@echo "  make codex   launch OpenAI Codex CLI"
	@echo ""
	@echo "Misc:"
	@echo "  make rebuild  --no-cache rebuild of the active variant"
	@echo "  make clean    remove all built $(IMAGE_NAME):* images"

# Each variant target sets VARIANT=<itself> for the duration of one build.
# Bootstrap cc-home/.mcp.json from the repo's template on a fresh clone
# (cc-home/* is gitignored, so this file is missing on a fresh
# checkout). The Linux template wires X11; the macOS template falls
# back to QT_QPA_PLATFORM=offscreen.
$(TARGETS):
	@test -f cc-home/.mcp.json || cp $(MCP_TEMPLATE) cc-home/.mcp.json
	VARIANT=$@ $(COMPOSE) build

rebuild:
	$(COMPOSE) build --no-cache

run:
	$(COMPOSE) run --rm cc bash

claude:
	$(COMPOSE) run --rm cc claude

codex:
	$(COMPOSE) run --rm cc codex

clean:
	-for v in $(TARGETS); do docker rmi $(IMAGE_NAME):$$v 2>/dev/null; done
