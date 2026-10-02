#Requires -Version 7.2
<#
.SYNOPSIS
    Deletes the AMPLS DNS demo resource group.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ResourceGroupName = 'rg-ampls-dns-demo',
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Delete resource group and all lab resources')) {
    if ($NoWait) { $null = Remove-AzResourceGroup -Name $ResourceGroupName -Force -AsJob; Write-Host 'Deletion started in background.' }
    else { $null = Remove-AzResourceGroup -Name $ResourceGroupName -Force; Write-Host "$ResourceGroupName deleted." -ForegroundColor Green }
}
