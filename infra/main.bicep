targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
@allowed(['australiaeast', 'eastasia', 'eastus', 'eastus2', 'northeurope', 'southcentralus', 'southeastasia', 'swedencentral', 'uksouth', 'westus2', 'eastus2euap'])
@metadata({
  azd: {
    type: 'location'
  }
})
param location string
param skipVnet bool = false
param apiServiceName string = ''
param apiUserAssignedIdentityName string = ''
param applicationInsightsName string = ''
param appServicePlanName string = ''
param logAnalyticsName string = ''
param resourceGroupName string = ''
param storageAccountName string = ''
param vNetName string = ''
param disableLocalAuth bool = true

// --------------------------------------------------------------------------------------------------------------
// Personal info
// --------------------------------------------------------------------------------------------------------------
@description('My IP address for network access')
param myIpAddress string = ''
@description('Id of the user executing the deployment')
param principalId string = ''

// --------------------------------------------------------------------------------------------------------------
// Database
// --------------------------------------------------------------------------------------------------------------
@description('Azure AD admin name.')
param aadAdminName string
var POSTGRES_MONITORED_TABLE_NAME = 'monitored_table'
var POSTGRES_TARGET_TABLE_NAME = 'target_table'

@description('Azure AD admin Type')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param aadAdminType string = 'User'
param databaseName string = 'appdb'

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var functionAppName = !empty(apiServiceName) ? apiServiceName : '${abbrs.webSitesFunctions}api-${resourceToken}'
var deploymentStorageContainerName = 'app-package-${take(functionAppName, 32)}-${take(toLower(uniqueString(functionAppName, resourceToken)), 7)}'
var queueName = 'app-queue-${take(functionAppName, 32)}-${take(toLower(uniqueString(functionAppName, resourceToken)), 7)}'

// Organize resources in a resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

// User assigned managed identity to be used by the function app to reach storage
module apiUserAssignedIdentity './core/identity/userAssignedIdentity.bicep' = {
  name: 'apiUserAssignedIdentity'
  scope: rg
  params: {
    location: location
    tags: tags
    identityName: !empty(apiUserAssignedIdentityName) ? apiUserAssignedIdentityName : '${abbrs.managedIdentityUserAssignedIdentities}api-${resourceToken}'
  }
}

// The application backend is a function app
module appServicePlan './core/host/appserviceplan.bicep' = {
  name: 'appserviceplan'
  scope: rg
  params: {
    name: !empty(appServicePlanName) ? appServicePlanName : '${abbrs.webServerFarms}${resourceToken}'
    location: location
    tags: tags
    sku: {
      name: 'FC1'
      tier: 'FlexConsumption'
    }
  }
}

module api './app/api.bicep' = {
  name: 'api'
  scope: rg
  params: {
    name: functionAppName
    location: location
    tags: tags
    applicationInsightsName: monitoring.outputs.applicationInsightsName
    appServicePlanId: appServicePlan.outputs.id
    runtimeName: 'python'
    runtimeVersion: '3.11'
    storageAccountName: storage.outputs.name
    deploymentStorageContainerName: deploymentStorageContainerName
    identityId: apiUserAssignedIdentity.outputs.identityId
    identityClientId: apiUserAssignedIdentity.outputs.identityClientId
    appSettings: {
      POSTGRES_HOST: pg.outputs.POSTGRES_DOMAIN_NAME
      POSTGRES_NAME: pg.outputs.POSTGRES_NAME
      POSTGRES_SSL: 'require'
      POSTGRES_DATABASE: databaseName
      POSTGRES_MONITORED_TABLE_NAME: POSTGRES_MONITORED_TABLE_NAME
      POSTGRES_TARGET_TABLE_NAME: POSTGRES_TARGET_TABLE_NAME
      POSTGRES_USERNAME: apiUserAssignedIdentity.outputs.identityName
      QUEUECONNECTION__serviceUri: storage.outputs.primaryEndpoints.queue
      QUEUE_NAME: queueName
    }
    virtualNetworkSubnetId: skipVnet ? '' : serviceVirtualNetwork.outputs.appSubnetID
  }
}

// Backing storage for Azure functions api
module storage './core/storage/storage-account.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    name: !empty(storageAccountName) ? storageAccountName : '${abbrs.storageStorageAccounts}${resourceToken}'
    location: location
    tags: tags
    containers: [{name: deploymentStorageContainerName}]
    queues: [queueName]
    publicNetworkAccess: 'Enabled'
    networkAcls: skipVnet ? {} : {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: empty(myIpAddress)
        ? []
        : [
            {
              value: myIpAddress
            }
          ]
    }
  }
}

module accessForApp 'app/all-access.bicep' = {
  name: 'accessForApp'
  scope: rg
  params: {
    storageName: storage.outputs.name
    principalId: apiUserAssignedIdentity.outputs.identityPrincipalId
  }
}

module accessForUser 'app/all-access.bicep' = if (!empty(principalId)) {
  name: 'accessForUser'
  scope: rg
  params: {
    storageName: storage.outputs.name
    principalId: principalId
    principalType: 'User'
  }
}

// Virtual Network & private endpoint to blob storage
module serviceVirtualNetwork 'app/vnet.bicep' = if (!skipVnet) {
  name: 'serviceVirtualNetwork'
  scope: rg
  params: {
    location: location
    tags: tags
    vNetName: !empty(vNetName) ? vNetName : '${abbrs.networkVirtualNetworks}${resourceToken}'
  }
}

module storagePrivateEndpoint 'app/storage-PrivateEndpoint.bicep' = if (!skipVnet) {
  name: 'storagePrivateEndpoint'
  scope: rg
  params: {
    location: location
    tags: tags
    virtualNetworkName: !empty(vNetName) ? vNetName : '${abbrs.networkVirtualNetworks}${resourceToken}'
    subnetName: skipVnet ? '' : serviceVirtualNetwork.outputs.peSubnetName
    resourceName: storage.outputs.name
  }
}

// Monitor application with Azure Monitor
module monitoring './core/monitor/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    tags: tags
    logAnalyticsName: !empty(logAnalyticsName) ? logAnalyticsName : '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: !empty(applicationInsightsName) ? applicationInsightsName : '${abbrs.insightsComponents}${resourceToken}'
    disableLocalAuth: disableLocalAuth
  }
}

var monitoringRoleDefinitionId = '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher role ID

// Allow access from api to application insights using a managed identity
module appInsightsRoleAssignmentApi './core/monitor/appinsights-access.bicep' = {
  name: 'appInsightsRoleAssignmentApi'
  scope: rg
  params: {
    appInsightsName: monitoring.outputs.applicationInsightsName
    roleDefinitionID: monitoringRoleDefinitionId
    principalID: apiUserAssignedIdentity.outputs.identityPrincipalId
  }
}

module pg 'db/postgresql.bicep' = {
  name: 'pg'
  scope: rg
  params: {
    name: '${resourceToken}-postgresql'
    location: location
    tags: tags
    authType: 'EntraOnly'
    aadAdminObjectid: principalId
    aadAdminName: aadAdminName
    aadAdminType: aadAdminType
    databaseNames: [ databaseName ]
    storage: {
      storageSizeGB: 32
    }
    version: '17'
    allowAllIPsFirewall: false
    allowedSingleIPs: [ myIpAddress ]
    virtualNetworkName: serviceVirtualNetwork.outputs.vnetName
    subnetNameForPE: serviceVirtualNetwork.outputs.peSubnetName
    subnetNameForDB: serviceVirtualNetwork.outputs.dbSubnetName
  }
}

output POSTGRES_ADMIN string = aadAdminName
output POSTGRES_DATABASE string = databaseName
output POSTGRES_HOST string = pg.outputs.POSTGRES_DOMAIN_NAME
output POSTGRES_SSL string = 'require'
output POSTGRES_NAME string = pg.outputs.POSTGRES_NAME
output POSTGRES_MONITORED_TABLE_NAME string = POSTGRES_MONITORED_TABLE_NAME
output POSTGRES_TARGET_TABLE_NAME string = POSTGRES_TARGET_TABLE_NAME
output IDENTITY_NAME string = apiUserAssignedIdentity.outputs.identityName

output STORAGE_ACCOUNT_NAME string = storage.outputs.name
output QUEUE_ENDPOINT string = storage.outputs.primaryEndpoints.queue
output QUEUE_NAME string = queueName

// App outputs
output APPLICATIONINSIGHTS_CONNECTION_STRING string = monitoring.outputs.applicationInsightsConnectionString
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output SERVICE_API_NAME string = api.outputs.SERVICE_API_NAME
output AZURE_FUNCTION_NAME string = api.outputs.SERVICE_API_NAME
