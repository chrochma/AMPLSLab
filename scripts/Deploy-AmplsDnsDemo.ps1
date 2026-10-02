#Requires -Version 7.2
<#
.SYNOPSIS
    Deploys the AMPLS private DNS demo lab and applies the Baseline scenario.
.EXAMPLE
    .\Deploy-AmplsDnsDemo.ps1 -Location swedencentral
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-ampls-dns-demo',
    [string]$Location = 'swedencentral',
    [string]$Prefix = 'amplsdns',
    [string]$VmSize = 'Standard_B2ms',
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AmplsDnsDemo.Common.ps1')
$L = $script:DemoLayout

Assert-DemoAzContext -SubscriptionId $SubscriptionId

# Az PowerShell needs the Bicep CLI on PATH; reuse the one installed by 'az bicep install'
if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
    $azBicep = Join-Path $HOME '.azure\bin'
    if (Test-Path (Join-Path $azBicep 'bicep.exe')) { $env:PATH = "$azBicep;$env:PATH" }
    else { throw 'Bicep CLI not found. Install it with: az bicep install  (or winget install Microsoft.Bicep)' }
}

# Random local admin password (VMs are only managed through Run Command)
$chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!#%+=?'.ToCharArray()
$adminPassword = 'Aa1!' + (-join (1..20 | ForEach-Object { $chars | Get-Random }))

Write-Host "Creating resource group $ResourceGroupName in $Location ..." -ForegroundColor Cyan
$null = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{ purpose = 'AMPLS private DNS demo'; demoScenario = 'Deploying' } -Force

Write-Host 'Deploying lab (VNets, DNS VMs, subscription VMs, AMPLS, private endpoint, zones) ... ~10-15 min' -ForegroundColor Cyan
$deployment = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
    -Name "amplsdns-$(Get-Date -Format yyyyMMddHHmmss)" `
    -TemplateFile (Join-Path $PSScriptRoot '..\infra\main.bicep') `
    -TemplateParameterObject @{ location = $Location; prefix = $Prefix; vmSize = $VmSize; adminPassword = $adminPassword }
if ($deployment.ProvisioningState -ne 'Succeeded') { throw "Deployment failed: $($deployment.ProvisioningState)" }
Remove-Variable adminPassword

# Wait until BIND is installed by cloud-init on both DNS VMs
Write-Host 'Waiting for cloud-init on the DNS VMs ...' -ForegroundColor Cyan
$wait = 'cloud-init status --wait >/dev/null 2>&1; systemctl is-active named'
$state = Invoke-DemoRunCommand -ResourceGroupName $ResourceGroupName -Scripts @{ $L.StandardDnsVm = $wait; $L.MonitoringDnsVm = $wait }
$state.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-11} named: {1}" -f $_.Key, $_.Value.StdOut.Trim()) }

& (Join-Path $PSScriptRoot 'Set-AmplsDnsScenario.ps1') -Scenario Baseline -ResourceGroupName $ResourceGroupName

Write-Host "`nLab ready. Workspace: $($deployment.Outputs.workspaceName.Value)  AMPLS: $($deployment.Outputs.amplsName.Value)" -ForegroundColor Green
Write-Host 'Next: ..\Start-AmplsDnsDemo.ps1  (interactive demo menu)' -ForegroundColor Green
