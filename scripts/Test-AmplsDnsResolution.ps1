#Requires -Version 7.2
<#
.SYNOPSIS
    Shows how each subscription resolves the monitoring endpoints and whether it can reach them.
.DESCRIPTION
    Runs a resolution + TCP/443 test on both spoke VMs via Run Command and prints a comparison.
.EXAMPLE
    .\Test-AmplsDnsResolution.ps1
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-ampls-dns-demo',
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AmplsDnsDemo.Common.ps1')
$L = $script:DemoLayout

# Workspace ID is needed for the per-workspace ingestion FQDNs
$law = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.OperationalInsights/workspaces' -ExpandProperties | Select-Object -First 1
if (-not $law) { throw "No Log Analytics workspace found in $ResourceGroupName. Deploy the lab first." }
$wsId = $law.Properties.customerId

# FQDN, purpose, test TCP 443
$targets = @(
    ,@('api.monitor.azure.com',                     'Query / control plane', 1)
    ,@('global.handler.control.monitor.azure.com',  'AMA control (DCR)',     1)
    ,@("$wsId.ods.opinsights.azure.com",            'LAW data ingestion',    1)
    ,@("$wsId.oms.opinsights.azure.com",            'LAW agent onboarding',  1)
    ,@('scadvisorcontentpl.blob.core.windows.net',  'AMA solution packs (blob)', 1)
    ,@("app01.$($L.CorpZone)",                      'Corporate zone (Infoblox)', 0)
)

$checks = ($targets | ForEach-Object { "check '$($_[0])' $($_[2])" }) -join "`n"
$bash = @"
IF=`$(ip route show default | awk '{print `$5; exit}')
resolvectl flush-caches 2>/dev/null || true
DNS=`$(resolvectl dns "`$IF" 2>/dev/null | cut -d: -f2- | xargs)
check() {
  ip=`$(getent ahostsv4 "`$1" | awk 'NR==1{print `$1}')
  tcp=n/a
  if [ -z "`$ip" ]; then ip=NXDOMAIN
  elif [ "`$2" = 1 ]; then
    if timeout 4 bash -c "</dev/tcp/`$ip/443" 2>/dev/null; then tcp=Open; else tcp=Blocked; fi
  fi
  echo "RESULT|`$1|`$ip|`$tcp|`$DNS"
}
$checks
"@

$scenario = Get-DemoScenarioState -ResourceGroupName $ResourceGroupName
Write-Host "`nTesting resolution from both subscriptions (scenario: $scenario) ..." -ForegroundColor Cyan
$out = Invoke-DemoRunCommand -ResourceGroupName $ResourceGroupName -Scripts @{ $L.SpokeAVm = $bash; $L.SpokeBVm = $bash }

$rows = foreach ($vm in @($L.SpokeAVm, $L.SpokeBVm)) {
    $sub = if ($vm -eq $L.SpokeAVm) { 'A (AMPLS, FW ok)' } else { 'B (no FW clearance)' }
    foreach ($line in ($out[$vm].StdOut -split "`n" | Where-Object { $_ -like 'RESULT|*' })) {
        $null, $fqdn, $ip, $tcp, $dns = $line.Trim() -split '\|'
        $path = if ($ip -eq 'NXDOMAIN') { 'UNRESOLVED' }
                elseif ($ip.StartsWith($L.PePrefix)) { 'Private (PE)' }
                elseif ($ip -match '^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)') { 'Private' }
                else { 'Public' }
        $purpose = ($targets | Where-Object { $_[0] -eq $fqdn })[1]
        [pscustomobject]@{
            Subscription = $sub; DnsServer = $dns; Purpose = $purpose; Fqdn = $fqdn
            ResolvedIp = $ip; Path = $path; Tcp443 = $tcp
        }
    }
}

# Colourised table
foreach ($group in $rows | Group-Object Subscription) {
    Write-Host ("`nSubscription {0}  - DNS server: {1}" -f $group.Name, $group.Group[0].DnsServer) -ForegroundColor Yellow
    foreach ($r in $group.Group) {
        $color = if ($r.Path -eq 'UNRESOLVED' -or $r.Tcp443 -eq 'Blocked') { 'Red' } elseif ($r.Path -like 'Private*') { 'Green' } else { 'Gray' }
        Write-Host ("  {0,-26} {1,-15} {2,-13} {3,-8} {4}" -f $r.Purpose, $r.ResolvedIp, $r.Path, $r.Tcp443, $r.Fqdn) -ForegroundColor $color
    }
}
if ($script:DemoScenarios.Contains($scenario)) { Write-Host "`nExpected: $($script:DemoScenarios[$scenario].Expect)" -ForegroundColor Green }

if ($PassThru) { $rows }
