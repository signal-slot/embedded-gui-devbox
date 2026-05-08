# Build / run helpers for the cc-qt6-mcp Docker environment.
#
#   make build    Cache-aware rebuild. Bumps MCP_DESIGN2GUI_REV from the
#                 local mcp-design2gui git HEAD so committed changes are
#                 always picked up.
#   make rebuild  Full --no-cache rebuild (~10 min). Use when something
#                 fishy happens with the cache (e.g. uncommitted changes
#                 that the rev-based cache-bust can't catch).
#   make run      Interactive bash shell inside the container.
#   make claude   Launch Claude Code inside the container.
#   make codex    Launch OpenAI Codex CLI inside the container.
#   make clean    Remove the cc-qt6-mcp image.
#
# Override knobs:
#   MCP_DESIGN2GUI_SRC=/path/to/clone   make build
#   MCP_DESIGN2GUI_REV=dev-$(date +%s)  make build   # force cache-bust
#                                                    # (useful for dirty trees)

MCP_DESIGN2GUI_SRC ?= $(HOME)/src/mcp-design2gui

# Resolve the build-arg used to invalidate the COPY layer for mcp-design2gui.
# Prefer an explicit override (MCP_DESIGN2GUI_REV=...), else use the local
# clone's HEAD commit hash. Falls back to "dev" when git is unavailable.
GIT_REV := $(shell git -C $(MCP_DESIGN2GUI_SRC) rev-parse HEAD 2>/dev/null)
MCP_DESIGN2GUI_REV ?= $(if $(GIT_REV),$(GIT_REV),dev)

export HOST_UID := $(shell id -u)
export HOST_GID := $(shell id -g)
export MCP_DESIGN2GUI_SRC
export MCP_DESIGN2GUI_REV

COMPOSE := docker compose
IMAGE := cc-qt6-mcp:ubuntu-26.04

.PHONY: help build rebuild run claude codex clean

help:
	@echo "Targets:"
	@echo "  build    cache-aware build (MCP_DESIGN2GUI_REV=$(MCP_DESIGN2GUI_REV))"
	@echo "  rebuild  full --no-cache build"
	@echo "  run      interactive shell in container"
	@echo "  claude   launch Claude Code in container"
	@echo "  codex    launch OpenAI Codex CLI in container"
	@echo "  clean    remove image $(IMAGE)"

build:
	$(COMPOSE) build

rebuild:
	$(COMPOSE) build --no-cache

run:
	$(COMPOSE) run --rm cc bash

claude:
	$(COMPOSE) run --rm cc claude

codex:
	$(COMPOSE) run --rm cc codex

clean:
	-docker rmi $(IMAGE)
