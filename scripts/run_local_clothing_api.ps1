param(
  [int]$Port = 8000
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$apiDir = Join-Path $root "tools\clothing_api"
$venvDir = Join-Path $apiDir ".venv"
$pythonExe = Join-Path $venvDir "Scripts\python.exe"

Write-Host "[clothing-api] project root: $root"
Write-Host "[clothing-api] api dir: $apiDir"

if (!(Test-Path $pythonExe)) {
  Write-Host "[clothing-api] creating virtual env..."
  python -m venv $venvDir
}

Write-Host "[clothing-api] installing dependencies..."
& $pythonExe -m pip install --upgrade pip | Out-Null
& $pythonExe -m pip install -r (Join-Path $apiDir "requirements.txt")

Write-Host "[clothing-api] starting on http://127.0.0.1:$Port"
Push-Location $apiDir
try {
  & $pythonExe -m uvicorn main:app --host 127.0.0.1 --port $Port --reload
}
finally {
  Pop-Location
}
