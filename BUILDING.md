# Building the web page

This fork's `main` branch builds the game with [Emscripten](https://emscripten.org) into a page,
`BanjoTooieRecompiled.html`, that draws through WebGPU. The desktop build is upstream's, except that it makes its
recompiled code from your ROM, which upstream commits: README.md's Building section.

`lib/rt64`, `lib/N64ModernRuntime`, `lib/RecompFrontend` and `lib/N64Recomp` are upstream's, at the same commits, and
patched by `patches/` as upstream patches them (`tools/setup_deps.py`).
[N64Recomp-browser](https://github.com/n64hub/N64Recomp-browser) (`lib/N64Recomp-browser`) puts the web support
on top of those (its `patches/apply.cmake`) and makes the game a page (its `frontend/`). Where the two change the same
code, `tools/build_web.sh` leaves N64Recomp-browser's change out of that file: `thread_queue_remove`, which upstream's
runtime patch fixes too, and the recompiler's jump tables in another section, whose analysis upstream's N64Recomp
patch rewrites.

The page needs recompiled code of its own: the desktop's `RecompiledFuncs/` is C from upstream's N64Recomp, and the
page's comes from the web-patched one, which writes a tail call as a `return_call` and keeps the FPU's rounding mode
for float-to-int conversions (WebAssembly's own instructions only round to nearest). So `tools/build_web.sh` makes it
from your ROM into `build/RecompiledFuncs-web`, as `tools/autostub.py` makes upstream's.

Mods a player adds are off on the page (the live recompiler writes machine code, which a page can't load), so are
Exit (it would leave the page dead) and RT64's render to RAM (`src/main.cpp` says why).

## What it needs

- The US ROM of Banjo-Tooie, once: `build/decompressed.us.z64` is made from it and kept.
- The [Emscripten SDK](https://emscripten.org/docs/getting_started/downloads.html), installed and activated
  (`source emsdk_env.sh`).
- [naga](https://github.com/gfx-rs/wgpu/tree/trunk/naga) on `PATH` (`cargo install naga-cli`), which turns the shaders
  into WGSL, and `spirv-opt` ([SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools)), without which the shaders
  come out about twice the size.
- A host clang and clang++ for the recompiler (`HOST_CC` and `HOST_CXX` pick others), CMake 3.20+, Ninja, git and
  Python 3 with `venv` (the script installs rabbitizer into `build/venv`).
- [ccache](https://ccache.dev) on `PATH`, optional: a second build dir, or another checkout with `build-web` inside it,
  then compiles nothing that was compiled before.

It was built on Linux, in the Docker image N64Recomp-browser's README describes.

## Building

```bash
git clone --recursive https://github.com/n64hub/BanjoTooieRecompiled-web
cd BanjoTooieRecompiled-web
tools/build_web.sh "path/to/Banjo-Tooie (USA).z64"
```

Run again after a pull, without the ROM: each step skips what is done. `WEB_CMAKE_ARGS` goes to the configure
(`-DN64RECOMP_BROWSER_FAST_LINK=ON` for a quick link while trying something, never for a page people play).

`build-web` then holds `BanjoTooieRecompiled.html`, `.js`, `.wasm`, `.data` and `coi_serviceworker.js`. The page must
be cross-origin isolated: serve the folder with `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`, or on a host that can't set headers (GitHub Pages), as is, and
`coi_serviceworker.js` sets them after one reload. The player picks their ROM in the launcher; it, the settings and the
saves are kept in the browser's IndexedDB for that origin.

## The shaders

The page builds the game's shaders from `src/rt64_shaders.txt` (`RT64_PREBUILT_SHADER_LIST` in `CMakeLists.txt`), in
sections, one a world. In Chrome they are built in the background, and the game waits only when a frame
wants 4 or more that aren't built yet, under a small "Preparing graphics" indicator in a corner; Chrome keeps
them for the visits after. Firefox builds a pipeline in line with the rest of its GPU work, so there the game waits
instead: on its first frame for the list's boot, and for a world's section when a frame first wants 4 of its shaders.
Without them RT64 would draw with its ubershader meanwhile, which integrated graphics can't keep up with. A shader the
list missed is built behind the game, and the page remembers it and builds it with the rest on the next visit.

The list is recorded by code, not by hand: `tools/shader_plan.json` (written by `tools/make_plans.py`) is a plan for
N64Recomp-browser's `tools/record_shaders.mjs`, which boots the page, starts a new game and, for each section, sends
Banjo to the maps of one world with `tools/shader_survey.js`, looking around on each; then, a load each, to a world's
boss room or a room further in (`FURTHER` in `make_plans.py`), played about 25 s, which records into that world's
section. That script needs no change to
the game: a map change is a request the game's own code leaves in RAM, and the survey leaves the same one (its header
says where). To record again:

```bash
python3 tools/make_plans.py
node lib/N64Recomp-browser/tools/record_shaders.mjs tools/shader_plan.json build-web <rom> src/rt64_shaders.txt
```

then put back the list's header. The list's header says what was played.

## How it plays

How the page plays is recorded in N64Recomp-browser's
[plays.jsonl](https://github.com/n64hub/N64Recomp-browser/blob/main/plays.jsonl) and its
[games table](https://github.com/n64hub/N64Recomp-browser#games).

The desktop build (upstream's release, Windows, RTX 2070) runs the game at 30 frames a second at the first map of Jinjo
Village, Glitter Gulch Mine, Ordnance Storage, Mayahem Temple and Cloud Cuckooland, 12 in Terrydactyland and 10 in
Hailfire Peaks, and doesn't crash entering Ordnance Storage or Mayahem Temple.

In Terrydactyland, Grunty Industries, Hailfire Peaks, Cloud Cuckooland and Cauldron Keep the page draws 12-45 presents
a second in both browsers: the game's own rate there, which the desktop build shares. The game's frames come unevenly
there, while the GPU is 30-39% busy, so RT64 paces its presents to them (`presents paced to the game's frames`), one a
game frame, 12-14 a second in Hailfire Peaks.

The game draws about 1,700 batches a frame in Jinjo Village, 3-7 times Rush 2049's, and RT64 makes each one WebGPU
calls on the page's thread: a draw, its push constants and a bind group, and a texture set and pipeline where they
change, as the desktop build does. In Chrome with the CPU throttled 6 times (an RTX 5080, uncapped) that thread is 92%
busy with them and the page draws 72-93 presents a second, the slowest of the pages there; Firefox and an unthrottled
Chrome play it like the others. That is the game's draw count, not the web support's: N64Recomp-browser's
docs/findings.md (A page's thread in Chrome, throttled) has the trace and the counts.

In Firefox the first load's wasm fetch is cut off by `coi_serviceworker.js`'s reload, which the console shows as an
exception.

Render to RAM is off on the page: on, 200 s in Jinjo Village and Terrydactyland drew 48.6 presents a second with the
sound about 10,000 frames short, against 59.0 and none off (headless Chrome 155). With it off, RT64 made every tile
copy a new texture until rt64-web 8bea892: the game makes 4 a frame, and the page had 16,690 textures and 2.7 GB of
video memory after those 200 s, its frame rate falling. Now it keeps 4 copies and about 300 textures, 53 MB, flat.
