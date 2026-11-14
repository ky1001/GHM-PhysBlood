# Third-party material

The MIT licence in `LICENSE` covers GHM's own code in this repository: the Lua addon, the `ghmpb_*` shader
sources, the native module, the tools, the tests and the docs. These parts are not GHM's and keep their own terms:

| What | Where | Owner / terms |
|---|---|---|
| Source SDK shader headers `common_fxc.h`, `common_ps_fxc.h`, `common_vs_fxc.h`, `common_pragmas.h`, `common_hlsl_cpp_consts.h` | `shadersrc/` | Valve Corporation, from the Source SDK 2013, under the Source 1 SDK License. Included unchanged so the shaders can be compiled. |
| Garry's Mod module headers (`GarrysMod/Lua/Interface.h` and friends) | not included; the build fetches them | Facepunch Studios, [gmod-module-base](https://github.com/Facepunch/gmod-module-base) |

## Assets are not in this repository

Textures, models, the test map and the pre-baked fluid bursts (`materials/`, `models/`, `maps/`,
`data_static/ghmpb/vat/`) ship with the Steam Workshop addon only. Some of the splatter textures come from other
blood mods, so they are not covered by the MIT licence and are not redistributed here. To play, install the
Workshop addon: it has the same Lua as `addon/` plus these assets.

The Lua data tables `cl_spatterdata.lua` and `cl_crbdata.lua` hold shape measurements (droplet positions and sizes)
that `tools/make_ngb_spatter.py` and `tools/make_crb_spatter.py` measured from splatter textures; they contain no
image data.
