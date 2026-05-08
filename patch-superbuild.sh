#!/bin/bash
# Align submodule QT_REPO_MODULE_VERSION with system Qt and patch
# Debian/Ubuntu multiarch path layout for the mcp-vnc / mcp-design2gui
# superbuild CMakeLists.txt at $PWD.
set -e

QT_VER=$(qmake6 -query QT_VERSION)

for cmake_conf in "$@"; do
    sed -i "s/QT_REPO_MODULE_VERSION \"[^\"]*\"/QT_REPO_MODULE_VERSION \"${QT_VER}\"/" \
        "$cmake_conf"
done

sed -i \
    -e 's|"${DEPS_INSTALL_PREFIX}/${QT_LIB_DIR_NAME}/cmake"|"${DEPS_INSTALL_PREFIX}/lib/${QT_LIB_DIR_NAME}/cmake"|' \
    -e 's|${DEPS_INSTALL_PREFIX}/include/qt6|${DEPS_INSTALL_PREFIX}/include/${QT_LIB_DIR_NAME}/qt6|' \
    CMakeLists.txt
