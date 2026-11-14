#!/bin/bash
# Builds the optional C++ droplet solver with MinGW-w64 (no MSVC needed). The module only uses the public
# GMod Lua C API (ILuaBase), so the MinGW build is ABI compatible with the MSVC built game.
#
# Needs: x86_64-w64-mingw32-g++ and i686-w64-mingw32-g++ (Debian/Ubuntu: apt install mingw-w64)
#        the Garry's Mod module headers from https://github.com/Facepunch/gmod-module-base
#        (cloned to native/gmod-module-base, or point GMOD_MODULE_BASE at your copy)
#
# Output: native/out/gmcl_ghmpb_native_v5_win64.dll (x86-64 branch of GMod)
#         native/out/gmcl_ghmpb_native_v5_win32.dll (main branch of GMod)
#   -> copy to garrysmod/lua/bin/
#
# GitHub Actions runs this same script for every release (.github/workflows/build.yml).
set -euo pipefail
cd "$(dirname "$0")"
BASE="${GMOD_MODULE_BASE:-gmod-module-base}"
if [ ! -f "$BASE/include/GarrysMod/Lua/Interface.h" ]; then
	echo "GMod module headers not found in $BASE"
	echo "  git clone https://github.com/Facepunch/gmod-module-base.git native/gmod-module-base"
	exit 1
fi
mkdir -p out
FLAGS="-std=c++17 -O2 -Wall -shared -static -static-libgcc -static-libstdc++ -s -I$BASE/include"
x86_64-w64-mingw32-g++ $FLAGS -o out/gmcl_ghmpb_native_v5_win64.dll ghm_physblood.cpp
i686-w64-mingw32-g++   $FLAGS -o out/gmcl_ghmpb_native_v5_win32.dll ghm_physblood.cpp
ls -la out/gmcl_*.dll
