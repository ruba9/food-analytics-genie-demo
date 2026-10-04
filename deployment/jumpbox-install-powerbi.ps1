<#
.SYNOPSIS
    Installs Power BI Desktop on the jumpbox.

.DESCRIPTION
    Power BI Desktop has to run inside the VNet: the Databricks workspace has no public
    endpoint, so Desktop on a workstation cannot refresh the model.

    Installation is silent, but the rest of the workflow is not automatable. Opening the
    project, signing in to the Databricks connector and publishing all need an interactive
    session, so RDP to the VM afterwards.
#>
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$installed = Get-ChildItem 'C:\Program Files\Microsoft Power BI Desktop\bin\PBIDesktop.exe' -ErrorAction SilentlyContinue
if ($installed) {
    Write-Output "already installed: $($installed.VersionInfo.ProductVersion)"
    exit 0
}

$installer = Join-Path $env:TEMP 'PBIDesktopSetup_x64.exe'
Write-Output 'downloading Power BI Desktop...'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # aka.ms/pbiSingleInstaller returns the download page, not the binary.
    Invoke-WebRequest -Uri 'https://download.microsoft.com/download/8/8/0/880bca75-79dd-466a-927d-1abf1f5454b0/PBIDesktopSetup_x64.exe' `
        -OutFile $installer -UseBasicParsing -TimeoutSec 1800
}
catch {
    Write-Output ("download failed: " + $_.Exception.Message)
    exit 1
}

$size = [math]::Round((Get-Item $installer).Length / 1MB, 1)
Write-Output "downloaded: $size MB"
if ($size -lt 100) {
    Write-Output 'too small to be the installer; the URL probably returned a web page'
    exit 1
}

Write-Output 'installing (several minutes)...'
$p = Start-Process -FilePath $installer -ArgumentList '-quiet', '-norestart', 'ACCEPT_EULA=1' -Wait -PassThru
Write-Output ("installer exit code: " + $p.ExitCode)

Remove-Item $installer -Force -ErrorAction SilentlyContinue

$exe = 'C:\Program Files\Microsoft Power BI Desktop\bin\PBIDesktop.exe'
if (Test-Path $exe) {
    Write-Output ("installed: " + (Get-Item $exe).VersionInfo.ProductVersion)
}
else {
    Write-Output 'PBIDesktop.exe not found after install'
    exit 1
}
