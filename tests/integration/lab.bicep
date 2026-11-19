targetScope = 'resourceGroup'

@description('Region approved for this disposable lab.')
param location string

@description('Temporary lab administrator username.')
param adminUsername string = 'nvmetestadmin'

@secure()
@description('Temporary lab password; never store in source or logs.')
param adminPassword string

@description('Pinned Marketplace image version, resolved before deployment.')
param imageVersion string

@description('Approved VM sizes; one NVMe VM and one negative control.')
param vmSizes string[] = ['Standard_D2ds_v6', 'Standard_D2s_v6']

resource network 'Microsoft.Network/virtualNetworks@2025-01-01' = {
  name: 'nvme-lab-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.98.0.0/16'] }
    subnets: [
      { name: 'lab', properties: { addressPrefix: '10.98.0.0/24' } }
    ]
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2025-01-01' = {
  name: 'nvme-lab-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'DenyInbound'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// Explicit outbound access lets the VM agent download extensions without inbound access.
resource outboundIp 'Microsoft.Network/publicIPAddresses@2025-01-01' = {
  name: 'nvme-lab-outbound-ip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nat 'Microsoft.Network/natGateways@2025-01-01' = {
  name: 'nvme-lab-nat'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIpAddresses: [{ id: outboundIp.id }]
    idleTimeoutInMinutes: 4
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2025-01-01' = {
  parent: network
  name: 'lab'
  properties: {
    addressPrefix: '10.98.0.0/24'
    networkSecurityGroup: { id: nsg.id }
    natGateway: { id: nat.id }
  }
}

resource interfaces 'Microsoft.Network/networkInterfaces@2025-01-01' = [for (_, index) in vmSizes: {
  name: 'nvme-lab-nic-${index}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: subnet.id }
        }
      }
    ]
  }
}]

resource machines 'Microsoft.Compute/virtualMachines@2025-04-01' = [for (size, index) in vmSizes: {
  name: 'nvme-lab-${index}'
  location: location
  properties: {
    hardwareProfile: { vmSize: size }
    osProfile: {
      computerName: 'nvme-lab-${index}'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: imageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        deleteOption: 'Delete'
      }
    }
    networkProfile: { networkInterfaces: [{ id: interfaces[index].id, properties: { deleteOption: 'Delete' } }] }
  }
}]
