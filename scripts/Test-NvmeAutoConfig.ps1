#requires -Version 5.1
<#
.SYNOPSIS
Read-only NVMe health check. Emits a final OK/NOT OK line; failure also throws.
.DESCRIPTION
Uses AutoConfig registry values as expectations. Optional SQL queries use
integrated authentication; SQL connection/permission failures are reported.
#>
[CmdletBinding()]
param(
    [string[]] $SqlInstance = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$issues = [System.Collections.Generic.List[string]]::new()
$autoConfigPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\AutoConfig'
try {
    foreach ($exe in @('autoconfig.exe', 'autoconfigw.exe')) {
        $exists = Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\$exe") -PathType Leaf
        Write-Output "$exe present: $exists"
        if (-not $exists) { $issues.Add("Missing $exe") }
    }
    $session = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $boot = $session.PSObject.Properties['BootExecute']
    if (-not $boot -or $boot.Value -isnot [string[]] -or @($boot.Value) -notcontains 'autoconfig') {
        $issues.Add('BootExecute lacks a valid autoconfig entry')
    }
    $session | Select-Object BootExecute | Format-List | Out-String | Write-Output
    if (-not (Test-Path -LiteralPath $autoConfigPath)) { throw 'AutoConfig registry key is absent.' }
    $config = Get-ItemProperty -LiteralPath $autoConfigPath
    $config | Format-List | Out-String | Write-Output
    $expectedTypes = @{
        PhysicalDiskModel = 'MultiString'; VolumeDriveLetter = 'String'; VolumeLabel = 'String'
        VolumePaths = 'MultiString'; VolumeClusterSize = 'DWord'; VirtualDiskStripeSize = 'DWord'
    }
    $key = Get-Item -LiteralPath $autoConfigPath
    try {
        foreach ($name in $expectedTypes.Keys) {
            if ("$($key.GetValueKind($name))" -ne $expectedTypes[$name]) { $issues.Add("Wrong registry type: $name") }
        }
    } finally { $key.Close() }
    $disks = @(Get-Disk | Where-Object { $config.PhysicalDiskModel -contains $_.FriendlyName })
    $disks | Select-Object Number, FriendlyName, BusType, PartitionStyle, IsOffline, IsReadOnly |
        Format-Table -AutoSize | Out-String | Write-Output
    Get-PhysicalDisk | Where-Object { $config.PhysicalDiskModel -contains $_.FriendlyName } |
        Select-Object FriendlyName, CanPool, CannotPoolReason, OperationalStatus |
        Format-Table -AutoSize | Out-String | Write-Output
    if ($disks.Count -eq 0) { $issues.Add('No matching temp disks') }
    $volume = Get-CimInstance Win32_Volume -Filter "DriveLetter='$($config.VolumeDriveLetter):'"
    $volume | Select-Object DriveLetter, Label, FileSystem, BlockSize, Capacity |
        Format-List | Out-String | Write-Output
    if (-not $volume -or $volume.DriveType -ne 3 -or $volume.Label -ne $config.VolumeLabel -or
        $volume.FileSystem -ne 'NTFS' -or $volume.BlockSize -ne $config.VolumeClusterSize) {
        $issues.Add('Volume missing or label/filesystem/cluster size mismatch')
    }
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $config.VolumePaths) {
        if ($path -notmatch '^\\[^\\]' -or $path -match '\\$|\\\\|[:/"*?<>|\x00-\x1f]' -or
            $path -match '(^|\\)\.\.?(\\|$)') {
            $issues.Add("Invalid native VolumePaths entry '$path'; rerun Set-NvmeAutoConfig.ps1 to normalize it")
            continue
        }
        $parentIndex = $path.LastIndexOf('\')
        if ($parentIndex -gt 0 -and -not $seenPaths.Contains($path.Substring(0, $parentIndex))) {
            $issues.Add("VolumePaths parent must precede child '$path'")
        }
        $null = $seenPaths.Add($path)
        $fullPath = "$($config.VolumeDriveLetter):$path"
        $exists = Test-Path -LiteralPath $fullPath -PathType Container
        Write-Output "Folder $fullPath exists: $exists"
        if (-not $exists) { $issues.Add("Missing folder $fullPath") }
    }
    $services = @(Get-CimInstance Win32_Service | Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' })
    $services | Select-Object Name, State, StartMode, StartName | Format-Table -AutoSize | Out-String | Write-Output
    if ($SqlInstance.Count -eq 0) {
        $SqlInstance = @($services | ForEach-Object {
            if ($_.Name -eq 'MSSQLSERVER') { '.' } else { '.\' + $_.Name.Substring(6) }
        })
    }
    foreach ($instance in $SqlInstance) {
        $connection = [System.Data.SqlClient.SqlConnection]::new(
            "Data Source=$instance;Integrated Security=SSPI;Initial Catalog=master;Connect Timeout=10")
        try {
            $connection.Open()
            $command = $connection.CreateCommand()
            $command.CommandText = 'SELECT physical_name FROM sys.master_files WHERE database_id = 2'
            $reader = $command.ExecuteReader()
            try { while ($reader.Read()) { Write-Output "SQL $instance tempdb: $($reader.GetString(0))" } }
            finally { $reader.Dispose(); $command.Dispose() }
        } finally { $connection.Dispose() }
    }
} catch {
    $issues.Add($_.Exception.Message)
}
if ($issues.Count -gt 0) {
    $message = 'NOT OK: ' + ($issues -join '; ')
    Write-Output $message
    throw $message
}
Write-Output 'OK: NVMe volume, folders, binaries and boot configuration match. SQL paths reported when installed; ACLs/startup ordering require integration tests.'
