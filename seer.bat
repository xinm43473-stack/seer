@echo off
chcp 65001 >nul
title Seer XM launcher
cd /d "%~dp0"

:: ===========================================================================
::  seer.bat -- entry point. All real work happens in seer_run.ps1.
::
::  THIS FILE IS PURE ASCII ON PURPOSE.
::  cmd.exe parses a .bat file before the code page change fully applies, and a
::  UTF-8 file with no BOM gets read with the ANSI code page. Chinese text here
::  therefore got tokenised into garbage and cmd tried to run fragments of it
::  ("'...' is not recognized as an internal or external command").
::  All Chinese output is printed by seer_run.ps1 instead, which sets its own
::  console encoding and is safe.
::
::  Required next to this file (2 files, no Python needed):
::    seer_run.ps1    main logic (waits, clicks, log watch, push)
::    click_ui.ps1    locates the buttons through UI Automation and clicks
:: ===========================================================================

set "BASE=%~dp0"

if not exist "%BASE%seer_run.ps1" (
  echo [ERROR] missing "%BASE%seer_run.ps1"
  pause
  exit /b 9
)
if not exist "%BASE%click_ui.ps1" (
  echo [ERROR] missing "%BASE%click_ui.ps1"
  pause
  exit /b 9
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%seer_run.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
echo ------------------------------------------------------------
echo  finished, exit code %RC%
echo ------------------------------------------------------------
echo.
pause
exit /b %RC%
