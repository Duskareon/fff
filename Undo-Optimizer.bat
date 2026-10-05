@echo off
REM Double-click to revert every change made by Run-Optimizer.bat.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GamingPCOptimizer.ps1" -Undo
