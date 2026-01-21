@echo off
title Discord Voice Node Patcher
echo ========================================
echo   Discord Voice Node Patcher Launcher
echo ========================================
echo.
echo Downloading latest version...
echo.
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/ProdHallow/Discord-Voice-Node-Patcher-For-Stereo/refs/heads/main/discord_voice_node_patcher_v2.1.ps1 | iex"
pause
