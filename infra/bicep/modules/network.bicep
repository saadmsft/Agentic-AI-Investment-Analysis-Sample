// Virtual network + subnets + NSGs for zero-trust deployment.
// Six subnets:
//   snet-aca-infra   (/23) — delegated to Microsoft.App/environments (workload-profiles ACA)
//   snet-pe          (/26) — shared Private Endpoints
//   snet-jumpbox     (/27) — jump VM NIC
//   AzureBastionSubnet (/26) — required name for Azure Bastion
//   snet-build       (/27) — reserved for ACR Tasks / private build agents
//   snet-mgmt        (/27) — reserved for future self-hosted CI/CD agents

@description('Location for all resources')
param location string = resourceGroup().location

@description('Virtual network name')
param vnetName string

@description('Address space for the virtual network')
param vnetAddressPrefix string = '10.50.0.0/16'

@description('Tags for resources')
param tags object = {}

// ---- NSGs -------------------------------------------------------------------

resource nsgPe 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
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

resource nsgJumpbox 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${vnetName}-nsg-jumpbox'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowBastionInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [ '22', '3389' ]
        }
      }
    ]
  }
}

resource nsgBastion 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${vnetName}-nsg-bastion'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowHttpsInbound'
        properties: { priority: 120, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'Internet', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '443' }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: { priority: 130, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'GatewayManager', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '443' }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: { priority: 140, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'AzureLoadBalancer', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '443' }
      }
      {
        name: 'AllowBastionHostCommunication'
        properties: { priority: 150, direction: 'Inbound', access: 'Allow', protocol: '*', sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*', destinationAddressPrefix: 'VirtualNetwork', destinationPortRanges: [ '8080', '5701' ] }
      }
      {
        name: 'AllowSshRdpOutbound'
        properties: { priority: 100, direction: 'Outbound', access: 'Allow', protocol: '*', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: 'VirtualNetwork', destinationPortRanges: [ '22', '3389' ] }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: { priority: 110, direction: 'Outbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: 'AzureCloud', destinationPortRange: '443' }
      }
      {
        name: 'AllowBastionCommunication'
        properties: { priority: 120, direction: 'Outbound', access: 'Allow', protocol: '*', sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*', destinationAddressPrefix: 'VirtualNetwork', destinationPortRanges: [ '8080', '5701' ] }
      }
      {
        name: 'AllowGetSessionInformation'
        properties: { priority: 130, direction: 'Outbound', access: 'Allow', protocol: '*', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: 'Internet', destinationPortRange: '80' }
      }
    ]
  }
}

resource nsgAca 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${vnetName}-nsg-aca'
  location: location
  tags: tags
  properties: {
    // Intentionally permissive within the VNet; ACA platform manages its own
    // subnet rules. Do not block traffic — see Azure docs for ACA NSG limits.
    securityRules: []
  }
}

resource nsgBuild 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${vnetName}-nsg-build'
  location: location
  tags: tags
  properties: { securityRules: [] }
}

resource nsgMgmt 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${vnetName}-nsg-mgmt'
  location: location
  tags: tags
  properties: { securityRules: [] }
}

resource nsgAppSvc 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${vnetName}-nsg-appsvc'
  location: location
  tags: tags
  // Permissive within VNet; App Service regional VNet integration handles
  // outbound traffic; inbound is via separate private endpoint in snet-pe.
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
        name: 'snet-aca-infra'
        properties: {
          addressPrefix: '10.50.0.0/23'
          networkSecurityGroup: { id: nsgAca.id }
          delegations: [
            {
              name: 'aca-delegation'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: '10.50.2.0/26'
          networkSecurityGroup: { id: nsgPe.id }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'snet-jumpbox'
        properties: {
          addressPrefix: '10.50.2.64/27'
          networkSecurityGroup: { id: nsgJumpbox.id }
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.50.2.128/26'
          networkSecurityGroup: { id: nsgBastion.id }
        }
      }
      {
        name: 'snet-build'
        properties: {
          addressPrefix: '10.50.2.192/27'
          networkSecurityGroup: { id: nsgBuild.id }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'snet-mgmt'
        properties: {
          addressPrefix: '10.50.2.224/27'
          networkSecurityGroup: { id: nsgMgmt.id }
        }
      }
      {
        name: 'snet-appsvc'
        properties: {
          addressPrefix: '10.50.4.0/26'
          networkSecurityGroup: { id: nsgAppSvc.id }
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
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output acaInfraSubnetId string = '${vnet.id}/subnets/snet-aca-infra'
output peSubnetId string = '${vnet.id}/subnets/snet-pe'
output jumpboxSubnetId string = '${vnet.id}/subnets/snet-jumpbox'
output bastionSubnetId string = '${vnet.id}/subnets/AzureBastionSubnet'
output buildSubnetId string = '${vnet.id}/subnets/snet-build'
output mgmtSubnetId string = '${vnet.id}/subnets/snet-mgmt'
output appSvcSubnetId string = '${vnet.id}/subnets/snet-appsvc'
