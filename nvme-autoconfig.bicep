targetScope = 'resourceGroup'

@description('Existing, running Windows VM in the deployment resource group.')
@minLength(1)
param vmName string

@description('Single drive letter D-Z, without a colon. Validated in the guest before changes.')
@minLength(1)
@maxLength(1)
param driveLetter string = 'D'

@description('Volume label, without quotes or NTFS-invalid characters. Maximum 32 characters.')
@minLength(1)
@maxLength(32)
param volumeLabel string = 'SQLTemp'

@description('Relative folders or full paths on driveLetter (for example D:\\tempdb\\data). Guest validation rejects mismatched drives and unsafe paths, then writes leading-backslash, parent-first native entries. An empty array creates no folders (unverified on Azure).')
param volumePaths string[] = [
  'tempdb\\data'
  'tempdb\\log'
]

@description('Exact NVMe temp disk model names. Never specify a persistent/data disk model.')
@minLength(1)
param diskModels string[] = [
  'Microsoft NVMe Direct Disk v2'
]

@description('NTFS allocation unit size in bytes.')
@allowed([4096, 8192, 16384, 32768, 65536])
param volumeClusterSize int = 65536

@description('Stripe size in bytes. Multi-disk behavior remains unverified.')
@minValue(4096)
@maxValue(1048576)
param virtualDiskStripeSize int = 65536

@description('Changes the run-command parameters on redeployment. Supply a new value when retrying.')
param runTag string = utcNow()

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' existing = {
  name: vmName
}

// Resolve the existing VM's region before the child deployment starts.
module configuration 'modules/configure-vm.bicep' = {
  name: 'nvmeAutoConfig-${uniqueString(vm.id)}'
  params: {
    vmName: vm.name
    location: vm.location
    driveLetter: driveLetter
    volumeLabel: volumeLabel
    volumePaths: volumePaths
    diskModels: diskModels
    volumeClusterSize: volumeClusterSize
    virtualDiskStripeSize: virtualDiskStripeSize
    runTag: runTag
  }
}

output runCommandName string = configuration.outputs.runCommandName
output checkResult string = configuration.outputs.checkResult
