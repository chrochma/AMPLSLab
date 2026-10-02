#Requires -Version 7.2
<#
.SYNOPSIS
    Interactive demo menu: walk through the common DNS designs for AMPLS.
.EXAMPLE
    .\Start-AmplsDnsDemo.ps1
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-ampls-dns-demo',
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'
$scripts = Join-Path $PSScriptRoot 'scripts'
. (Join-Path $scripts 'AmplsDnsDemo.Common.ps1')
Assert-DemoAzContext -SubscriptionId $SubscriptionId

if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    Write-Warning "Resource group $ResourceGroupName not found. Run .\scripts\Deploy-AmplsDnsDemo.ps1 first."
    return
}

$names = @($script:DemoScenarios.Keys)
while ($true) {
    $current = Get-DemoScenarioState -ResourceGroupName $ResourceGroupName
    Write-Host "`n==================== AMPLS private DNS demo ====================" -ForegroundColor Cyan
    Write-Host "Active scenario: $current`n" -ForegroundColor DarkGray
    for ($i = 0; $i -lt $names.Count; $i++) {
        $marker = if ($names[$i] -eq $current) { '*' } else { ' ' }
        Write-Host (" {0}{1}  {2,-14} {3}" -f $marker, ($i + 1), $names[$i], $script:DemoScenarios[$names[$i]].Title)
    }
    Write-Host "`n  T  Test resolution in the active scenario"
    Write-Host '  S  Scale estimate (dedicated DNS per hub vs. DNS views)'
    Write-Host '  Q  Quit'
    $choice = (Read-Host "`nSelect").Trim()

    switch -Regex ($choice) {
        '^[1-9]$' {
            $idx = [int]$choice - 1
            if ($idx -lt $names.Count) {
                & (Join-Path $scripts 'Set-AmplsDnsScenario.ps1') -Scenario $names[$idx] -ResourceGroupName $ResourceGroupName
                Write-Host 'Waiting 30s so Azure DNS picks up link changes ...' -ForegroundColor DarkGray
                Start-Sleep -Seconds 30
                & (Join-Path $scripts 'Test-AmplsDnsResolution.ps1') -ResourceGroupName $ResourceGroupName
            }
        }
        '^[Tt]$' { & (Join-Path $scripts 'Test-AmplsDnsResolution.ps1') -ResourceGroupName $ResourceGroupName }
        '^[Ss]$' {
            $hubs = Read-Host 'Number of hubs [10]'; if (-not $hubs) { $hubs = 10 }
            $svc = Read-Host 'Number of services [300]'; if (-not $svc) { $svc = 300 }
            $null = & (Join-Path $scripts 'Get-AmplsDnsScaleEstimate.ps1') -HubCount $hubs -ServiceCount $svc
        }
        '^[Qq]$' { return }
    }
}
