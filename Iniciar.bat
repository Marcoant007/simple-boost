@echo off
rem Abre o BLK Boost (pede permissao de administrador)
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0BlkBoost.ps1"
