@description('The name of Azure Compute Gallery')
param imageGalleryName string = ''

@description('The name of Azure Compute Gallery image definition')
param imageDefinitionName string = ''

@description('Primary location for all resources e.g. eastus')
param location string = resourceGroup().location

@description('Guid for generating random template name')
param guidId string = newGuid()

@description('Base image publisher')
param baseImagePublisher string = 'MicrosoftWindowsDesktop'

@description('Base image offer')
param baseImageOffer string = 'windows-ent-cpc'

@description('Base image SKU')
param baseImageSku string = 'win11-22h2-ent-cpc-m365'

var resourceToken = toLower(uniqueString(resourceGroup().id, location))
var templateIdentityName = 'id-tpl-${resourceToken}'
var templateRoleDefinitionName = guid(resourceGroup().id)
var imageDefName = !empty(imageDefinitionName) ? imageDefinitionName : 'image-${resourceToken}'
var imageBuildName = take('${imageDefName}-${guidId}-buid',64)
var imageTemplateName = take('${imageDefName}-${guidId}_template',64)
var queryTemplateProgress = take('${imageDefName}-${guidId}-query',64)
var buildCommand = 'Invoke-AzResourceAction -ResourceName "${imageTemplateName}" -ResourceGroupName "${resourceGroup().name}" -ResourceType "Microsoft.VirtualMachineImages/imageTemplates" -ApiVersion "2020-02-14" -Action Run -Force'
var galleryName = !empty(imageGalleryName) ? imageGalleryName : 'gal${resourceToken}'

resource computeGallery 'Microsoft.Compute/galleries@2022-03-03' = {
  name: galleryName
  location: location
}

resource imageDefinition 'Microsoft.Compute/galleries/images@2022-03-03' = {
  parent: computeGallery
  name: imageDefName
  location: location
  properties: {
    hyperVGeneration: 'V2'
    architecture: 'x64'
    features: [
      {
          name: 'SecurityType'
          value: 'TrustedLaunch'
      }
    ]
    identifier: {
      offer: baseImageOffer
      publisher: baseImagePublisher
      sku: '${baseImageSku}-${imageDefName}'
    }
    osState: 'Generalized'
    osType: 'Windows'
  }
}

resource templateIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2022-01-31-preview' = {
  name: templateIdentityName
  location: location
}

resource templateRoleDefinition 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: templateRoleDefinitionName
  properties: {
    roleName: templateRoleDefinitionName
    description: 'Image Builder access to create resources for the image build, you should delete or split out as appropriate'
    type: 'customRole'
    permissions: [
      {
        actions: [
          'Microsoft.Compute/galleries/read'
          'Microsoft.Compute/galleries/images/read'
          'Microsoft.Compute/galleries/images/versions/read'
          'Microsoft.Compute/galleries/images/versions/write'
          'Microsoft.Compute/images/write'
          'Microsoft.Compute/images/read'
          'Microsoft.Compute/images/delete'
          'Microsoft.Storage/storageAccounts/blobServices/containers/read'
          'Microsoft.Storage/storageAccounts/blobServices/containers/write'
          'Microsoft.Resources/deployments/read'
          'Microsoft.Resources/deploymentScripts/read'
          'Microsoft.Resources/deploymentScripts/write'
          'Microsoft.VirtualMachineImages/imageTemplates/run/action'
          'Microsoft.ContainerInstance/containerGroups/read'
          'Microsoft.ContainerInstance/containerGroups/write'
          'Microsoft.ContainerInstance/containerGroups/start/action'
        ]
      }
    ]
    assignableScopes: [
      resourceGroup().id
    ]
  }
}

resource templateRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, '${templateRoleDefinition.id}', templateIdentity.id)
  properties: {
    roleDefinitionId: templateRoleDefinition.id
    principalId: templateIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

var readerDefinitionId =  resourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
resource readerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, readerDefinitionId, templateIdentity.id)
  properties: {
    roleDefinitionId: readerDefinitionId
    principalId: templateIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource imageTemplate 'Microsoft.VirtualMachineImages/imageTemplates@2022-02-14' = {
  name: imageTemplateName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${templateIdentity.id}': {}
    }
  }
  properties: {
    buildTimeoutInMinutes: 180
    vmProfile: {
      vmSize: 'Standard_DS2_v2'
      osDiskSizeGB: 127
    }
    source: {
      type: 'PlatformImage'
      offer: baseImageOffer
      publisher: baseImagePublisher
      sku: baseImageSku
      version: 'Latest'
    }
    customize: [
      {
        type: 'PowerShell'
        name: 'Install Choco'
        inline: [
          'Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString(\'https://community.chocolatey.org/install.ps1\'))'
        ]
      }
      {
        type: 'PowerShell'
        name: 'Install VS Code, Python, Azure CLI, Git, and Jupyter notebook extensions'
        inline: [
          'choco install -y git'
          'choco install -y azure-cli'
          'choco install -y vscode'
          'choco install -y python'
          'choco install -y nodejs-lts'
          '$vscode_extension_dir="C:/temp/extensions"; New-Item $vscode_extension_dir -ItemType Directory -Force; [Environment]::SetEnvironmentVariable("VSCODE_EXTENSIONS", $vscode_extension_dir, "Machine"); $env:VSCODE_EXTENSIONS=$vscode_extension_dir; Start-Process -FilePath "C:/Program Files/Microsoft VS Code/bin/code.cmd"  -ArgumentList " --install-extension github.copilot"  -Wait -NoNewWindow; Start-Process -FilePath "C:/Program Files/Microsoft VS Code/bin/code.cmd"  -ArgumentList " --install-extension ms-vscode.vscode-node-azure-pack"  -Wait -NoNewWindow; Start-Process -FilePath "C:/Program Files/Microsoft VS Code/bin/code.cmd"  -ArgumentList " --install-extension ms-azuretools.azure-dev"  -Wait -NoNewWindow; Start-Process -FilePath "C:/Program Files/Microsoft VS Code/bin/code.cmd"  -ArgumentList " --install-extension ms-python.python"  -Wait -NoNewWindow; Start-Process -FilePath "C:/Program Files/Microsoft VS Code/bin/code.cmd"  -ArgumentList " --install-extension ms-toolsai.jupyter"  -Wait -NoNewWindow'
        ]
      }
    ]
    distribute: [
      {
        type: 'SharedImage'
        galleryImageId: imageDefinition.id
        runOutputName: '${imageDefName}_Output'
        replicationRegions: array(location)
      }
    ]
  }
  dependsOn: [
    templateRoleAssignment
  ]
}

resource imageTemplateBuild 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: imageBuildName
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${templateIdentity.id}': {}
    }
  }
  dependsOn: [
    imageTemplate
    templateRoleAssignment
  ]
  properties: {
    forceUpdateTag: guidId
    azPowerShellVersion: '8.3'
    scriptContent: buildCommand
    timeout: 'PT3H'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
  }
}

resource imageTemplateStatusQuery 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: queryTemplateProgress
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${templateIdentity.id}': {}
    }
  }
  properties: {
    azPowerShellVersion: '8.3'
    scriptContent: 'Connect-AzAccount -Identity; \'Az.ImageBuilder\', \'Az.ManagedServiceIdentity\' | ForEach-Object {Install-Module -Name $_ -AllowPrerelease -Force}; $status=\'Started\'; while ($status -ne \'Succeeded\' -and $status -ne \'Failed\' -and $status -ne \'Cancelled\') { Start-Sleep -Seconds 30;$status = (Get-AzImageBuilderTemplate -ImageTemplateName ${imageTemplateName} -ResourceGroupName ${resourceGroup().name}).LastRunStatusRunState}'  
    timeout: 'PT3H'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
  }
  dependsOn: [
    imageTemplate
    imageTemplateBuild
  ]
}

output galleryName string = computeGallery.name
output imageDefinitionName string = imageDefinition.name
output imageTemplateName string = imageTemplate.name
