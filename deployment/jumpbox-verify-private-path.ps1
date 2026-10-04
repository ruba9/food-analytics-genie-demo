param(
    [Parameter(Mandatory)] [string] $WorkspaceUrl
)

$ErrorActionPreference = 'Continue'

$hostName = ([uri]$WorkspaceUrl).Host

# A record cached before the private DNS zone existed will still return the public IP.
Clear-DnsClientCache
Write-Output ("dns servers: " + ((Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | ForEach-Object { $_.ServerAddresses }) -join ', '))

$dns = Resolve-DnsName $hostName -Type A -ErrorAction SilentlyContinue
$ips = @($dns | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
Write-Output ("resolved: " + ($ips -join ', '))

$private = @($ips | Where-Object { $_ -like '10.19.*' })
Write-Output ("private path: " + [bool]$private.Count)

$tcp = Test-NetConnection -ComputerName $hostName -Port 443 -WarningAction SilentlyContinue
Write-Output ("tcp 443: " + $tcp.TcpTestSucceeded + " via " + $tcp.RemoteAddress)

try {
    $r = Invoke-WebRequest -Uri "https://$hostName/login.html" -UseBasicParsing -TimeoutSec 20
    Write-Output ("https status: " + $r.StatusCode)
}
catch {
    Write-Output ("https status: " + $_.Exception.Response.StatusCode.value__)
}
