$ErrorActionPreference = 'Continue'
$azd = 'C:\Program Files\Azure Dev CLI\azd.exe'
if (-not (Test-Path $azd)) { $azd = "$env:LOCALAPPDATA\Programs\Azure Dev CLI\azd.exe" }
$env:PATH = (Split-Path -Parent $azd) + ';' + $env:PATH
Set-Location 'C:\food-analytics'
Write-Output ((& $azd ai agent invoke --help 2>&1 | Out-String))
