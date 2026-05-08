FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Tokyo

# System + Qt6 dev (largest, slowest layer — heavy apt traffic).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
      git sudo locales tzdata xauth \
      build-essential cmake ninja-build pkg-config dpkg-dev \
      qt6-base-dev qt6-base-private-dev qt6-multimedia-dev \
      qt6-declarative-dev qt6-tools-dev qt6-tools-dev-tools \
      qml6-module-qtquick qml6-module-qtquick-controls \
      qml6-module-qtquick-window qml6-module-qtquick-effects \
      qml6-module-qtquick-templates qml6-module-qtquick-shapes \
      qml6-module-qtqml qml6-module-qtqml-workerscript \
      libgl-dev libegl-dev zlib1g-dev \
   && locale-gen en_US.UTF-8 ja_JP.UTF-8 \
   && rm -rf /var/lib/apt/lists/*

# Qt 6.5+ xcb platform plugin needs libxcb-cursor0 at runtime, and
# fonts-noto-cjk supplies Japanese glyphs (fontconfig falls back from
# "Source Han Sans" to Noto Sans CJK JP). Placed BEFORE the
# MCP_DESIGN2GUI_REV pivot so a design2gui rev bump never invalidates
# this slow apt layer (Ubuntu 26.04 mirrors retry for many minutes).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libxcb-cursor0 \
      fonts-noto-cjk fonts-noto-cjk-extra fontconfig \
 && fc-cache -fv \
 && rm -rf /var/lib/apt/lists/*

# Node.js 22 LTS for Claude Code CLI.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Helper: align submodule QT_REPO_MODULE_VERSION with system Qt and patch
# Debian/Ubuntu multiarch path layout for the superbuild.
COPY patch-superbuild.sh /usr/local/bin/patch-superbuild.sh
RUN chmod +x /usr/local/bin/patch-superbuild.sh

# Submodules in mcp-vnc / mcp-design2gui reference git@github.com:... URLs;
# rewrite to anonymous HTTPS so --recursive clone works without SSH keys.
RUN git config --global url."https://github.com/".insteadOf "git@github.com:"

# --- Build mcp-vnc ---
RUN git clone --recursive https://github.com/signal-slot/mcp-vnc /opt/mcp-vnc
WORKDIR /opt/mcp-vnc
RUN /usr/local/bin/patch-superbuild.sh 3rdparty/qtmcp/.cmake.conf 3rdparty/qtvncclient/.cmake.conf \
 && cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
 && cmake --build build \
 && install -m 755 build/mcp-vnc /usr/local/bin/mcp-vnc \
 && ARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH) \
 && cp -a build/qt_modules/lib/${ARCH}/libQt6*.so* /usr/local/lib/ \
 && mkdir -p /usr/local/lib/qt6/plugins \
 && cp -a build/qt_modules/lib/${ARCH}/qt6/plugins/* /usr/local/lib/qt6/plugins/ \
 && rm -rf /opt/mcp-vnc/build

# --- Build qtvncglplugin (GPU-accelerated VNC platform plugin) ---
# Installs libqvncgl.so into the system Qt's platform plugin dir so Qt can
# auto-discover it (run apps with `-platform vncgl`). Placed BEFORE the
# MCP_DESIGN2GUI_REV pivot so design2gui bumps don't reclone/rebuild it.
RUN git clone --recursive https://github.com/signal-slot/qtvncglplugin /opt/qtvncglplugin \
 && cd /opt/qtvncglplugin \
 && cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
 && cmake --build build \
 && cmake --install build \
 && rm -rf /opt/qtvncglplugin/build

# OpenAI Codex CLI alongside Claude Code. Placed just above the
# MCP_DESIGN2GUI_REV pivot so design2gui bumps don't reinstall it.
RUN npm install -g @openai/codex mcp-prompt-bridge

# === MCP_DESIGN2GUI_REV pivot =========================================
# Everything above this line stays cached when only MCP_DESIGN2GUI_REV
# changes. Below this line is rebuilt every time the rev bumps.
#
# Sources are injected from build context "mcp-design2gui-src", configured
# in docker-compose.yml's additional_contexts so we pick up uncommitted
# local changes. Bump rev from compose with:
#   MCP_DESIGN2GUI_REV=$(git -C <path-to-mcp-design2gui> rev-parse HEAD) \
#       docker compose build
# (Or use `make build` from this directory which does it for you.)
ARG MCP_DESIGN2GUI_REV=dev
LABEL design2gui_rev="$MCP_DESIGN2GUI_REV"
COPY --from=mcp-design2gui-src CMakeLists.txt /opt/mcp-design2gui/
COPY --from=mcp-design2gui-src src /opt/mcp-design2gui/src
COPY --from=mcp-design2gui-src external /opt/mcp-design2gui/external
WORKDIR /opt/mcp-design2gui
RUN /usr/local/bin/patch-superbuild.sh external/qtpsd/.cmake.conf external/qtmcp/.cmake.conf \
 && cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
 && cmake --build build \
 && install -m 755 build/mcp-design2gui /usr/local/bin/mcp-design2gui \
 && ARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH) \
 && cp -a build/qt_modules/lib/${ARCH}/libQt6*.so* /usr/local/lib/ \
 && cp -a build/qt_modules/lib/${ARCH}/qt6/plugins/* /usr/local/lib/qt6/plugins/ \
 && rm -rf /opt/mcp-design2gui/build \
 && ldconfig

# Non-root user matching host UID/GID. Drop any pre-existing user holding
# the requested UID (Ubuntu base ships with UID 1000) and reuse pre-existing
# groups (e.g. "users" at GID 100).
ARG UID=1000
ARG GID=1000
RUN set -e; \
    if id -u $UID >/dev/null 2>&1; then \
        existing=$(getent passwd $UID | cut -d: -f1); \
        if [ "$existing" != "dev" ]; then userdel -r "$existing" 2>/dev/null || true; fi; \
    fi; \
    if ! getent group $GID >/dev/null; then groupadd -g $GID dev; fi; \
    useradd -u $UID -g $GID -m -s /bin/bash dev; \
    echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev

USER dev
WORKDIR /home/dev

ENV LANG=ja_JP.UTF-8
ENV LC_ALL=ja_JP.UTF-8
ENV QT_X11_NO_MITSHM=1
ENV QT_PLUGIN_PATH=/usr/local/lib/qt6/plugins

CMD ["bash"]
