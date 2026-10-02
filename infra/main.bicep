// AMPLS private DNS demo lab
// Hub (simulated Infoblox) + dedicated monitoring DNS VNet + two spoke VNets (one per subscription) + AMPLS with private endpoint.
targetScope = 'resourceGroup'

@description('Azure region for all regional resources.')
param location string = resourceGroup().location

@description('Short prefix used in resource names.')
param prefix string = 'amplsdns'

@description('Local admin user for the lab VMs (access is via Run Command only).')
param adminUsername string = 'azureadmin'

@secure()
@description('Local admin password for the lab VMs.')
param adminPassword string

@description('VM size for all four lab VMs.')
param vmSize string = 'Standard_B2ms'

// Fixed addressing so the scripts can rely on it
var stdDnsIp = '10.0.1.4' // simulated Infoblox (standard corporate DNS)
var monDnsIp = '10.3.0.4' // dedicated monitoring-only DNS
var peSubnetPrefix = '10.0.2.0/24'

// Private DNS zones required by an AMPLS private endpoint
var amplsZones = [
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  'privatelink.blob.${environment().suffixes.storage}'
]

var suffix = uniqueString(resourceGroup().id)
var dnsCloudInit = loadFileAsBase64('dns-cloud-init.yaml')

// ---------- Network security groups ----------
resource nsgSpokeA 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-spoke-a'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-PrivateEndpoints-FirewallCleared'
        properties: {
          description: 'Subscription A has firewall clearance to the AMPLS private endpoint subnet.'
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: peSubnetPrefix
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgSpokeB 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-spoke-b'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Deny-PrivateEndpoints-NoFirewallClearance'
        properties: {
          description: 'Simulates a subscription WITHOUT firewall clearance to the AMPLS private IPs.'
          priority: 100
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: peSubnetPrefix
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ---------- Virtual networks ----------
// Hub uses Azure-provided DNS: the simulated Infoblox forwards to 168.63.129.16 from here.
resource vnetHub 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-hub'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.0.0.0/16' ] }
    subnets: [
      {
        name: 'snet-dns'
        properties: { addressPrefix: '10.0.1.0/24', defaultOutboundAccess: true }
      }
      {
        name: 'snet-pe'
        properties: { addressPrefix: peSubnetPrefix, defaultOutboundAccess: false }
      }
    ]
  }
}

// Dedicated monitoring DNS VNet: the only VNet where the AMPLS zones are linked by default.
resource vnetMon 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-mondns'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.3.0.0/24' ] }
    subnets: [
      {
        name: 'snet-dns'
        properties: { addressPrefix: '10.3.0.0/24', defaultOutboundAccess: true }
      }
    ]
  }
}

// Subscription A: wants AMPLS, firewall cleared
resource vnetSpokeA 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-spoke-a'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.1.0.0/24' ] }
    dhcpOptions: { dnsServers: [ stdDnsIp ] }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: '10.1.0.0/24'
          defaultOutboundAccess: true
          networkSecurityGroup: { id: nsgSpokeA.id }
        }
      }
    ]
  }
}

// Subscription B: does not use AMPLS, no firewall clearance
resource vnetSpokeB 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-spoke-b'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.2.0.0/24' ] }
    dhcpOptions: { dnsServers: [ stdDnsIp ] }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: '10.2.0.0/24'
          defaultOutboundAccess: true
          networkSecurityGroup: { id: nsgSpokeB.id }
        }
      }
    ]
  }
}

// ---------- Peerings (hub <-> spokes, mondns <-> hub/spokes) ----------
var peerings = [
  { name: 'hub-to-spoke-a', local: 'vnet-hub', remote: vnetSpokeA.id }
  { name: 'spoke-a-to-hub', local: 'vnet-spoke-a', remote: vnetHub.id }
  { name: 'hub-to-spoke-b', local: 'vnet-hub', remote: vnetSpokeB.id }
  { name: 'spoke-b-to-hub', local: 'vnet-spoke-b', remote: vnetHub.id }
  { name: 'mondns-to-hub', local: 'vnet-mondns', remote: vnetHub.id }
  { name: 'hub-to-mondns', local: 'vnet-hub', remote: vnetMon.id }
  { name: 'mondns-to-spoke-a', local: 'vnet-mondns', remote: vnetSpokeA.id }
  { name: 'spoke-a-to-mondns', local: 'vnet-spoke-a', remote: vnetMon.id }
  { name: 'mondns-to-spoke-b', local: 'vnet-mondns', remote: vnetSpokeB.id }
  { name: 'spoke-b-to-mondns', local: 'vnet-spoke-b', remote: vnetMon.id }
]

@batchSize(1) // peerings on the same VNet must not be created in parallel
resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = [for p in peerings: {
  name: '${p.local}/${p.name}'
  properties: {
    remoteVirtualNetwork: { id: p.remote }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
  // Local VNet is referenced by name only, so all VNets must exist first
  #disable-next-line no-unnecessary-dependson
  dependsOn: [ vnetHub, vnetMon, vnetSpokeA, vnetSpokeB ]
}]

// ---------- VMs ----------
module vmStdDns 'vm.bicep' = {
  name: 'vm-dns-std'
  params: {
    name: 'vm-dns-std'
    location: location
    subnetId: '${vnetHub.id}/subnets/snet-dns'
    privateIp: stdDnsIp
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    customData: dnsCloudInit
    role: 'StandardDns'
  }
}

module vmMonDns 'vm.bicep' = {
  name: 'vm-dns-mon'
  params: {
    name: 'vm-dns-mon'
    location: location
    subnetId: '${vnetMon.id}/subnets/snet-dns'
    privateIp: monDnsIp
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    customData: dnsCloudInit
    role: 'MonitoringDns'
  }
}

module vmSpokeA 'vm.bicep' = {
  name: 'vm-spoke-a'
  params: {
    name: 'vm-spoke-a'
    location: location
    subnetId: '${vnetSpokeA.id}/subnets/snet-app'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    role: 'SubscriptionA'
  }
  dependsOn: [ vmStdDns, peering ]
}

module vmSpokeB 'vm.bicep' = {
  name: 'vm-spoke-b'
  params: {
    name: 'vm-spoke-b'
    location: location
    subnetId: '${vnetSpokeB.id}/subnets/snet-app'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    role: 'SubscriptionB'
  }
  dependsOn: [ vmStdDns, peering ]
}

// ---------- Azure Monitor + AMPLS ----------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${prefix}-${suffix}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${prefix}-${suffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

// Open access modes: public endpoints stay usable, only DNS decides the path
resource ampls 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' = {
  name: 'ampls-${prefix}'
  location: 'global'
  properties: {
    accessModeSettings: {
      ingestionAccessMode: 'Open'
      queryAccessMode: 'Open'
    }
  }
}

resource scopedLaw 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'scoped-law'
  properties: { linkedResourceId: law.id }
}

resource scopedAppi 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'scoped-appi'
  properties: { linkedResourceId: appi.id }
  dependsOn: [ scopedLaw ]
}

resource pe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-ampls'
  location: location
  properties: {
    subnet: { id: '${vnetHub.id}/subnets/snet-pe' }
    privateLinkServiceConnections: [
      {
        name: 'ampls'
        properties: {
          privateLinkServiceId: ampls.id
          groupIds: [ 'azuremonitor' ]
        }
      }
    ]
  }
  dependsOn: [ scopedLaw, scopedAppi, peering ]
}

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for z in amplsZones: {
  name: z
  location: 'global'
}]

// Only the dedicated monitoring DNS VNet is linked at deploy time (= Baseline scenario)
resource monLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (z, i) in amplsZones: {
  parent: zones[i]
  name: 'link-vnet-mondns'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetMon.id }
  }
}]

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (z, i) in amplsZones: {
      name: replace(z, '.', '-')
      properties: { privateDnsZoneId: zones[i].id }
    }]
  }
}

output workspaceName string = law.name
output workspaceCustomerId string = law.properties.customerId
output appInsightsName string = appi.name
output amplsName string = ampls.name
output standardDnsIp string = stdDnsIp
output monitoringDnsIp string = monDnsIp
output amplsZones array = amplsZones
