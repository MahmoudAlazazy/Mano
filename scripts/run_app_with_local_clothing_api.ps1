param(
  [int]$ApiPort = 8000
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$apiScript = Join-Path $PSScriptRoot "run_local_clothing_api.ps1"

Write-Host "[dev-stack] starting local clothing api in background..."
Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  "`"$apiScript`"",
  "-Port",
  "$ApiPort"
)

Write-Host "[dev-stack] running flutter app with local clothing api..."
Push-Location $root
try {
  flutter run --dart-define=CLOTHING_IMAGE_API_BASE_URL=http://10.0.2.2:$ApiPort
}
finally {
  Pop-Location
}
