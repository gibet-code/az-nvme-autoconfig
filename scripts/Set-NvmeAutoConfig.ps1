#requires -Version 5.1
<#
.SYNOPSIS
Configures undocumented Azure temp NVMe boot provisioning. Run elevated.
.DESCRIPTION
Array parameters use JSON strings so this file works unchanged with managed
Run Command, action Run Command, Azure PowerShell and manual invocation.
Only the lab reset companion script clears disks.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[D-Zd-z]$')]
    [string] $DriveLetter = 'D',

    [ValidateLength(1, 32)]
    [ValidatePattern('^[^''"\\/:*?<>|\x00-\x1f]+$')]
    [string] $VolumeLabel = 'SQLTemp',

    [string] $VolumePathsJson = '["tempdb\\data","tempdb\\log"]',
    [string] $DiskModelsJson = '["Microsoft NVMe Direct Disk v2"]',

    [ValidateSet(4096, 8192, 16384, 32768, 65536)]
    [int] $VolumeClusterSize = 65536,

    [ValidateRange(4096, 1048576)]
    [int] $VirtualDiskStripeSize = 65536,

    [string] $RunTag = 'manual'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$DriveLetter = $DriveLetter.ToUpperInvariant()

# Check JSON shape before conversion can unwrap a single-element array.
if ($VolumePathsJson -notmatch '^\s*\[' -or $DiskModelsJson -notmatch '^\s*\[') {
    throw 'VolumePathsJson and DiskModelsJson must be JSON arrays of strings.'
}
$requestedPaths = ConvertFrom-Json -InputObject $VolumePathsJson
$diskModels = ConvertFrom-Json -InputObject $DiskModelsJson
if ($requestedPaths -isnot [array] -or $diskModels -isnot [array]) {
    throw 'VolumePathsJson and DiskModelsJson must be JSON arrays of strings.'
}
$nativeVolumePaths = [System.Collections.Generic.List[string]]::new()
$seenPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($path in $requestedPaths) {
    if ($path -is [string] -and $path -match '^([a-z]):\\') {
        if ($Matches[1] -ne $DriveLetter) {
            throw "Folder '$path' must use the configured drive letter $($DriveLetter):."
        }
        $path = $path.Substring(3)
    }
    if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path) -or
        $path -match '[''"/:*?<>|\x00-\x1f]' -or $path -match '\.\.' -or
        $path -match '(^\\|\\$|\\\\|(^|\\)\.(\\|$)|[. ](\\|$))' -or
        $path -match '(^|\\)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|\\|$)') {
        throw "Invalid folder '$path'. Use a safe relative folder or a full path on $($DriveLetter): with no quotes, traversal, reserved names or empty segments."
    }
    # Native creation needs a leading separator and does not create missing parents.
    $nativePath = ''
    foreach ($segment in $path.Split('\')) {
        $nativePath += "\$segment"
        if ($seenPaths.Add($nativePath)) { $nativeVolumePaths.Add($nativePath) }
    }
}
if ($diskModels.Count -eq 0) { throw 'At least one exact disk model is required.' }
foreach ($model in $diskModels) {
    if ($model -isnot [string] -or [string]::IsNullOrWhiteSpace($model) -or $model -match '[''"\x00-\x1f]') {
        throw 'Disk model names must be nonempty strings without quotes or control characters.'
    }
}
if (($VirtualDiskStripeSize -band ($VirtualDiskStripeSize - 1)) -ne 0) {
    throw 'VirtualDiskStripeSize must be a power of two between 4096 and 1048576.'
}

function Assert-NvmeFolderPath {
    param([switch] $RequirePresent)
    foreach ($path in $nativeVolumePaths) {
        $fullPath = "$($DriveLetter):$path"
        if (-not (Test-Path -LiteralPath $fullPath)) {
            if ($RequirePresent) {
                throw "Missing folder after autoconfigw: $fullPath. Inspect $env:WINDIR\Logs\Autoconfig\autoconfig.log before another invocation overwrites it."
            }
            continue
        }
        $item = Get-Item -LiteralPath $fullPath -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing folder path through a file or reparse point: $fullPath"
        }
        if ($RequirePresent) { Write-Output "Folder: $fullPath" }
    }
}

$existingVolume = Get-CimInstance Win32_Volume -Filter "DriveLetter='$($DriveLetter):'"
$alreadyProvisioned = $null -ne $existingVolume -and $existingVolume.DriveType -eq 3 -and $existingVolume.Label -eq $VolumeLabel
if ($existingVolume -and $existingVolume.DriveType -ne 5 -and -not $alreadyProvisioned) {
    throw "$($DriveLetter): holds another volume. Nothing was changed; choose another letter."
}
if ($alreadyProvisioned -and ($existingVolume.FileSystem -ne 'NTFS' -or $existingVolume.BlockSize -ne $VolumeClusterSize)) {
    throw 'Volume exists but NTFS/cluster size differs from requested settings. Existing volumes are never reformatted.'
}
foreach ($exe in @('autoconfig.exe', 'autoconfigw.exe')) {
    $binary = Join-Path $env:WINDIR "System32\$exe"
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw "Required binary missing: $binary. Install LocalStoragePrepExtension first."
    }
}
$disks = @(Get-Disk | Where-Object { $diskModels -contains $_.FriendlyName })
if ($disks.Count -eq 0) { throw 'No disk matches DiskModelsJson. Nothing was changed.' }
foreach ($disk in $disks) {
    if ($disk.IsBoot -or $disk.IsSystem -or "$($disk.BusType)" -ne 'NVMe') {
        throw "Disk $($disk.Number) is not a safe temp NVMe candidate. Nothing was changed."
    }
    if (-not $alreadyProvisioned -and ($disk.PartitionStyle -ne 'RAW' -or $disk.IsOffline -or $disk.IsReadOnly)) {
        throw "Disk $($disk.Number) is not RAW, online and writable. Nothing was changed. Investigate; do not clear a production disk."
    }
    if ($alreadyProvisioned -and ($disk.PartitionStyle -eq 'RAW' -or $disk.IsOffline -or $disk.IsReadOnly)) {
        throw "Disk $($disk.Number) must be initialized, online and writable when refreshing an existing volume. Nothing was changed; refusing possible additional disk provisioning."
    }
}
if ($alreadyProvisioned) { Assert-NvmeFolderPath }

$sessionPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
$autoConfigPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\AutoConfig'
$session = Get-ItemProperty -LiteralPath $sessionPath
$bootProperty = $session.PSObject.Properties['BootExecute']
$bootExecute = @()
if ($bootProperty -and $null -ne $bootProperty.Value) {
    if ($bootProperty.Value -isnot [string[]]) { throw 'BootExecute is not REG_MULTI_SZ. Nothing was changed.' }
    $bootExecute = @($bootProperty.Value)
}
if ($bootExecute.Count -eq 0) { $bootExecute = @('autocheck autochk *') }
if ($bootExecute -notcontains 'autoconfig') { $bootExecute += 'autoconfig' }

$freeLetter = $null
if ($existingVolume -and $existingVolume.DriveType -eq 5) {
    $usedLetters = @(Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter)".ToUpperInvariant() })
    $usedLetters += @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpperInvariant() })
    $freeLetter = 90..69 | ForEach-Object { [string][char]$_ } |
        Where-Object { $_ -ne $DriveLetter -and $usedLetters -notcontains $_ } | Select-Object -First 1
    if (-not $freeLetter) { throw 'No free letter E-Z for the DVD drive. Nothing was changed.' }
}
if (-not $PSCmdlet.ShouldProcess("$($DriveLetter): ($VolumeLabel)", "Configure NVMe boot provisioning (tag: $RunTag)")) { return }

if ($freeLetter) {
    $diskpartScript = Join-Path $env:TEMP ("nvme-optical-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    try {
        Set-Content -LiteralPath $diskpartScript -Value @("select volume $DriveLetter", "assign letter=$freeLetter") -Encoding Ascii
        $diskpartOutput = & diskpart.exe /s $diskpartScript 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "DVD reassignment failed: $diskpartOutput" }
        if (Get-CimInstance Win32_Volume -Filter "DriveLetter='$($DriveLetter):'") {
            throw "DVD reassignment did not free $($DriveLetter):. Output: $diskpartOutput"
        }
        Write-Output "Moved DVD from $($DriveLetter): to $($freeLetter):."
    } finally {
        if (Test-Path -LiteralPath $diskpartScript) { Remove-Item -LiteralPath $diskpartScript -Force }
    }
}

$null = New-Item -Path $autoConfigPath -Force
$settings = @(
    @{ Name = 'PhysicalDiskModel'; Value = [string[]]$diskModels; Type = 'MultiString' }
    @{ Name = 'VolumeLabel'; Value = $VolumeLabel; Type = 'String' }
    @{ Name = 'VolumeDriveLetter'; Value = $DriveLetter; Type = 'String' }
    @{ Name = 'VolumePaths'; Value = [string[]]$nativeVolumePaths.ToArray(); Type = 'MultiString' }
    @{ Name = 'VirtualDiskStripeSize'; Value = $VirtualDiskStripeSize; Type = 'DWord' }
    @{ Name = 'VolumeClusterSize'; Value = $VolumeClusterSize; Type = 'DWord' }
)
foreach ($setting in $settings) {
    $null = New-ItemProperty -LiteralPath $autoConfigPath -Name $setting.Name -Value $setting.Value -PropertyType $setting.Type -Force
}
$null = New-ItemProperty -LiteralPath $sessionPath -Name BootExecute -Value ([string[]]$bootExecute) -PropertyType MultiString -Force

$process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\autoconfigw.exe') -Wait -PassThru -WindowStyle Hidden
if ($process.ExitCode -ne 0) {
    throw "autoconfigw.exe failed with exit code $($process.ExitCode). Boot configuration remains installed; inspect before retrying."
}
$volume = $null
for ($attempt = 0; $attempt -lt 12; $attempt++) {
    $volume = Get-CimInstance Win32_Volume -Filter "DriveLetter='$($DriveLetter):'" |
        Where-Object { $_.DriveType -eq 3 -and $_.Label -eq $VolumeLabel }
    if ($volume) { break }
    Start-Sleep -Seconds 5
}
if (-not $volume) {
    $state = Get-Disk | Select-Object Number, FriendlyName, PartitionStyle, IsOffline, IsReadOnly | Out-String
    throw "No expected volume after autoconfigw. Boot configuration remains installed. Disk state: $state"
}
if ($volume.FileSystem -ne 'NTFS' -or $volume.BlockSize -ne $VolumeClusterSize) {
    throw "Volume exists but NTFS/cluster size differs from requested settings. Existing volumes are never reformatted."
}
Assert-NvmeFolderPath -RequirePresent
Write-Output "BootExecute: $($bootExecute -join ' | ')"
Write-Output "OK: $($DriveLetter): $VolumeLabel, NTFS, $VolumeClusterSize bytes/cluster. SQL placement and ACLs are separate."
