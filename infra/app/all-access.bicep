param storageName string
param principalId string
@allowed(['ServicePrincipal', 'User'])
param principalType string = 'ServicePrincipal'

var storageRoleDefinitionId  = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' //Storage Blob Data Owner role
var queueSenderRoleDefinitionId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Message Sender role
var queueProcessorRoleDefinitionId = '8a0f0c08-91a1-4084-bc3d-661d67233fed' // Storage Queue Data Message Processor role

// Allow access to storage account using a managed identity
module storageBlobRoleAssignment 'storage-Access.bicep' = {
  name: 'storageBlobRoleAssignment${principalType}'
  params: {
    storageAccountName: storageName
    roleDefinitionID: storageRoleDefinitionId
    principalID: principalId
    principalType: principalType
  }
}

module storageQueueRoleAssignment 'storage-Access.bicep' = {
  name: 'storageQueueRoleAssignment${principalType}'
  params: {
    storageAccountName: storageName
    roleDefinitionID: queueSenderRoleDefinitionId
    principalID: principalId
    principalType: principalType
  }
}

module storageQueueProcessorRoleAssignment 'storage-Access.bicep' = {
  name: 'storageQueueProcessorRoleAssignment${principalType}'
  params: {
    storageAccountName: storageName
    roleDefinitionID: queueProcessorRoleDefinitionId
    principalID: principalId
    principalType: principalType
  }
}
