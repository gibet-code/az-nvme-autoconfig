#requires -Version 5.1
<#
.SYNOPSIS
LAB ONLY: destroys one explicitly selected Microsoft temp NVMe disk.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateRange(0, 65535)]
    [int] $DiskNumber,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
if (-not $Force) { throw 'LAB ONLY: -Force is required. This destroys all data on the selected temp disk.' }
$disk = Get-Disk -Number $DiskNumber
if ($disk.FriendlyName -ne 'Microsoft NVMe Direct Disk v2' -or "$($disk.BusType)" -ne 'NVMe' -or $disk.IsBoot -or $disk.IsSystem) {
    throw 'Refusing: disk is not the expected non-system Microsoft NVMe Direct Disk v2.'
}
if ($PSCmdlet.ShouldProcess("LAB disk $DiskNumber ($($disk.FriendlyName))", 'DESTROY all partitions and data')) {
    Set-Disk -Number $DiskNumber -IsOffline $false
    Set-Disk -Number $DiskNumber -IsReadOnly $false
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    Update-HostStorageCache
    $result = Get-Disk -Number $DiskNumber
    if ($result.PartitionStyle -ne 'RAW' -or $result.IsOffline -or $result.IsReadOnly) {
        throw 'Reset did not produce a RAW, online, writable disk.'
    }
    $result | Select-Object Number, FriendlyName, PartitionStyle, IsOffline, IsReadOnly
}
