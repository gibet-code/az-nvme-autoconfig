targetScope = 'resourceGroup'

param vmName string
param location string
param driveLetter string
param volumeLabel string
param volumePaths string[]
param diskModels string[]
param volumeClusterSize int
param virtualDiskStripeSize int
param runTag string

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' existing = {
  name: vmName
}

resource localStoragePrep 'Microsoft.Compute/virtualMachines/extensions@2026-04-01' = {
  parent: vm
  name: 'LocalStoragePrepExtension'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.HostStorage'
    type: 'LocalStoragePrepExtension'
    typeHandlerVersion: '0.1'
    autoUpgradeMinorVersion: true
    settings: {}
  }
}

resource nvmeAutoConfig 'Microsoft.Compute/virtualMachines/runCommands@2026-04-01' = {
  parent: vm
  name: 'nvmeAutoConfigRunCommand'
  location: location
  dependsOn: [
    localStoragePrep
  ]
  properties: {
    source: {
      script: loadTextContent('../scripts/Set-NvmeAutoConfig.ps1')
    }
    parameters: [
      { name: 'DriveLetter', value: toUpper(driveLetter) }
      { name: 'VolumeLabel', value: volumeLabel }
      { name: 'VolumePathsJson', value: string(volumePaths) }
      { name: 'DiskModelsJson', value: string(diskModels) }
      { name: 'VolumeClusterSize', value: string(volumeClusterSize) }
      { name: 'VirtualDiskStripeSize', value: string(virtualDiskStripeSize) }
      { name: 'RunTag', value: runTag }
    ]
    asyncExecution: false
    treatFailureAsDeploymentFailure: true
    timeoutInSeconds: 900
  }
}

output runCommandName string = nvmeAutoConfig.name
output checkResult string = 'az vm run-command show -g ${resourceGroup().name} --vm-name ${vmName} --run-command-name ${nvmeAutoConfig.name} --instance-view'
