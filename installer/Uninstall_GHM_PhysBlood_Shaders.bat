@echo off
rem ============================================================================================
rem  GHM PhysBlood - shader pack uninstaller
rem
rem  A plain batch file: no PowerShell, no downloads, nothing encoded. Open it in Notepad to read it.
rem  It removes only the files the installer copied:
rem    garrysmod\shaders\fxc\ghmpbb74_*.vcs
rem    garrysmod\lua\bin\gmcl_ghmpb_native_v5_win32.dll and gmcl_ghmpb_native_v5_win64.dll
rem  It shows where it found Garry's Mod and asks first. Without these files the mod keeps working
rem  in its built-in Lite renderer.
rem ============================================================================================
setlocal EnableExtensions EnableDelayedExpansion
title GHM PhysBlood - shader pack uninstaller
echo.
echo  GHM PhysBlood - shader pack uninstaller
echo  ---------------------------------------
echo.

call :findgmod
if not defined GMOD (
	echo  Garry's Mod was not found automatically.
	echo  Paste the path of your GarrysMod folder - the folder that contains gmod.exe - and press Enter.
	set /p "GMOD= Path: "
)
if defined GMOD set "GMOD=!GMOD:"=!"
if not defined GMOD goto :notfound
if not exist "!GMOD!\garrysmod\" goto :notfound

echo  Garry's Mod found at:
echo    !GMOD!
echo.
echo  This removes:
echo    !GMOD!\garrysmod\shaders\fxc\ghmpbb74_*.vcs
echo    !GMOD!\garrysmod\lua\bin\gmcl_ghmpb_native_v5_win32.dll
echo    !GMOD!\garrysmod\lua\bin\gmcl_ghmpb_native_v5_win64.dll
echo.
choice /c YN /m " Remove them"
if errorlevel 2 (
	echo  Cancelled, nothing was changed.
	goto :done
)

if exist "!GMOD!\garrysmod\shaders\fxc\ghmpbb74_*.vcs" del /q "!GMOD!\garrysmod\shaders\fxc\ghmpbb74_*.vcs"
if exist "!GMOD!\garrysmod\lua\bin\gmcl_ghmpb_native_v5_win32.dll" del /q "!GMOD!\garrysmod\lua\bin\gmcl_ghmpb_native_v5_win32.dll"
if exist "!GMOD!\garrysmod\lua\bin\gmcl_ghmpb_native_v5_win64.dll" del /q "!GMOD!\garrysmod\lua\bin\gmcl_ghmpb_native_v5_win64.dll"

if exist "!GMOD!\garrysmod\lua\bin\gmcl_ghmpb_native_v5_win64.dll" (
	echo  [!] Some files are still there. Close Garry's Mod and run this file again.
) else (
	echo  Done. The mod now uses its Lite renderer.
)
goto :done

:notfound
echo.
echo  No Garry's Mod folder there. Nothing was changed.
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
