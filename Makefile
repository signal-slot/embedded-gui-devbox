# Build / run helpers for the embedded-gui-devbox Docker environment.
#
# Build variants (each maps to a Dockerfile stage of the same name):
#
#   make qt         Qt 6 only (base image, ~2.4 GB)
#   make slint      qt + Rust toolchain for Slint
#   make flutter    qt + Flutter SDK (Linux desktop precached, ~+1.3 GB)
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
# Override knobs:
#   VARIANT=slint                       make qt slint
#   MCP_DESIGN2GUI_SRC=/path/to/clone   make qt
#   MCP_DESIGN2GUI_REV=dev-$(date +%s)  make qt   # force cache-bust

MCP_DESIGN2GUI_SRC ?= $(HOME)/src/mcp-design2gui

# Resolve the build-arg used to invalidate the COPY layer for mcp-design2gui.
# Prefer an explicit override (MCP_DESIGN2GUI_REV=...), else use the local
# clone's HEAD commit hash. Falls back to "dev" when git is unavailable.
GIT_REV := $(shell git -C $(MCP_DESIGN2GUI_SRC) rev-parse HEAD 2>/dev/null)
MCP_DESIGN2GUI_REV ?= $(if $(GIT_REV),$(GIT_REV),dev)

VARIANT ?= qt

export HOST_UID := $(shell id -u)
export HOST_GID := $(shell id -g)
export MCP_DESIGN2GUI_SRC
export MCP_DESIGN2GUI_REV
export VARIANT

COMPOSE := docker compose
IMAGE_NAME := embedded-gui-devbox
TARGETS := qt slint flutter lvgl

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
	@echo ""
	@echo "Active design2gui rev: $(MCP_DESIGN2GUI_REV)"

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
