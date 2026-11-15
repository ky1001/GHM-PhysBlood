@echo off
rem ============================================================================================
rem  GHM PhysBlood - shader pack installer
rem
rem  A plain batch file: no PowerShell, no downloads, nothing encoded. Open it in Notepad to read it.
rem  It copies the files from the "garrysmod" folder next to it into your Garry's Mod folder:
rem    garrysmod\shaders\fxc\ghmpbb74_*.vcs           compiled shaders, source in shadersrc\ on GitHub
rem    garrysmod\lua\bin\gmcl_ghmpb_native_v5_*.dll    optional C++ droplet solver, source in native\ on GitHub
rem  It shows where it found Garry's Mod and asks before it copies anything. It deletes nothing.
rem  Older copies of these same files are replaced.
rem
rem  Source code: see README.txt
rem ============================================================================================
setlocal EnableExtensions EnableDelayedExpansion
title GHM PhysBlood - shader pack installer
set "HERE=%~dp0"
echo.
echo  GHM PhysBlood - shader pack installer
echo  -------------------------------------
echo.

if not exist "%HERE%garrysmod\shaders\fxc\ghmpbb74_surface_ps30.vcs" (
	echo  The shader files are not next to this file.
	echo  Extract the WHOLE zip into a folder first, then run this file from that folder.
	goto :done
)

call :findgmod
if not defined GMOD (
	echo  Garry's Mod was not found automatically.
	echo  Paste the path of your GarrysMod folder - the folder that contains gmod.exe - and press Enter.
	echo  Example: C:\Program Files ^(x86^)\Steam\steamapps\common\GarrysMod
	set /p "GMOD= Path: "
)
if defined GMOD set "GMOD=!GMOD:"=!"
if not defined GMOD goto :notfound
if not exist "!GMOD!\garrysmod\" goto :notfound

echo  Garry's Mod found at:
echo    !GMOD!
echo.
echo  This copies:
echo    61 shader files  to  !GMOD!\garrysmod\shaders\fxc\
echo     2 module files  to  !GMOD!\garrysmod\lua\bin\
echo.
choice /c YN /m " Copy the GHM PhysBlood shaders and native module there"
if errorlevel 2 (
	echo  Cancelled, nothing was changed.
	goto :done
)

tasklist /fi "imagename eq gmod.exe" 2>nul | find /i "gmod.exe" >nul
if not errorlevel 1 (
	echo  Garry's Mod is running. Close it first, then run this file again.
	goto :done
)

if not exist "!GMOD!\garrysmod\shaders\fxc\" mkdir "!GMOD!\garrysmod\shaders\fxc"
if not exist "!GMOD!\garrysmod\lua\bin\" mkdir "!GMOD!\garrysmod\lua\bin"
set "FAILED="
copy /y "%HERE%garrysmod\shaders\fxc\ghmpbb74_*.vcs" "!GMOD!\garrysmod\shaders\fxc\" >nul || set "FAILED=1"
copy /y "%HERE%garrysmod\lua\bin\gmcl_ghmpb_native_v5_win*.dll" "!GMOD!\garrysmod\lua\bin\" >nul || set "FAILED=1"

rem Legacy addon folders that carry an older copy of the shaders: replace those too, so no old one is loaded instead.
for /d %%D in ("!GMOD!\garrysmod\addons\*") do (
	if exist "%%~D\shaders\fxc\ghmpbb74_surface_ps30.vcs" (
		copy /y "%HERE%garrysmod\shaders\fxc\ghmpbb74_*.vcs" "%%~D\shaders\fxc\" >nul || set "FAILED=1"
		echo  Also updated the older copy in %%~D\shaders\fxc
	)
)

echo.
if defined FAILED (
	echo  [!] Some files could not be copied. Close Garry's Mod and run this file again.
	echo      If Garry's Mod is in Program Files, right-click this file and choose "Run as administrator".
) else (
	echo  Done. Start Garry's Mod.
	echo  ghmpb_shader_check in the console shows whether the shaders are installed.
)
goto :done

:notfound
echo.
echo  No Garry's Mod folder there. Nothing was changed.
echo  Manual install: copy the "garrysmod" folder from this zip over your GarrysMod folder.
goto :done

rem --------------------------------------------------------------------------------------------
rem  Finds Garry's Mod: the Steam folder from the registry, then every Steam library listed in
rem  steamapps\libraryfolders.vdf. Sets GMOD, or leaves it empty.
rem --------------------------------------------------------------------------------------------
:findgmod
set "GMOD="
set "STEAM="
for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Valve\Steam" /v SteamPath 2^>nul ^| find /i "SteamPath"') do set "STEAM=%%B"
if not defined STEAM for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\WOW6432Node\Valve\Steam" /v InstallPath 2^>nul ^| find /i "InstallPath"') do set "STEAM=%%B"
if not defined STEAM exit /b 0
set "STEAM=!STEAM:/=\!"
if exist "!STEAM!\steamapps\common\GarrysMod\garrysmod\" (
	set "GMOD=!STEAM!\steamapps\common\GarrysMod"
	exit /b 0
)
if not exist "!STEAM!\steamapps\libraryfolders.vdf" exit /b 0
for /f "usebackq tokens=1,*" %%A in (`findstr /i /c:"\"path\"" "!STEAM!\steamapps\libraryfolders.vdf"`) do (
	set "LIB=%%~B"
	set "LIB=!LIB:\\=\!"
	if not defined GMOD if exist "!LIB!\steamapps\common\GarrysMod\garrysmod\" set "GMOD=!LIB!\steamapps\common\GarrysMod"
)
exit /b 0

:done
echo.
pause
endlocal
