#requires -Version 5.1
<#
.SYNOPSIS
Removes only autoconfig from BootExecute and deletes its configuration key.
.DESCRIPTION
Run elevated. Move tempdb elsewhere first. Does not delete volumes or binaries,
move the optical drive back, or remove Azure resources.
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$sessionPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
$autoConfigPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\AutoConfig'
$session = Get-ItemProperty -LiteralPath $sessionPath
$property = $session.PSObject.Properties['BootExecute']
if ($property -and $null -ne $property.Value -and $property.Value -isnot [string[]]) {
    throw 'BootExecute is not REG_MULTI_SZ. Nothing was changed.'
}
if ($PSCmdlet.ShouldProcess('AutoConfig and BootExecute', 'Remove NVMe boot provisioning')) {
    if ($property -and $null -ne $property.Value) {
        $remaining = [string[]]@($property.Value | Where-Object { $_ -ine 'autoconfig' })
        $null = New-ItemProperty -LiteralPath $sessionPath -Name BootExecute -Value $remaining -PropertyType MultiString -Force
    }
    if (Test-Path -LiteralPath $autoConfigPath) {
        Remove-Item -LiteralPath $autoConfigPath -Recurse -Force
    }
    Write-Output 'AutoConfig removed. Existing volume and binaries retained. Temp storage can disappear on deallocation.'
}
