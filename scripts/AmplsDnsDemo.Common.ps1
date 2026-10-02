#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.PrivateDns, Az.Compute
<#
    Shared settings and helpers for the AMPLS private DNS demo lab.
    Dot-source this file from the other scripts.
#>

Set-StrictMode -Version Latest

# ---------- Fixed lab layout (must match infra\main.bicep) ----------
$script:DemoLayout = [ordered]@{
    StandardDnsVm   = 'vm-dns-std'      # simulated Infoblox in the hub
    MonitoringDnsVm = 'vm-dns-mon'      # dedicated monitoring-only DNS
    SpokeAVm        = 'vm-spoke-a'      # subscription A (wants AMPLS, firewall cleared)
    SpokeBVm        = 'vm-spoke-b'      # subscription B (no AMPLS, no firewall clearance)
    HubVnet         = 'vnet-hub'
    MonVnet         = 'vnet-mondns'
    SpokeAVnet      = 'vnet-spoke-a'
    SpokeBVnet      = 'vnet-spoke-b'
    StandardDnsIp   = '10.0.1.4'
    MonitoringDnsIp = '10.3.0.4'
    SpokeAPrefix    = '10.1.0.0/24'
    PePrefix        = '10.0.2.'
    AzureDnsIp      = '168.63.129.16'
    CorpZone        = 'corp.contoso.internal'
}

# Private DNS zones used by an AMPLS private endpoint
$script:AmplsZones = @(
    'privatelink.monitor.azure.com'
    'privatelink.oms.opinsights.azure.com'
    'privatelink.ods.opinsights.azure.com'
    'privatelink.agentsvc.azure-automation.net'
    'privatelink.blob.core.windows.net'
)

# Public parent zones that must be conditionally forwarded so the CNAME chain resolves privately
$script:AmplsPublicZones = @(
    'monitor.azure.com'
    'oms.opinsights.azure.com'
    'ods.opinsights.azure.com'
    'agentsvc.azure-automation.net'
    'blob.core.windows.net'
)

# ---------- Scenario catalog ----------
# HubLinked / SpokeALinked : AMPLS zones linked to that VNet
# SpokeADns / SpokeBDns    : Standard | Monitoring | Azure (empty = Azure-provided)
# StandardMode             : Standard | Views (BIND views on the simulated Infoblox)
$script:DemoScenarios = [ordered]@{
    Baseline      = @{ Order = 1; HubLinked = $false; SpokeALinked = $false; SpokeADns = 'Standard'; SpokeBDns = 'Standard'; StandardMode = 'Standard'
        Title = 'Today without AMPLS zones in the hub'
        Story = 'Both subscriptions use the standard DNS (Infoblox). Monitoring names resolve to public IPs everywhere.'
        Expect = 'A: public / B: public. Corp zone resolves in both subscriptions.' }
    Incident      = @{ Order = 2; HubLinked = $true; SpokeALinked = $false; SpokeADns = 'Standard'; SpokeBDns = 'Standard'; StandardMode = 'Standard'
        Title = 'Central link: AMPLS zones linked in the hub'
        Story = 'The monitoring private DNS zones are linked to the hub where Infoblox resolves. Every subscription now gets private IPs.'
        Expect = 'A: private + reachable / B: private + BLOCKED (no firewall clearance).' }
    SpokeZoneLink = @{ Order = 3; HubLinked = $false; SpokeALinked = $true; SpokeADns = 'Standard'; SpokeBDns = 'Standard'; StandardMode = 'Standard'
        Title = 'Zones created/linked inside the subscription'
        Story = 'Zones are linked to spoke A only, but spoke A still uses Infoblox IPs as DNS servers. The link is never consulted.'
        Expect = 'A: still public (link has no effect) / B: public.' }
    SpokeAzureDns = @{ Order = 4; HubLinked = $false; SpokeALinked = $true; SpokeADns = 'Azure'; SpokeBDns = 'Standard'; StandardMode = 'Standard'
        Title = 'Subscription uses the Azure platform resolver (168.63.129.16)'
        Story = 'Spoke A switches to Azure-provided DNS so its zone link takes effect - but it loses the corporate DNS.'
        Expect = 'A: private, corp zone FAILS / B: public.' }
    DedicatedDns  = @{ Order = 5; HubLinked = $false; SpokeALinked = $false; SpokeADns = 'Monitoring'; SpokeBDns = 'Standard'; StandardMode = 'Standard'
        Title = 'Dedicated monitoring DNS instance per selected VNet'
        Story = 'Spoke A points to a dedicated DNS holding only the monitoring zones; everything else is conditionally forwarded to Infoblox.'
        Expect = 'A: private + corp OK / B: public + corp OK.' }
    DnsViews      = @{ Order = 6; HubLinked = $false; SpokeALinked = $false; SpokeADns = 'Standard'; SpokeBDns = 'Standard'; StandardMode = 'Views'
        Title = 'Source-based answers on the existing Infoblox (DNS views)'
        Story = 'Both subscriptions keep the standard DNS. Infoblox answers monitoring names differently depending on the source VNet.'
        Expect = 'A: private + corp OK / B: public + corp OK. No VNet DNS change needed.' }
}

function Assert-DemoAzContext {
    <# Ensures an Azure login and optionally switches subscription. #>
    param([string]$SubscriptionId)
    if (-not (Get-AzContext)) { $null = Connect-AzAccount }
    if ($SubscriptionId) { $null = Set-AzContext -Subscription $SubscriptionId }
    $ctx = Get-AzContext
    Write-Host "Azure context: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))" -ForegroundColor DarkGray
}

function ConvertTo-LfScript {
    <# Run Command on Linux needs LF line endings. #>
    param([string]$Text)
    ($Text -replace "`r`n", "`n").Trim() + "`n"
}

function Invoke-DemoRunCommand {
    <#
        Runs bash scripts on several VMs in parallel via Run Command.
        Scripts: hashtable VMName -> bash text. Returns hashtable VMName -> @{StdOut; StdErr}.
    #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][hashtable]$Scripts
    )
    $pending = foreach ($vm in $Scripts.Keys) {
        $file = Join-Path ([IO.Path]::GetTempPath()) ("amplsdns-$vm-$([guid]::NewGuid()).sh")
        [IO.File]::WriteAllText($file, (ConvertTo-LfScript $Scripts[$vm]), [Text.UTF8Encoding]::new($false))
        [pscustomobject]@{
            VM   = $vm
            File = $file
            Job  = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vm -CommandId 'RunShellScript' -ScriptPath $file -AsJob
        }
    }

    $results = @{}
    foreach ($p in $pending) {
        try {
            $r = $p.Job | Wait-Job | Receive-Job -ErrorAction Stop
            $msg = ($r.Value | ForEach-Object Message) -join "`n"
            $stdout = $msg; $stderr = ''
            if ($msg -match '(?s)\[stdout\]\s*(.*?)\s*\[stderr\]\s*(.*)$') { $stdout = $Matches[1]; $stderr = $Matches[2].Trim() }
            $results[$p.VM] = [pscustomobject]@{ StdOut = $stdout; StdErr = $stderr }
        }
        finally {
            Remove-Item $p.File -Force -ErrorAction SilentlyContinue
            $p.Job | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }
    $results
}

function Get-DemoBindScript {
    <#
        Builds the bash script that writes the BIND config for a DNS VM.
        Role: Standard (simulated Infoblox) | Monitoring (dedicated). Mode: Standard | Views.
    #>
    param(
        [ValidateSet('Standard', 'Monitoring')][string]$Role,
        [ValidateSet('Standard', 'Views')][string]$Mode = 'Standard'
    )
    $L = $script:DemoLayout

    $options = @"
options {
  directory "/var/cache/bind";
  recursion yes;
  allow-query { any; };
  allow-recursion { any; };
  forwarders { __UPSTREAM__; };
  forward only;
  dnssec-validation no;
  listen-on { any; };
  listen-on-v6 { none; };
};
"@

    # Conditional forwarders for the public monitoring parent zones
    $fwd = { param($target) ($script:AmplsPublicZones | ForEach-Object { "  zone `"$_`" { type forward; forward only; forwarders { $target; }; };" }) -join "`n" }

    if ($Role -eq 'Monitoring') {
        # Dedicated DNS: monitoring zones -> Azure DNS (zones linked here), everything else -> Infoblox
        $conf = $options.Replace('__UPSTREAM__', $L.StandardDnsIp) + "`n" + (& $fwd $L.AzureDnsIp) + "`ninclude `"/etc/bind/named.conf.default-zones`";"
        $zoneFile = ''
    }
    else {
        $corp = "zone `"$($L.CorpZone)`" { type master; file `"/etc/bind/db.$($L.CorpZone)`"; };"
        $zoneFile = @'
$TTL 60
@     IN SOA ns1 hostmaster ( 1 60 60 600 60 )
@     IN NS  ns1
ns1   IN A   10.0.1.4
app01 IN A   10.0.1.100
'@
        if ($Mode -eq 'Standard') {
            $conf = $options.Replace('__UPSTREAM__', $L.AzureDnsIp) + "`n$corp`ninclude `"/etc/bind/named.conf.default-zones`";"
        }
        else {
            # Views: clients from AMPLS subscriptions get monitoring names from the dedicated resolver
            $conf = $options.Replace('__UPSTREAM__', $L.AzureDnsIp) + @"

acl "ampls-subscriptions" { $($L.SpokeAPrefix); };
view "ampls" {
  match-clients { "ampls-subscriptions"; };
$(& $fwd $L.MonitoringDnsIp)
  $corp
  include "/etc/bind/named.conf.default-zones";
};
view "default" {
  match-clients { any; };
  zone "$($L.CorpZone)" { in-view "ampls"; };
  include "/etc/bind/named.conf.default-zones";
};
"@
        }
    }

    $script = @"
set -e
cat > /etc/bind/named.conf <<'NAMEDEOF'
$conf
NAMEDEOF
"@
    if ($zoneFile) {
        $script += @"

cat > /etc/bind/db.$($L.CorpZone) <<'ZONEEOF'
$zoneFile
ZONEEOF
"@
    }
    $script += @"

named-checkconf /etc/bind/named.conf
systemctl restart named
sleep 2
systemctl is-active named
echo "APPLIED role=$Role mode=$Mode"
"@
    $script
}

function Get-DemoSpokeRefreshScript {
    <# Renews DHCP (picks up VNet DNS changes) and flushes the local resolver cache. #>
    @'
IF=$(ip route show default | awk '{print $5; exit}')
networkctl renew "$IF" >/dev/null 2>&1 || true
sleep 5
resolvectl flush-caches 2>/dev/null || true
echo "DNS=$(resolvectl dns "$IF" 2>/dev/null | cut -d: -f2- | xargs)"
'@
}

function Get-DemoScenarioState {
    <# Reads the active scenario from the resource group tag. #>
    param([Parameter(Mandatory)][string]$ResourceGroupName)
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
    if ($rg.Tags -and $rg.Tags.ContainsKey('demoScenario')) { $rg.Tags['demoScenario'] } else { 'Unknown' }
}
