#!/usr/bin/env bash
# Builds the web page, build-web/BanjoTooieRecompiled.html, from a clone and your ROM (BUILDING.md says what it needs
# and how to serve it):
#   tools/build_web.sh [path/to/Banjo-Tooie (USA).z64]
#   tools/build_web.sh --patches          the submodules and their patches alone: no ROM, only git, CMake and Python
# The ROM is needed once: its decompressed copy stays in build/. Safe to run again after a pull: every step skips what
# is done or redoes only what changed. Extra arguments for the page's CMake configure go in $WEB_CMAKE_ARGS (it runs
# once per build dir: delete build-web/build.ninja to configure again). --patches is for N64Recomp-browser's CI: it puts
# its own checkout at lib/N64Recomp-browser, which --patches leaves as it is, so a change there that stops patches/
# going in under its web patches is red there and not at this page's next build.
#
# The page needs its own recompiled code: N64Recomp patched by patches/N64Recomp.patch and by N64Recomp-browser, whose
# C writes the tail calls as return_calls and keeps the FPU's rounding mode for float-to-int conversions, which
# WebAssembly's own instructions can't. So this makes it from the ROM as tools/autostub.py does, into
# build/RecompiledFuncs-web, and the desktop's RecompiledFuncs/ is upstream N64Recomp's (README.md, Building). The audio
# microcode, rsp/n_aspMain.cpp, is RSPRecomp's, which neither patches, so the two builds share it.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
PATCHES_ONLY=false
if [ "${1:-}" = --patches ]; then
    PATCHES_ONLY=true
    shift
    # Every submodule update below, setup_deps.py's too, leaves lib/N64Recomp-browser alone.
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=submodule.lib/N64Recomp-browser.update GIT_CONFIG_VALUE_0=none
fi
ROM=${1:-}
step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nError: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- the submodules
# patches/ (tools/setup_deps.py), then N64Recomp-browser's web support on top: rt64 (with plume and hlslpp),
# N64ModernRuntime (with the N64Recomp in it, whose recomp.h the recompiled code includes) and RecompFrontend, and
# lib/N64Recomp, the recompiler. The web patches change some of the same lines, so once they are in setup_deps.py
# can't tell its own are: the submodules are patched from scratch whenever they aren't as this left them.
TOOLS="lib/N64Recomp lib/N64ModernRuntime lib/rt64 lib/RecompFrontend"
patched_state() {
    {
        cat patches/*.patch lib/N64Recomp-browser/patches/*.patch
        git submodule status --recursive
        for tool in $TOOLS; do
            git -C "$tool" diff HEAD
            git -C "$tool" submodule foreach --recursive -q 'git diff HEAD'
        done
    } | git hash-object --stdin
}
PATCHED=$(git rev-parse --git-dir)/web-patched
if [ "$(cat "$PATCHED" 2> /dev/null)" != "$(patched_state 2> /dev/null)" ]; then
    step "Patching the submodules"
    for tool in $TOOLS; do
        if [ -e "$tool/.git" ]; then
            git -C "$tool" submodule foreach --recursive -q 'git reset -q --hard && git clean -fdq'
            git -C "$tool" reset -q --hard
            git -C "$tool" clean -fdq
        fi
    done
    git submodule update --init --recursive
    python3 tools/setup_deps.py
    # Each project by itself, leaving out a file whose change patches/ already makes its own way, where the two
    # would conflict: thread_queue_remove's fix, which patches/N64ModernRuntime.patch makes with a null check too, and
    # the recompiler's jump tables read from another section, where patches/N64Recomp.patch rewrites that analysis.
    web_patch() { cmake -P lib/N64Recomp-browser/patches/apply.cmake "$@"; }
    web_patch rt64 lib/rt64
    web_patch plume lib/rt64/src/contrib/plume
    web_patch hlslpp lib/rt64/src/contrib/hlslpp
    web_patch N64ModernRuntime lib/N64ModernRuntime ultramodern/src/threadqueue.cpp
    web_patch N64Recomp lib/N64ModernRuntime/N64Recomp
    web_patch RecompFrontend lib/RecompFrontend
    web_patch N64Recomp lib/N64Recomp src/analysis.cpp
    # Not with --patches, whose lib/N64Recomp-browser can be a symbolic link, which git submodule status refuses.
    $PATCHES_ONLY || patched_state > "$PATCHED"
fi
if $PATCHES_ONLY; then
    printf '\nDone: the submodules are patched.\n'
    exit 0
fi

# ---------------------------------------------------------------- the recompiled code
step "Building the recompiler"
if [ ! -f build/N64Recomp/build.ninja ]; then
    cmake -S lib/N64Recomp -B build/N64Recomp -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="${HOST_CC:-clang}" -DCMAKE_CXX_COMPILER="${HOST_CXX:-clang++}" > /dev/null
fi
cmake --build build/N64Recomp --target N64RecompCLI RSPRecomp

if [ -n "$ROM" ]; then
    [ -f "$ROM" ] || fail "no file at $ROM."
    step "Decompressing your ROM into build/decompressed.us.z64"
    python3 tools/decompress_rom.py "$ROM" build/decompressed.us.z64
fi
[ -f build/decompressed.us.z64 ] || fail "no ROM yet. Run this with the path to your Banjo-Tooie (USA) ROM."

step "Recompiling the game"
# tools/gen_syms_toml.py reads the ROM with rabbitizer.
if [ ! -x build/venv/bin/python3 ]; then
    python3 -m venv build/venv
    build/venv/bin/pip install -q rabbitizer
fi
build/venv/bin/python3 tools/gen_syms_toml.py
# banjotooie.us.toml with its paths made relative to build/, where this copy goes, and the output its own.
sed -e 's|^output_func_path = .*|output_func_path = "RecompiledFuncs-web.new"|' \
    -e 's|= "build/|= "|' banjotooie.us.toml > build/banjotooie.us.web.toml
rm -rf build/RecompiledFuncs-web.new
mkdir -p build/RecompiledFuncs-web.new build/RecompiledFuncs-web
build/N64Recomp/N64Recomp build/banjotooie.us.web.toml > build/recompile-web.log 2>&1 ||
    { tail -20 build/recompile-web.log; fail "N64Recomp failed (build/recompile-web.log)."; }
# Only the files that changed are replaced, so the page's build recompiles only those.
for file in build/RecompiledFuncs-web.new/*; do
    cmp -s "$file" "build/RecompiledFuncs-web/${file##*/}" || cp "$file" build/RecompiledFuncs-web/
done
for file in build/RecompiledFuncs-web/*; do
    [ -e "build/RecompiledFuncs-web.new/${file##*/}" ] || rm "$file"
done
rm -rf build/RecompiledFuncs-web.new

step "Recompiling the audio microcode"
sed -e 's|^output_file_path = .*|output_file_path = "n_aspMain.cpp.new"|' \
    -e 's|= "build/|= "|' n_aspMain.us.toml > build/n_aspMain.us.web.toml
build/N64Recomp/RSPRecomp build/n_aspMain.us.web.toml > build/rsp-recompile.log 2>&1 ||
    { tail -20 build/rsp-recompile.log; fail "RSPRecomp failed (build/rsp-recompile.log)."; }
mkdir -p rsp
cmp -s build/n_aspMain.cpp.new rsp/n_aspMain.cpp || cp build/n_aspMain.cpp.new rsp/n_aspMain.cpp
rm build/n_aspMain.cpp.new

# ---------------------------------------------------------------- the page
step "Building the page"
# The Emscripten ports CMake finds and the build depends on.
embuilder build sdl2-mt freetype-legacysjlj > /dev/null
if [ ! -f build-web/build.ninja ]; then
    emcmake cmake -S . -B build-web -G Ninja -DCMAKE_BUILD_TYPE=Release ${WEB_CMAKE_ARGS:-}
fi
cmake --build build-web --target BanjoTooieRecompiled

printf '\nDone: %s/build-web/BanjoTooieRecompiled.html (BUILDING.md says how to serve it).\n' "$ROOT"
