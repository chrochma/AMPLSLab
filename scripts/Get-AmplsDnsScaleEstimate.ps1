#Requires -Version 7.2
<#
.SYNOPSIS
    Estimates how many extra DNS instances the "dedicated DNS per hub" design needs.
.DESCRIPTION
    One AMPLS holds ~3,000 resources (Log Analytics workspaces + Application Insights).
    Every additional AMPLS needs its own monitoring DNS layer in every hub.
.EXAMPLE
    .\Get-AmplsDnsScaleEstimate.ps1 -HubCount 10 -ServiceCount 500 -ResourcesPerService 8
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 1000)][int]$HubCount = 10,
    [ValidateRange(1, 10)][int]$DnsServersPerHub = 2,
    [ValidateRange(0, 1000000)][int]$ServiceCount = 300,
    [ValidateRange(1, 100)][int]$ResourcesPerService = 10,
    [ValidateRange(1, 100000)][int]$ResourcesPerAmpls = 3000
)

$resources = $ServiceCount * $ResourcesPerService
$amplsCount = [math]::Max(1, [math]::Ceiling($resources / $ResourcesPerAmpls))

$result = [pscustomobject]@{
    Hubs                       = $HubCount
    MonitoredResources         = $resources
    AmplsRequired              = $amplsCount
    'DedicatedDns (instances)' = $HubCount * $DnsServersPerHub * $amplsCount
    'DnsViews (instances)'     = 0
    'Per extra AMPLS'          = $HubCount * $DnsServersPerHub
}

Write-Host "`nScaling = hubs x DNS servers per hub x AMPLS count" -ForegroundColor Cyan
$result | Format-List | Out-Host
Write-Host 'DnsViews / forwarding rules on the existing Infoblox add configuration, not instances.' -ForegroundColor DarkGray
$result
