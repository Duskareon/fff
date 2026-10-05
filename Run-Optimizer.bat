@echo off
REM Double-click to optimize. Asks for Administrator rights.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GamingPCOptimizer.ps1" %*
