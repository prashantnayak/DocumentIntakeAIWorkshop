// Optional, non-production test access: a private Windows VM and free
// Developer-tier Azure Bastion host in the workload VNet. The VM is intended
// only for workshop validation of private endpoints and must not hold PHI.
metadata name = 'test-access'
metadata description = 'Private Windows test VM with Developer Azure Bastion, Entra join, automatic shutdown, and workshop tooling.'

@description('Azure region.')
param location string

@description('Common resource tags.')
param tags object

@description('Name of the Windows test VM.')
param vmName string

@description('Name of the Developer Bastion resource.')
param bastionName string

@description('VM size validated for the target subscription and region.')
param vmSize string

@description('Resource ID of the existing workload VNet.')
param virtualNetworkResourceId string

@description('Resource ID of the dedicated test VM subnet.')
param testVmSubnetResourceId string

@description('Resource ID of the NSG associated with the test VM subnet.')
param testVmNsgResourceId string

@description('Local fallback administrator username.')
param adminUsername string

@secure()
@description('Temporary local fallback administrator password.')
param adminPassword string

@description('Object ID granted Virtual Machine Administrator Login.')
param administratorObjectId string

@description('Daily automatic shutdown time in HHmm format.')
param autoShutdownTime string = '1900'

var vmAdministratorLoginRoleId = '1c0163c0-47e6-4577-8991-ea5c82e286e4'
var bootstrapCommand = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = \'Stop\'; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force; Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; Install-Module -Name Az.Accounts,SqlServer -Scope AllUsers -Force -AllowClobber"'

module vm 'br/public:avm/res/compute/virtual-machine:0.15.0' = {
  name: take('vm-${vmName}-deploy', 64)
  params: {
    name: vmName
    computerName: take(replace(vmName, '-', ''), 15)
    location: location
    tags: tags
    zone: 0
    osType: 'Windows'
    vmSize: vmSize
    imageReference: {
      publisher: 'MicrosoftWindowsServer'
      offer: 'WindowsServer'
      sku: '2022-datacenter-azure-edition'
      version: 'latest'
    }
    osDisk: {
      name: '${vmName}-osdisk'
      createOption: 'FromImage'
      deleteOption: 'Delete'
      caching: 'ReadWrite'
      diskSizeGB: 128
      managedDisk: {
        storageAccountType: 'StandardSSD_LRS'
      }
    }
    adminUsername: adminUsername
    adminPassword: adminPassword
    managedIdentities: {
      systemAssigned: true
    }
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    // Workshop exception: this subscription has not enabled the
    // Microsoft.Compute/EncryptionAtHost feature. Managed-disk encryption at
    // rest, Trusted Launch, Secure Boot, and vTPM remain enabled. This VM must
    // handle synthetic fixtures only and is not approved for PHI.
    encryptionAtHost: false
    patchMode: 'AutomaticByPlatform'
    enableAutomaticUpdates: true
    bootDiagnostics: true
    extensionAadJoinConfig: {
      enabled: true
    }
    extensionCustomScriptConfig: {
      enabled: true
      name: 'bootstrap-test-tools'
      fileData: []
    }
    extensionCustomScriptProtectedSetting: {
      commandToExecute: bootstrapCommand
    }
    nicConfigurations: [
      {
        name: '${vmName}-nic'
        enableAcceleratedNetworking: true
        enableIPForwarding: false
        deleteOption: 'Delete'
        networkSecurityGroupResourceId: testVmNsgResourceId
        ipConfigurations: [
          {
            name: 'ipconfig'
            privateIPAllocationMethod: 'Dynamic'
            privateIPAddressVersion: 'IPv4'
            subnetResourceId: testVmSubnetResourceId
          }
        ]
      }
    ]
    roleAssignments: [
      {
        principalId: administratorObjectId
        roleDefinitionIdOrName: vmAdministratorLoginRoleId
        principalType: 'User'
        description: 'Workshop operator: sign in to the private test VM for deployment validation.'
      }
    ]
  }
}

module bastion 'br/public:avm/res/network/bastion-host:0.8.0' = {
  name: take('bas-${bastionName}-deploy', 64)
  params: {
    name: bastionName
    location: location
    tags: tags
    skuName: 'Developer'
    virtualNetworkResourceId: virtualNetworkResourceId
  }
}

resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: 'W. Europe Standard Time'
    notificationSettings: {
      status: 'Disabled'
    }
    targetResourceId: vm.outputs.resourceId
  }
}

@description('Name of the test VM.')
output vmName string = vm.outputs.name

@description('Resource ID of the test VM.')
output vmResourceId string = vm.outputs.resourceId

@description('Principal ID of the test VM system-assigned identity.')
output vmPrincipalId string = vm.outputs.?systemAssignedMIPrincipalId ?? ''

@description('Name of the Developer Bastion resource.')
output bastionName string = bastion.outputs.name
