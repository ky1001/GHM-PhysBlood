# GHM PhysBlood

Physically simulated blood for Garry's Mod: flying droplets with real drag and break-up, forensic spatter, blood that
flows, pools, clots and dries on the world and on bodies, footprints and smears.

- **Steam Workshop:** https://steamcommunity.com/sharedfiles/filedetails/?id=3828548254
- **Shader pack download:** [Releases](https://github.com/ky1001/GHM-PhysBlood/releases/latest)

This repository is the complete, readable source of the mod: the Lua addon (not obfuscated), the HLSL shaders, the
optional C++ module, the installer, the tools and the tests. The shader pack on the releases page is built from it by
GitHub Actions. It replaces the old Google Drive download.

## What is where

| Folder | What it is |
|---|---|
| `addon/ghm_physblood/` | The Garry's Mod addon: `lua/autorun/ghm_physblood.lua` loads every module in `lua/ghm_physblood/` (57 files, about 28,000 lines of Lua). Same code as the Workshop addon, without its textures and models. |
| `shadersrc/` | HLSL source of the GPU simulation and shading (Shader Model 3, Source SDK `screenspace_general` style). The core is in `ghmpb_sim_main.h`, `ghmpb_shade.h`, `ghmpb_surface_main.h`, `ghmpb_surf_split.h`, `ghmpb_body_main.h`, `ghmpb_common.h` and `ghmpb_dust.h`; the `*_ps30.hlsl` / `*_vs30.hlsl` files are thin wrappers. |
| `prebuilt/shaders/fxc/` | The 61 compiled shaders (`ghmpbb74_*.vcs`) that go into the Workshop addon and the shader pack. |
| `native/` | `ghm_physblood.cpp`: the optional droplet solver (`require("ghmpb_native_v5")`), and `build.sh` to build it. |
| `installer/` | The plain-batch installer and uninstaller that ship in the shader pack. |
| `tools/` | Pack builder, shader manifest writer, texture and spatter-data generators. |
| `tests/` | `mp_mock/`: a mocked GMod for LuaJIT with behaviour tests; `*.py`: NumPy reference of the cell solver. |
| `docs/` | The full manual (`README_1.25.1_full.md`), engineering notes and change logs. |

## The shader pack

Since 1.26.11 the compiled shaders ship inside the Workshop addon (Garry's Mod allows `shaders/fxc/*.vcs` in addons),
so the Workshop version needs no extra download. The Workshop does not allow DLLs, so the optional native module comes
only from this pack. The pack is also the fix for players who still have older loose shader copies in
`garrysmod/shaders/fxc` (those override the addon's files); the mod detects that and links here.

What the zip contains:

| File | What it does |
|---|---|
| `garrysmod/shaders/fxc/ghmpbb74_*.vcs` | Compiled GPU shaders. Garry's Mod loads them through its `screenspace_general` material; they run on the graphics card only. |
| `garrysmod/lua/bin/gmcl_ghmpb_native_v5_win32.dll`, `_win64.dll` | Optional droplet solver, built in GitHub Actions from `native/ghm_physblood.cpp`. It talks to the game only through the public GMod Lua API, imports nothing but `KERNEL32.dll` and `msvcrt.dll` (the build log prints the import table), and does no networking or file access. |
| `Install_GHM_PhysBlood_Shaders.bat` | Plain batch file (no PowerShell, nothing encoded, no downloads). Finds Garry's Mod, shows the folder, asks, then copies the two folders above. Deletes nothing. |
| `Uninstall_GHM_PhysBlood_Shaders.bat` | Removes exactly those files after asking. |
| `SHA256SUMS.txt` | Checksums of every file in the pack. |

**Install:** close Garry's Mod, extract the zip, then run `Install_GHM_PhysBlood_Shaders.bat` or copy the zip's
`garrysmod` folder over your GarrysMod folder (the one with `gmod.exe`). `ghmpb_shader_check` in the console shows
whether the shaders are installed.

**Check a download:** every release is built by the `Build` workflow from a tagged commit, and the release notes link
the build log and list the SHA-256 of the zip and the DLLs. Releases also carry a signed build-provenance attestation:

```
gh attestation verify GHM_PhysBlood_Shaders_<version>.zip --repo ky1001/GHM-PhysBlood
```

## Building

**Native module** (Linux or WSL, MinGW-w64):

```
sudo apt install mingw-w64
git clone https://github.com/Facepunch/gmod-module-base.git native/gmod-module-base
bash native/build.sh              # -> native/out/gmcl_ghmpb_native_v5_win32.dll / _win64.dll
bash tools/make_pack.sh           # -> dist/GHM_PhysBlood_Shaders_<version>.zip
```

**Shaders:** compile the `*_ps30.hlsl` / `*_vs30.hlsl` wrappers with Valve's ShaderCompile from the Source SDK 2013
(output prefix `ghmpbb74_`). The world film shaders (`surface`, `surfstatic`, `surfbase`, `surfcoat`) sit at the edge of
ps_3_0 and are compiled at optimisation level 1. After a shader change, run
`python3 tools/make_shader_manifest.py prebuilt/shaders/fxc addon/ghm_physblood/lua/ghm_physblood/sh_shaderver.lua <version> "<notes>"`
so the in-game check knows the new files.

**Tests** (LuaJIT): `cd tests/mp_mock && luajit test_client_lite.lua` (each `test_*.lua` runs on its own). They
were written for 1.26.8; a few pin older defaults and report failures on newer versions.

## Licence

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 GalaxyHighMarshal (GHM).
Valve's Source SDK shader headers in `shadersrc/` keep their own licence, and the Workshop assets are not part of this
repository: see [THIRD_PARTY.md](THIRD_PARTY.md).
