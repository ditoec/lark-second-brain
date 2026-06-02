# scripts/lib.ps1 - Shared utility helpers for build orchestration
# Dot-sourced by scripts/build.ps1. Do NOT execute directly.

function info    { param([string]$Msg) Write-Host "[info] $Msg" -ForegroundColor Cyan }
function success { param([string]$Msg) Write-Host "[ok]   $Msg" -ForegroundColor Green }
function warn    { param([string]$Msg) Write-Host "[warn] $Msg" -ForegroundColor Yellow }
function die     { param([string]$Msg) Write-Host "[err]  $Msg" -ForegroundColor Red; exit 1 }
