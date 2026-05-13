param(
  [int]$ApiPort = 8000,
  [string]$AppClothingApiBaseUrl = ""
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
  $apiBase = $AppClothingApiBaseUrl
  if ([string]::IsNullOrWhiteSpace($apiBase)) {
    $apiBase = "http://10.0.2.2:$ApiPort"
  }
  flutter run --dart-define=CLOTHING_IMAGE_API_BASE_URL=$apiBase
}
finally {
  Pop-Location
}
