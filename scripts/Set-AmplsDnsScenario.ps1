#Requires -Version 7.2
<#
.SYNOPSIS
    Switches the AMPLS DNS demo lab to one of the common DNS designs.
.DESCRIPTION
    Adjusts private DNS zone links, VNet DNS servers and the BIND configuration on the
    simulated Infoblox / dedicated monitoring DNS VMs. Spoke VMs renew DHCP and flush caches.
.EXAMPLE
    .\Set-AmplsDnsScenario.ps1 -Scenario Incident
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Baseline', 'Incident', 'SpokeZoneLink', 'SpokeAzureDns', 'DedicatedDns', 'DnsViews')]
    [string]$Scenario,

    [string]$ResourceGroupName = 'rg-ampls-dns-demo'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AmplsDnsDemo.Common.ps1')

$L = $script:DemoLayout
$def = $script:DemoScenarios[$Scenario]
Write-Host "`n=== Scenario: $Scenario - $($def.Title) ===" -ForegroundColor Cyan
Write-Host $def.Story -ForegroundColor Gray

function Set-ZoneLinks {
    <# Adds or removes the AMPLS zone links for one VNet. #>
    param([string]$VnetName, [bool]$Enabled)
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VnetName
    $linkName = "link-$VnetName"
    foreach ($zone in $script:AmplsZones) {
        $link = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $ResourceGroupName -ZoneName $zone -Name $linkName -ErrorAction SilentlyContinue
        if ($Enabled -and -not $link -and $PSCmdlet.ShouldProcess("$zone -> $VnetName", 'Link zone')) {
            $null = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $ResourceGroupName -ZoneName $zone -Name $linkName -VirtualNetworkId $vnet.Id
        }
        elseif (-not $Enabled -and $link -and $PSCmdlet.ShouldProcess("$zone -> $VnetName", 'Unlink zone')) {
            Remove-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $ResourceGroupName -ZoneName $zone -Name $linkName
        }
    }
    Write-Host ("  Zones {0} {1}" -f ($(if ($Enabled) { 'linked to  ' } else { 'unlinked from' })), $VnetName)
}

function Set-VnetDns {
    <# Sets custom DNS servers on a VNet (Azure = Azure-provided DNS). #>
    param([string]$VnetName, [ValidateSet('Standard', 'Monitoring', 'Azure')][string]$Target)
    $servers = switch ($Target) {
        'Standard'   { @($L.StandardDnsIp) }
        'Monitoring' { @($L.MonitoringDnsIp) }
        'Azure'      { @() }
    }
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VnetName
    $current = if ($vnet.DhcpOptions -and $vnet.DhcpOptions.DnsServers) { @($vnet.DhcpOptions.DnsServers) } else { @() }
    if (($current -join ',') -ne ($servers -join ',') -and $PSCmdlet.ShouldProcess($VnetName, "Set DNS to $Target")) {
        if (-not $vnet.DhcpOptions) { $vnet.DhcpOptions = [Microsoft.Azure.Commands.Network.Models.PSDhcpOptions]::new() }
        $vnet.DhcpOptions.DnsServers = [Collections.Generic.List[string]]::new([string[]]$servers)
        $null = $vnet | Set-AzVirtualNetwork
    }
    $label = if ($servers) { $servers -join ', ' } else { "Azure-provided ($($L.AzureDnsIp))" }
    Write-Host ("  {0,-13} DNS -> {1} [{2}]" -f $VnetName, $label, $Target)
}

# 1. Private DNS zone links
Write-Host "`n[1/3] Private DNS zone links" -ForegroundColor Yellow
Set-ZoneLinks -VnetName $L.HubVnet -Enabled $def.HubLinked
Set-ZoneLinks -VnetName $L.SpokeAVnet -Enabled $def.SpokeALinked

# 2. VNet DNS servers
Write-Host "`n[2/3] VNet DNS servers" -ForegroundColor Yellow
Set-VnetDns -VnetName $L.SpokeAVnet -Target $def.SpokeADns
Set-VnetDns -VnetName $L.SpokeBVnet -Target $def.SpokeBDns

# 3. DNS server configs + spoke DHCP renew, all in parallel
Write-Host "`n[3/3] Applying BIND configs and refreshing subscription VMs (Run Command, ~1 min)" -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess('lab VMs', 'Run Command')) {
    $refresh = Get-DemoSpokeRefreshScript
    $results = Invoke-DemoRunCommand -ResourceGroupName $ResourceGroupName -Scripts @{
        $L.StandardDnsVm   = Get-DemoBindScript -Role Standard -Mode $def.StandardMode
        $L.MonitoringDnsVm = Get-DemoBindScript -Role Monitoring
        $L.SpokeAVm        = $refresh
        $L.SpokeBVm        = $refresh
    }
    foreach ($vm in $results.Keys | Sort-Object) {
        $line = ($results[$vm].StdOut -split "`n" | Where-Object { $_ } | Select-Object -Last 1)
        Write-Host ("  {0,-11} {1}" -f $vm, $line)
        if ($results[$vm].StdErr -and $vm -like 'vm-dns-*') { Write-Warning "$vm stderr: $($results[$vm].StdErr)" }
    }
    $null = Update-AzTag -ResourceId (Get-AzResourceGroup -Name $ResourceGroupName).ResourceId -Tag @{ demoScenario = $Scenario } -Operation Merge
}

Write-Host "`nExpected: $($def.Expect)" -ForegroundColor Green
Write-Host "Run .\Test-AmplsDnsResolution.ps1 to verify (Azure DNS may cache link changes for up to ~1-2 min)." -ForegroundColor DarkGray
