// Virtual network + subnets + NSGs for zero-trust deployment.
//
// The customer allocates a single /26 (64 IPs) for this workload. It is split
// into two equal /27 subnets:
//   snet-services (/27) — App Service VNet integration (delegated to
//                         Microsoft.Web/serverFarms). All outbound calls from
//                         the API/Web apps egress here.
//   snet-pe       (/27) — Shared Private Endpoints for ACR, Storage, Cosmos,
//                         AI Foundry, and Azure Monitor Private Link Scope.
//
// Operator access (build/deploy) is assumed to come from the customer's peered
// network (ExpressRoute / VPN / hub VNet). There is no Bastion and no jumpbox.

@description('Location for all resources')
param location string = resourceGroup().location

@description('Virtual network name')
param vnetName string

@description('Address space for the virtual network. MUST be a /26 supplied by the customer (e.g. 10.123.45.0/26).')
param vnetAddressPrefix string

@description('Tags for resources')
param tags object = {}

@description('When false, subnets are deployed without NSG attachment (customer-managed governance, e.g. Azure Firewall + intra-VNet rules).')
param deployNetworkSecurityGroups bool = true

// Two equal /27 subnets derived from the supplied /26.
//   offset 0  → snet-services (App Service delegation)
//   offset 1  → snet-pe       (private endpoints)
var servicesSubnetPrefix = cidrSubnet(vnetAddressPrefix, 27, 0)
var peSubnetPrefix       = cidrSubnet(vnetAddressPrefix, 27, 1)

// ---- NSGs -------------------------------------------------------------------

resource nsgPe 'Microsoft.Network/networkSecurityGroups@2023-11-01' = if (deployNetworkSecurityGroups) {
  name: '${vnetName}-nsg-pe'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowHttpsInboundFromVnet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

resource nsgServices 'Microsoft.Network/networkSecurityGroups@2023-11-01' = if (deployNetworkSecurityGroups) {
  name: '${vnetName}-nsg-services'
  location: location
  tags: tags
  // Permissive within VNet; App Service regional VNet integration handles
  // outbound traffic; inbound is via separate private endpoints in snet-pe.
  properties: { securityRules: [] }
}

// ---- VNet + Subnets ---------------------------------------------------------

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetAddressPrefix ]
    }
    subnets: [
      {
        name: 'snet-services'
        properties: {
          addressPrefix: servicesSubnetPrefix
          networkSecurityGroup: deployNetworkSecurityGroups ? { id: nsgServices.id } : null
          delegations: [
            {
              name: 'appsvc-delegation'
              properties: { serviceName: 'Microsoft.Web/serverFarms' }
            }
          ]
          serviceEndpoints: [
            { service: 'Microsoft.CognitiveServices' }
          ]
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: peSubnetPrefix
          networkSecurityGroup: deployNetworkSecurityGroups ? { id: nsgPe.id } : null
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output peSubnetId string = '${vnet.id}/subnets/snet-pe'
output appSvcSubnetId string = '${vnet.id}/subnets/snet-services'
