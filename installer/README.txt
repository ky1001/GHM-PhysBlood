GHM PhysBlood - shader pack (version in the zip name)
=====================================================

The Steam Workshop cannot deliver compiled shaders (.vcs) or DLLs, so they come in this pack.
Without them the mod still works in its built-in Lite renderer.

Everything here is built from the public source code:
  __REPO_URL__

WHAT IS IN THIS ZIP
  garrysmod\shaders\fxc\ghmpbb74_*.vcs
      61 compiled GPU shaders (DirectX 9 _ps30/_vs30 and DirectX 11 _ps50/_vs50).
      Garry's Mod loads them through its screenspace_general material. They run on the graphics card
      only and cannot touch files, the network or the system. Source: shadersrc\ in the repository.
  garrysmod\lua\bin\gmcl_ghmpb_native_v5_win32.dll and _win64.dll
      Optional C++ droplet solver (drag, break-up, merging of flying drops), loaded by the mod with
      require("ghmpb_native_v5"). Built by GitHub Actions from native\ghm_physblood.cpp for every release.
      It only uses Garry's Mod's Lua API: no network, no file access. Without it the mod uses its Lua solver.
  Install_GHM_PhysBlood_Shaders.bat / Uninstall_GHM_PhysBlood_Shaders.bat
      Plain batch files. Open them in Notepad to read them. No PowerShell, nothing is downloaded.
  SHA256SUMS.txt
      SHA-256 checksums of every file in this pack.

INSTALL
  1. Close Garry's Mod.
  2. Extract this whole zip into a folder (anywhere).
  3. Either double-click Install_GHM_PhysBlood_Shaders.bat
       (it finds Garry's Mod, shows where, asks before copying, deletes nothing)
     or copy the "garrysmod" folder from the zip over your GarrysMod folder by hand
       (the folder that contains gmod.exe, usually
        C:\Program Files (x86)\Steam\steamapps\common\GarrysMod).
  4. Start Garry's Mod. Type ghmpb_status in the console to see which renderer runs.

UNINSTALL
  Double-click Uninstall_GHM_PhysBlood_Shaders.bat, or delete the files listed above.

LICENCE
  MIT, see LICENSE.txt. Copyright (c) 2026 GalaxyHighMarshal (GHM).
