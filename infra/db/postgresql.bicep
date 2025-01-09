metadata description = 'Creates a PostgreSQL flexible server'
param name string
param location string = resourceGroup().location
param tags object = {}

@allowed([
  'Password'
  'EntraOnly'
])
param authType string = 'Password'

param administratorLogin string = ''
@secure()
param administratorLoginPassword string = ''

@description('The Object ID of the Azure AD admin.')
param aadAdminObjectid string

@description('Azure AD admin name.')
param aadAdminName string

@description('Azure AD admin Type')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param aadAdminType string = 'User'

param databaseNames array = []
param allowAzureIPsFirewall bool = false
param allowAllIPsFirewall bool = false
param allowedSingleIPs array = []

// PostgreSQL version
param version string
param storage object

// Parameters
@description('Specifies the name of the virtual network.')
param virtualNetworkName string

@description('Specifies the name of the subnet for private endpoints.')
param subnetNameForPE string
@description('Specifies the name of the subnet for the database.')
param subnetNameForDB string
@description('Decides whether to allow public network access.')
param publicNetworkAccess string = 'Enabled'

var authProperties = authType == 'Password'
  ? {
      administratorLogin: administratorLogin
      administratorLoginPassword: administratorLoginPassword
      authConfig: {
        passwordAuth: 'Enabled'
      }
    }
  : {
      authConfig: {
        activeDirectoryAuth: 'Enabled'
        passwordAuth: 'Disabled'
      }
    }

// Virtual Network
resource vnet 'Microsoft.Network/virtualNetworks@2021-08-01' existing = {
  name: virtualNetworkName
}

var pgPrivateDNSZoneName = 'privatelink.postgres.database.azure.com'
var pgPrivateDnsZoneVirtualNetworkLinkName = format(
  '{0}-link-{1}',
  name,
  take(toLower(uniqueString(name, virtualNetworkName)), 4)
)

// Private DNS Zones
resource pgPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: pgPrivateDNSZoneName
  location: 'global'
  tags: tags
  properties: {}
  dependsOn: [
    vnet
  ]
}

// Virtual Network Links
resource pgPrivateDnsZoneVirtualNetworkLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: pgPrivateDnsZone
  name: pgPrivateDnsZoneVirtualNetworkLinkName
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// Private Endpoints
resource pgPrivateEndpoint 'Microsoft.Network/privateEndpoints@2021-08-01' = {
  name: 'pg-private-endpoint'
  location: location
  tags: tags
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'pgPrivateLinkConnection'
        properties: {
          privateLinkServiceId: postgresServer.id
          groupIds: [
            'postgresqlServer'
          ]
        }
      }
    ]
    subnet: {
      id: '${vnet.id}/subnets/${subnetNameForPE}'
    }
  }
}

resource pgPrivateDnsZoneGroupName 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2022-01-01' = {
  parent: pgPrivateEndpoint
  name: 'pgPrivateDnsZoneGroup'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'storagepgARecord'
        properties: {
          privateDnsZoneId: pgPrivateDnsZone.id
        }
      }
    ]
  }
}

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-03-01-preview' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: union(authProperties, {
    version: version
    storage: storage

    highAvailability: {
      mode: 'Disabled'
    }

    network: (publicNetworkAccess == 'Enabled')
      ? {
          publicNetworkAccess: publicNetworkAccess
        }
      : {
          delegatedSubnetResourceId: '${vnet.id}/subnets/${subnetNameForDB}'
          privateDnsZoneArmResourceId: pgPrivateDnsZone.id
          publicNetworkAccess: publicNetworkAccess
        }
  })

  resource database 'databases' = [
    for name in databaseNames: {
      name: name
    }
  ]
}

resource firewall_all 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-03-01-preview' = if (allowAllIPsFirewall) {
  parent: postgresServer
  name: 'allow-all-IPs'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '255.255.255.255'
  }
}

resource firewall_azure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-03-01-preview' = if (allowAzureIPsFirewall) {
  parent: postgresServer
  name: 'allow-all-azure-internal-IPs'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

@batchSize(1)
resource firewall_single 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-03-01-preview' = [
  for ip in allowedSingleIPs: {
    parent: postgresServer
    name: 'allow-single-${replace(ip, '.', '')}'
    properties: {
      startIpAddress: ip
      endIpAddress: ip
    }
  }
]

// Workaround issue https://github.com/Azure/bicep-types-az/issues/1507
resource configurations 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2023-03-01-preview' = {
  name: 'azure.extensions'
  parent: postgresServer
  properties: {
    value: 'vector'
    source: 'user-override'
  }
  dependsOn: [
    firewall_all
    firewall_azure
    firewall_single
  ]
}

// This must be created *after* the server is created - it cannot be a nested child resource
resource addAddUser 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2023-03-01-preview' = {
  name: aadAdminObjectid // Pass my principal ID
  parent: postgresServer
  properties: {
    tenantId: subscription().tenantId
    principalType: aadAdminType // User
    principalName: aadAdminName // UserRole
  }
  dependsOn: [
    firewall_all
    firewall_azure
    firewall_single
    configurations
  ]
}

output POSTGRES_DOMAIN_NAME string = postgresServer.properties.fullyQualifiedDomainName
output POSTGRES_NAME string = postgresServer.name
