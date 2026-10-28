@echo off
rem Lance l'Optimiseur Windows (demande les droits administrateur)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0OptimiseurWindows.ps1"
