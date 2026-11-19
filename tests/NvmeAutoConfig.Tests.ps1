#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mock state crosses invoked-script scope in Pester 5; prefixed variables are removed in AfterAll.')]
param()

AfterAll {
    foreach ($name in @('NvmeTest_cimCalls', 'NvmeTest_occupied', 'NvmeTest_noVolume',
        'NvmeTest_exitCode', 'NvmeTest_boot', 'NvmeTest_disk', 'NvmeTest_keyExists', 'NvmeTest_config', 'NvmeTest_nativeRan',
        'NvmeTest_badRegistryType')) {
        Remove-Variable -Name $name -Scope Global -ErrorAction Ignore
    }
}

BeforeAll {
    $script:setScript = Join-Path $PSScriptRoot '..\scripts\Set-NvmeAutoConfig.ps1'
    $script:testScript = Join-Path $PSScriptRoot '..\scripts\Test-NvmeAutoConfig.ps1'
    $script:removeScript = Join-Path $PSScriptRoot '..\scripts\Remove-NvmeAutoConfig.ps1'
    $script:resetScript = Join-Path $PSScriptRoot 'integration\Reset-NvmeTempDisk.ps1'
    # Provide an interceptable native-command boundary even on non-VM test hosts.
    function diskpart.exe { param($s) throw "Unmocked diskpart invocation: $s" }
    function Get-PhysicalDisk {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Test-only boundary: Pester cannot proxy Storage generated enum parameter types.')]
        param()
        throw 'Unmocked physical disk inspection.'
    }
}

Describe 'NVMe configuration guard rails (U1-U8 and S5)' {
    BeforeEach {
        $global:NvmeTest_cimCalls = 0
        $global:NvmeTest_occupied = $null
        $global:NvmeTest_noVolume = $false
        $global:NvmeTest_exitCode = 0
        $global:NvmeTest_nativeRan = $false
        $global:NvmeTest_boot = [string[]]@('autocheck autochk /q /v *', 'other-native')
        $global:NvmeTest_disk = [pscustomobject]@{
            Number = 1; FriendlyName = 'Microsoft NVMe Direct Disk v2'; BusType = 'NVMe'
            PartitionStyle = 'RAW'; IsBoot = $false; IsSystem = $false
            IsOffline = $false; IsReadOnly = $false
        }
        Mock Get-CimInstance {
            $global:NvmeTest_cimCalls++
            if ($global:NvmeTest_cimCalls -eq 1) { return $global:NvmeTest_occupied }
            if (-not $global:NvmeTest_noVolume) {
                [pscustomobject]@{ DriveType = 3; Label = 'SQLTemp'; FileSystem = 'NTFS'; BlockSize = 65536 }
            }
        }
        Mock Get-Disk { $global:NvmeTest_disk }
        Mock Test-Path { $true }
        Mock Get-Item { [pscustomobject]@{ PSIsContainer = $true; Attributes = [IO.FileAttributes]::Directory } }
        Mock Join-Path { [IO.Path]::Combine($Path, $ChildPath) }
        Mock Get-ItemProperty { [pscustomobject]@{ BootExecute = $global:NvmeTest_boot } }
        Mock New-Item {}
        Mock New-ItemProperty {}
        Mock Get-Volume { [pscustomobject]@{ DriveLetter = 'C' }; [pscustomobject]@{ DriveLetter = 'D' } }
        Mock Get-PSDrive { [pscustomobject]@{ Name = 'C' } }
        Mock Set-Content {}
        Mock Remove-Item {}
        Mock Start-Sleep {}
        Mock Start-Process {
            $global:NvmeTest_nativeRan = $true
            [pscustomobject]@{ ExitCode = $global:NvmeTest_exitCode }
        }
        Mock diskpart.exe { $global:LASTEXITCODE = 0; 'Reassigned' }
    }

    It 'U1 writes typed settings, preserves boot entries and provisions a free letter' {
        & $setScript
        Should -Invoke diskpart.exe -Times 0
        Should -Invoke New-ItemProperty -Times 1 -ParameterFilter {
            $Name -eq 'BootExecute' -and $PropertyType -eq 'MultiString' -and
            ($Value -join '|') -eq 'autocheck autochk /q /v *|other-native|autoconfig'
        }
        Should -Invoke New-ItemProperty -Times 1 -ParameterFilter {
            $Name -eq 'PhysicalDiskModel' -and $PropertyType -eq 'MultiString' -and
            $Value -is [string[]] -and $Value[0] -eq 'Microsoft NVMe Direct Disk v2'
        }
        Should -Invoke New-ItemProperty -Times 1 -ParameterFilter {
            $Name -eq 'VolumePaths' -and $PropertyType -eq 'MultiString' -and
            $Value -is [string[]] -and ($Value -join '|') -eq '\tempdb|\tempdb\data|\tempdb\log'
        }
        foreach ($expectedName in @('VolumeLabel', 'VolumeDriveLetter')) {
            Should -Invoke New-ItemProperty -Times 1 -ParameterFilter { $Name -eq $expectedName -and $PropertyType -eq 'String' }
        }
        foreach ($expectedName in @('VolumeClusterSize', 'VirtualDiskStripeSize')) {
            Should -Invoke New-ItemProperty -Times 1 -ParameterFilter { $Name -eq $expectedName -and $PropertyType -eq 'DWord' -and $Value -eq 65536 }
        }
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $Wait -and $PassThru -and $FilePath -like '*\autoconfigw.exe' }
        Should -Invoke New-Item -Times 0 -ParameterFilter { $ItemType -eq 'Directory' }
    }

    It 'U2 moves only a DVD to the highest available letter' {
        $global:NvmeTest_occupied = [pscustomobject]@{ DriveType = 5; Label = $null }
        Mock Get-CimInstance {
            $global:NvmeTest_cimCalls++
            if ($global:NvmeTest_cimCalls -eq 1) { return $global:NvmeTest_occupied }
            if ($global:NvmeTest_cimCalls -gt 2) {
                [pscustomobject]@{ DriveType = 3; Label = 'SQLTemp'; FileSystem = 'NTFS'; BlockSize = 65536 }
            }
        }
        Mock Get-Volume { @('C', 'D', 'Z') | ForEach-Object { [pscustomobject]@{ DriveLetter = $_ } } }
        & $setScript
        Should -Invoke Set-Content -Times 1 -ParameterFilter { ($Value -join '|') -eq 'select volume D|assign letter=Y' }
        Should -Invoke diskpart.exe -Times 1
        Should -Invoke Remove-Item -Times 1
    }

    It 'U2 fails before changes when no optical destination is free' {
        $global:NvmeTest_occupied = [pscustomobject]@{ DriveType = 5; Label = $null }
        Mock Get-Volume { 68..90 | ForEach-Object { [pscustomobject]@{ DriveLetter = [char]$_ } } }
        { & $setScript } | Should -Throw '*No free letter*'
        Should -Invoke New-ItemProperty -Times 0
        Should -Invoke diskpart.exe -Times 0
    }

    It 'surfaces diskpart failure and removes its temporary script without writing registry settings' {
        $global:NvmeTest_occupied = [pscustomobject]@{ DriveType = 5; Label = $null }
        Mock diskpart.exe { $global:LASTEXITCODE = 1; 'Access denied' }
        { & $setScript } | Should -Throw '*DVD reassignment failed*Access denied*'
        Should -Invoke Remove-Item -Times 1 -ParameterFilter { $LiteralPath -like '*nvme-optical-*.txt' -and $Force }
        Should -Invoke New-ItemProperty -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It 'refuses a reported successful DVD move that leaves the target letter occupied' {
        Mock Get-CimInstance { [pscustomobject]@{ DriveType = 5; Label = $null } }
        { & $setScript } | Should -Throw '*DVD reassignment did not free D:*'
        Should -Invoke Remove-Item -Times 1 -ParameterFilter { $LiteralPath -like '*nvme-optical-*.txt' }
        Should -Invoke New-ItemProperty -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It 'rejects a wrong BootExecute type before changing settings or moving a DVD' {
        $global:NvmeTest_boot = 'autocheck autochk *'
        { & $setScript } | Should -Throw '*BootExecute is not REG_MULTI_SZ*'
        Should -Invoke New-ItemProperty -Times 0
        Should -Invoke diskpart.exe -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It 'supplies the standard boot check when BootExecute is absent' {
        Mock Get-ItemProperty { [pscustomobject]@{} }
        & $setScript
        Should -Invoke New-ItemProperty -Times 1 -ParameterFilter {
            $Name -eq 'BootExecute' -and ($Value -join '|') -eq 'autocheck autochk *|autoconfig'
        }
    }

    It 'U3 refreshes our existing volume and launches autoconfigw for native folder handling' {
        $global:NvmeTest_occupied = [pscustomobject]@{ DriveType = 3; Label = 'SQLTemp'; FileSystem = 'NTFS'; BlockSize = 65536 }
        $global:NvmeTest_disk.PartitionStyle = 'GPT'
        & $setScript
        Should -Invoke Start-Process -Times 1
        Should -Invoke New-ItemProperty -Times 7
        Should -Invoke New-Item -Times 0 -ParameterFilter { $ItemType -eq 'Directory' }
    }

    It 'converts matching-drive full paths, deduplicating parents case-insensitively' {
        & $setScript -DriveLetter d -VolumePathsJson '["d:\\tempdb\\data","tempdb\\log","D:\\TEMPDB","D:\\TEMPDB\\DATA","archive\\nested\\logs"]'
        Should -Invoke New-ItemProperty -Times 1 -ParameterFilter {
            $Name -eq 'VolumePaths' -and $PropertyType -eq 'MultiString' -and
            ($Value -join '|') -ceq '\tempdb|\tempdb\data|\tempdb\log|\archive|\archive\nested|\archive\nested\logs'
        }
        Should -Invoke Get-Item -Times 1 -ParameterFilter { $LiteralPath -eq 'D:\archive\nested\logs' }
    }

    It 'accepts full paths on a non-default configured drive' {
        & $setScript -DriveLetter T -VolumePathsJson '["t:\\work\\data"]'
        Should -Invoke New-ItemProperty -Times 1 -ParameterFilter {
            $Name -eq 'VolumePaths' -and ($Value -join '|') -eq '\work|\work\data'
        }
        Should -Invoke Get-Item -Times 1 -ParameterFilter { $LiteralPath -eq 'T:\work\data' }
    }

    It 'refreshes changed folder settings on repeated runs without deleting data or duplicating BootExecute' {
        $global:NvmeTest_occupied = [pscustomobject]@{ DriveType = 3; Label = 'SQLTemp'; FileSystem = 'NTFS'; BlockSize = 65536 }
        $global:NvmeTest_disk.PartitionStyle = 'GPT'
        Mock New-ItemProperty {
            if ($Name -eq 'BootExecute') { $global:NvmeTest_boot = [string[]]$Value }
        }
        & $setScript
        $global:NvmeTest_nativeRan = $false
        Mock Test-Path { $global:NvmeTest_nativeRan } -ParameterFilter { $LiteralPath -eq 'D:\tempdb\new' }
        & $setScript -VolumePathsJson '["D:\\tempdb\\new"]'
        Should -Invoke New-ItemProperty -Times 1 -ParameterFilter {
            $Name -eq 'VolumePaths' -and ($Value -join '|') -eq '\tempdb|\tempdb\new' -and $Force
        }
        Should -Invoke New-Item -Times 0 -ParameterFilter { $ItemType -eq 'Directory' }
        @($global:NvmeTest_boot | Where-Object { $_ -eq 'autoconfig' }).Count | Should -Be 1
        Should -Invoke Start-Process -Times 2
        Should -Invoke Remove-Item -Times 0
        Should -Invoke diskpart.exe -Times 0
    }

    It 'U4 refuses a foreign volume before any changes' {
        $global:NvmeTest_occupied = [pscustomobject]@{ DriveType = 3; Label = 'Data' }
        { & $setScript } | Should -Throw '*another volume*'
        Should -Invoke New-Item -Times 0
        Should -Invoke New-ItemProperty -Times 0
        Should -Invoke diskpart.exe -Times 0
    }

    It 'U5 refuses missing binaries without changes' {
        Mock Test-Path { $false }
        { & $setScript } | Should -Throw '*binary missing*'
        Should -Invoke New-ItemProperty -Times 0
        Should -Invoke diskpart.exe -Times 0
    }

    It 'U6 refuses no matching disk without changes' {
        Mock Get-Disk {}
        { & $setScript } | Should -Throw '*No disk matches*'
        Should -Invoke New-ItemProperty -Times 0
        Should -Invoke diskpart.exe -Times 0
    }

    It 'U7 preserves the order of existing boot entries without duplicates' {
        $global:NvmeTest_boot = [string[]]@('first', 'autoconfig', 'last')
        & $setScript
        Should -Invoke New-ItemProperty -Times 1 -ParameterFilter {
            $Name -eq 'BootExecute' -and ($Value -join '|') -eq 'first|autoconfig|last'
        }
    }

    It 'U7 supplies autocheck first when BootExecute is empty' {
        $global:NvmeTest_boot = [string[]]@()
        & $setScript
        Should -Invoke New-ItemProperty -Times 1 -ParameterFilter {
            $Name -eq 'BootExecute' -and ($Value -join '|') -eq 'autocheck autochk *|autoconfig'
        }
    }

    It 'U8 throws on nonzero native exit code' {
        $global:NvmeTest_exitCode = 19
        { & $setScript } | Should -Throw '*exit code 19*'
    }

    It 'U8 reports disk state if native success creates no volume' {
        $global:NvmeTest_noVolume = $true
        { & $setScript } | Should -Throw '*Disk state:*'
        Should -Invoke Start-Sleep -Times 12
    }

    It 'rejects unsafe disk state before any changes: <Property>=<Value>' -ForEach @(
        @{ Property = 'PartitionStyle'; Value = 'GPT' }
        @{ Property = 'IsOffline'; Value = $true }
        @{ Property = 'IsReadOnly'; Value = $true }
        @{ Property = 'IsBoot'; Value = $true }
        @{ Property = 'IsSystem'; Value = $true }
        @{ Property = 'BusType'; Value = 'SCSI' }
    ) {
        $global:NvmeTest_disk.$Property = $Value
        { & $setScript } | Should -Throw
        Should -Invoke New-ItemProperty -Times 0
        Should -Invoke diskpart.exe -Times 0
    }

    It 'rejects invalid input without querying or modifying storage: <Name>=<Value>' -ForEach @(
        @{ Name = 'DriveLetter'; Value = 'A' }
        @{ Name = 'DriveLetter'; Value = 'B' }
        @{ Name = 'DriveLetter'; Value = 'C' }
        @{ Name = 'DriveLetter'; Value = 'DD' }
        @{ Name = 'VolumeLabel'; Value = "SQL'Temp" }
        @{ Name = 'VolumeLabel'; Value = 'SQL"Temp' }
        @{ Name = 'VolumeLabel'; Value = ('x' * 33) }
        @{ Name = 'VolumePathsJson'; Value = '["foo''bar"]' }
        @{ Name = 'VolumePathsJson'; Value = '["foo\"bar"]' }
        @{ Name = 'VolumePathsJson'; Value = '["..\\data"]' }
        @{ Name = 'VolumePathsJson'; Value = '["C:\\data"]' }
        @{ Name = 'VolumePathsJson'; Value = '["T:\\data"]' }
        @{ Name = 'VolumePathsJson'; Value = '["D:data"]' }
        @{ Name = 'VolumePathsJson'; Value = '["D:\\"]' }
        @{ Name = 'VolumePathsJson'; Value = '["D:\\data\\"]' }
        @{ Name = 'VolumePathsJson'; Value = '["D:\\data\\\\logs"]' }
        @{ Name = 'VolumePathsJson'; Value = '["D:\\..\\data"]' }
        @{ Name = 'VolumePathsJson'; Value = '["D:\\data\\NUL.txt"]' }
        @{ Name = 'VolumePathsJson'; Value = '["\\\\server\\share"]' }
        @{ Name = 'VolumePathsJson'; Value = '["\\\\?\\D:\\data"]' }
        @{ Name = 'VolumePathsJson'; Value = '["\\data"]' }
        @{ Name = 'VolumePathsJson'; Value = '["data/absolute"]' }
        @{ Name = 'VolumePathsJson'; Value = '[null]' }
        @{ Name = 'VolumePathsJson'; Value = '["CON"]' }
        @{ Name = 'VolumePathsJson'; Value = '["data.\\logs"]' }
        @{ Name = 'VolumePathsJson'; Value = '"data"' }
        @{ Name = 'DiskModelsJson'; Value = '[]' }
        @{ Name = 'DiskModelsJson'; Value = '[1]' }
        @{ Name = 'VolumeClusterSize'; Value = 512 }
        @{ Name = 'VirtualDiskStripeSize'; Value = 12288 }
    ) {
        $parameters = @{ $Name = $Value }
        { & $setScript @parameters } | Should -Throw
        Should -Invoke Get-Disk -Times 0
        Should -Invoke New-ItemProperty -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It 'accepts lowercase drive letters and an empty folder array' {
        & $setScript -DriveLetter d -VolumePathsJson '[]'
        Should -Invoke New-ItemProperty -Times 1 -ParameterFilter {
            $Name -eq 'VolumePaths' -and $Value.Count -eq 0 -and $PropertyType -eq 'MultiString'
        }
        Should -Invoke Start-Process -Times 1
        Should -Invoke Get-Item -Times 0
    }

    It 'honors WhatIf without modifying registry or launching executables' {
        & $setScript -WhatIf
        Should -Invoke New-ItemProperty -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It 'fails visibly on mismatching cluster size before checking folders' {
        Mock Get-CimInstance {
            $global:NvmeTest_cimCalls++
            if ($global:NvmeTest_cimCalls -gt 1) {
                [pscustomobject]@{ DriveType = 3; Label = 'SQLTemp'; FileSystem = 'NTFS'; BlockSize = 4096 }
            }
        }
        { & $setScript } | Should -Throw '*cluster size differs*'
        Should -Invoke New-Item -Times 0 -ParameterFilter { $ItemType -eq 'Directory' }
    }

    It 'fails when native exit zero leaves a requested child missing' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'D:\tempdb\data' }
        { & $setScript } | Should -Throw '*Missing folder after autoconfigw*autoconfig.log*'
        Should -Invoke Start-Process -Times 1
        Should -Invoke New-Item -Times 0 -ParameterFilter { $ItemType -eq 'Directory' }
    }

    It 'lets native code repair missing folders on an existing labelled volume' {
        $global:NvmeTest_occupied = [pscustomobject]@{ DriveType = 3; Label = 'SQLTemp'; FileSystem = 'NTFS'; BlockSize = 65536 }
        $global:NvmeTest_disk.PartitionStyle = 'GPT'
        Mock Test-Path { $global:NvmeTest_nativeRan } -ParameterFilter { $LiteralPath -eq 'D:\tempdb\log' }
        & $setScript
        Should -Invoke Start-Process -Times 1
        Should -Invoke New-Item -Times 0 -ParameterFilter { $ItemType -eq 'Directory' }
    }

    It 'refuses a reparse point in the requested folder path' {
        Mock Get-Item {
            [pscustomobject]@{ PSIsContainer = $true; Attributes = [IO.FileAttributes]::ReparsePoint }
        }
        { & $setScript } | Should -Throw '*reparse point*'
        Should -Invoke New-Item -Times 0 -ParameterFilter { $ItemType -eq 'Directory' }
    }

    It 'refuses a file in the requested folder path' {
        Mock Get-Item { [pscustomobject]@{ PSIsContainer = $false; Attributes = [IO.FileAttributes]::Normal } }
        { & $setScript } | Should -Throw '*file or reparse point*'
    }

    It 'fails when native exit zero leaves a parent missing instead of creating it in PowerShell' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'D:\tempdb' }
        { & $setScript } | Should -Throw '*Missing folder after autoconfigw: D:\tempdb.*'
        Should -Invoke New-Item -Times 0 -ParameterFilter { $ItemType -eq 'Directory' }
    }

    It 'rejects existing unsafe folders before invoking native code: <Kind>' -ForEach @(
        @{ Kind = 'file'; Container = $false; Attributes = [IO.FileAttributes]::Normal }
        @{ Kind = 'reparse point'; Container = $true; Attributes = [IO.FileAttributes]::ReparsePoint }
    ) {
        $global:NvmeTest_occupied = [pscustomobject]@{ DriveType = 3; Label = 'SQLTemp'; FileSystem = 'NTFS'; BlockSize = 65536 }
        $global:NvmeTest_disk.PartitionStyle = 'GPT'
        Mock Get-Item { [pscustomobject]@{ PSIsContainer = $Container; Attributes = $Attributes } } -ParameterFilter { $LiteralPath -eq 'D:\tempdb' }
        { & $setScript } | Should -Throw '*file or reparse point*'
        Should -Invoke Start-Process -Times 0
        Should -Invoke New-ItemProperty -Times 0
    }

    It 'refuses a mismatching existing allocation unit before native execution or settings changes' {
        $global:NvmeTest_occupied = [pscustomobject]@{ DriveType = 3; Label = 'SQLTemp'; FileSystem = 'NTFS'; BlockSize = 4096 }
        { & $setScript } | Should -Throw '*cluster size differs*'
        Should -Invoke Start-Process -Times 0
        Should -Invoke New-ItemProperty -Times 0
    }

    It 'refuses unexpected disk provisioning on an existing volume: <Property>=<Value>' -ForEach @(
        @{ Property = 'PartitionStyle'; Value = 'RAW' }
        @{ Property = 'IsOffline'; Value = $true }
        @{ Property = 'IsReadOnly'; Value = $true }
    ) {
        $global:NvmeTest_occupied = [pscustomobject]@{ DriveType = 3; Label = 'SQLTemp'; FileSystem = 'NTFS'; BlockSize = 65536 }
        $global:NvmeTest_disk.PartitionStyle = 'GPT'
        $global:NvmeTest_disk.$Property = $Value
        { & $setScript } | Should -Throw '*must be initialized, online and writable*'
        Should -Invoke Start-Process -Times 0
        Should -Invoke New-ItemProperty -Times 0
    }

    It 'fails an existing-volume refresh if native execution leaves folders missing' {
        $global:NvmeTest_occupied = [pscustomobject]@{ DriveType = 3; Label = 'SQLTemp'; FileSystem = 'NTFS'; BlockSize = 65536 }
        $global:NvmeTest_disk.PartitionStyle = 'GPT'
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'D:\tempdb\log' }
        { & $setScript } | Should -Throw '*Missing folder after autoconfigw*'
        Should -Invoke Start-Process -Times 1
        Should -Invoke New-Item -Times 0 -ParameterFilter { $ItemType -eq 'Directory' }
    }
}

Describe 'Native path health checks' {
    BeforeEach {
        $global:NvmeTest_badRegistryType = $null
        $global:NvmeTest_config = [pscustomobject]@{
            PhysicalDiskModel = [string[]]@('Microsoft NVMe Direct Disk v2')
            VolumeDriveLetter = 'D'; VolumeLabel = 'SQLTemp'
            VolumePaths = [string[]]@('\tempdb', '\tempdb\data', '\tempdb\log')
            VolumeClusterSize = 65536; VirtualDiskStripeSize = 65536
        }
        Mock Test-Path { $true }
        Mock Get-ItemProperty {
            if ($LiteralPath -like '*Session Manager') {
                [pscustomobject]@{ BootExecute = [string[]]@('autocheck autochk *', 'autoconfig') }
            } else { $global:NvmeTest_config }
        }
        Mock Get-Item {
            $key = [pscustomobject]@{}
            $key | Add-Member ScriptMethod GetValueKind {
                param($name)
                if ($name -eq $global:NvmeTest_badRegistryType) { return 'String' }
                switch ($name) {
                    { $_ -in 'PhysicalDiskModel', 'VolumePaths' } { 'MultiString' }
                    { $_ -in 'VolumeClusterSize', 'VirtualDiskStripeSize' } { 'DWord' }
                    default { 'String' }
                }
            }
            $key | Add-Member ScriptMethod Close {}
            $key
        }
        Mock Get-Disk { [pscustomobject]@{ FriendlyName = 'Microsoft NVMe Direct Disk v2' } }
        Mock Get-PhysicalDisk {
            [pscustomobject]@{
                FriendlyName = 'Microsoft NVMe Direct Disk v2'; CanPool = $false
                CannotPoolReason = 'In a Pool'; OperationalStatus = 'OK'
            }
        }
        Mock Get-CimInstance {
            if ($ClassName -eq 'Win32_Volume') {
                [pscustomobject]@{ DriveType = 3; Label = 'SQLTemp'; FileSystem = 'NTFS'; BlockSize = 65536 }
            }
        }
    }

    It 'checks canonical native entries without adding another backslash' {
        $output = & $testScript
        $output[-1] | Should -BeLike 'OK:*'
        Should -Invoke Test-Path -Times 1 -ParameterFilter { $LiteralPath -eq 'D:\tempdb\data' -and $PathType -eq 'Container' }
        Should -Invoke Test-Path -Times 0 -ParameterFilter { $LiteralPath -like 'D:\\*' }
    }

    It 'accepts volume-only configuration without requiring folders' {
        $global:NvmeTest_config.VolumePaths = [string[]]@()
        $output = & $testScript
        $output[-1] | Should -BeLike 'OK:*'
        Should -Invoke Test-Path -Times 0 -ParameterFilter { $PathType -eq 'Container' }
    }

    It 'reports legacy relative registry entries as invalid even if folders exist' {
        $global:NvmeTest_config.VolumePaths = [string[]]@('tempdb\data')
        { & $testScript } | Should -Throw '*Invalid native VolumePaths*'
    }

    It 'reports missing or out-of-order parents' {
        $global:NvmeTest_config.VolumePaths = [string[]]@('\tempdb\data', '\tempdb')
        { & $testScript } | Should -Throw '*parent must precede child*'
    }

    It 'accepts case-insensitive parent references and reports missing folders' {
        $global:NvmeTest_config.VolumePaths = [string[]]@('\tempdb', '\TEMPDB\data')
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'D:\TEMPDB\data' }
        { & $testScript } | Should -Throw '*Missing folder D:\TEMPDB\data*'
    }

    It 'reports a missing installed binary' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*\System32\autoconfig.exe' }
        { & $testScript } | Should -Throw '*Missing autoconfig.exe*'
    }

    It 'reports an invalid boot configuration: <State>' -ForEach @(
        @{ State = 'missing'; Session = [pscustomobject]@{} }
        @{ State = 'wrong type'; Session = [pscustomobject]@{ BootExecute = 'autoconfig' } }
        @{ State = 'no native entry'; Session = [pscustomobject]@{ BootExecute = [string[]]@('autocheck autochk *') } }
    ) {
        Mock Get-ItemProperty { $Session } -ParameterFilter { $LiteralPath -like '*Session Manager' }
        { & $testScript } | Should -Throw '*BootExecute lacks a valid autoconfig entry*'
    }

    It 'reports an absent AutoConfig key rather than claiming healthy storage' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\AutoConfig' }
        { & $testScript } | Should -Throw '*AutoConfig registry key is absent*'
    }

    It 'reports wrong registry value types' {
        $global:NvmeTest_badRegistryType = 'VolumePaths'
        { & $testScript } | Should -Throw '*Wrong registry type: VolumePaths*'
    }

    It 'reports no matching disks' {
        Mock Get-Disk {}
        { & $testScript } | Should -Throw '*No matching temp disks*'
    }

    It 'reports an incompatible or absent volume: <State>' -ForEach @(
        @{ State = 'missing'; Volume = $null }
        @{ State = 'wrong label'; Volume = [pscustomobject]@{ DriveType = 3; Label = 'Data'; FileSystem = 'NTFS'; BlockSize = 65536 } }
        @{ State = 'wrong filesystem'; Volume = [pscustomobject]@{ DriveType = 3; Label = 'SQLTemp'; FileSystem = 'ReFS'; BlockSize = 65536 } }
        @{ State = 'wrong allocation unit'; Volume = [pscustomobject]@{ DriveType = 3; Label = 'SQLTemp'; FileSystem = 'NTFS'; BlockSize = 4096 } }
        @{ State = 'optical'; Volume = [pscustomobject]@{ DriveType = 5; Label = 'SQLTemp'; FileSystem = $null; BlockSize = $null } }
    ) {
        Mock Get-CimInstance { $Volume } -ParameterFilter { $ClassName -eq 'Win32_Volume' }
        { & $testScript } | Should -Throw '*Volume missing or label/filesystem/cluster size mismatch*'
    }

    It 'aggregates independent health failures instead of returning OK' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*\System32\autoconfig.exe' }
        Mock Get-Disk {}
        { & $testScript } | Should -Throw '*Missing autoconfig.exe*No matching temp disks*'
    }

    It 'surfaces storage query failures' {
        Mock Get-Disk { throw 'Storage query denied' }
        { & $testScript } | Should -Throw '*NOT OK:*Storage query denied*'
    }
}

Describe 'Revert (U9)' {
    BeforeEach {
        $global:NvmeTest_boot = [string[]]@('first', 'autoconfig', 'middle', 'AUTOCONFIG', 'last')
        $global:NvmeTest_keyExists = $true
        Mock Get-ItemProperty { [pscustomobject]@{ BootExecute = $global:NvmeTest_boot } }
        Mock New-ItemProperty { $global:NvmeTest_boot = [string[]]$Value }
        Mock Test-Path { $global:NvmeTest_keyExists }
        Mock Remove-Item { $global:NvmeTest_keyExists = $false }
    }
    It 'removes only autoconfig, preserves all other entries and is repeatable' {
        & $removeScript
        & $removeScript
        $global:NvmeTest_boot -join '|' | Should -Be 'first|middle|last'
        Should -Invoke Remove-Item -Times 1 -ParameterFilter { $LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\AutoConfig' }
    }
    It 'honors WhatIf' {
        & $removeScript -WhatIf
        Should -Invoke New-ItemProperty -Times 0
        Should -Invoke Remove-Item -Times 0
    }
    It 'rejects an invalid BootExecute registry type before deleting configuration' {
        $global:NvmeTest_boot = 'autoconfig'
        { & $removeScript } | Should -Throw '*BootExecute is not REG_MULTI_SZ*'
        Should -Invoke New-ItemProperty -Times 0
        Should -Invoke Remove-Item -Times 0
    }
    It 'removes configuration even when BootExecute is absent' {
        Mock Get-ItemProperty { [pscustomobject]@{} }
        & $removeScript
        Should -Invoke New-ItemProperty -Times 0
        Should -Invoke Remove-Item -Times 1 -ParameterFilter { $LiteralPath -like '*\AutoConfig' }
    }
}

Describe 'Lab reset safety' {
    BeforeEach {
        $global:NvmeTest_disk = [pscustomobject]@{
            Number = 1; FriendlyName = 'Microsoft NVMe Direct Disk v2'; BusType = 'NVMe'
            PartitionStyle = 'GPT'; IsBoot = $false; IsSystem = $false
            IsOffline = $true; IsReadOnly = $true
        }
        Mock Get-Disk { $global:NvmeTest_disk }
        Mock Set-Disk {}
        Mock Clear-Disk {
            $global:NvmeTest_disk.PartitionStyle = 'RAW'
            $global:NvmeTest_disk.IsOffline = $false
            $global:NvmeTest_disk.IsReadOnly = $false
        }
        Mock Update-HostStorageCache {}
    }

    It 'requires Force before even inspecting a disk' {
        { & $resetScript -DiskNumber 1 } | Should -Throw '*-Force is required*'
        Should -Invoke Get-Disk -Times 0
    }

    It 'refuses an unsafe lab reset candidate: <Property>=<Value>' -ForEach @(
        @{ Property = 'FriendlyName'; Value = 'Persistent data disk' }
        @{ Property = 'BusType'; Value = 'SCSI' }
        @{ Property = 'IsBoot'; Value = $true }
        @{ Property = 'IsSystem'; Value = $true }
    ) {
        $global:NvmeTest_disk.$Property = $Value
        { & $resetScript -DiskNumber 1 -Force -Confirm:$false } | Should -Throw '*Refusing*'
        Should -Invoke Set-Disk -Times 0
        Should -Invoke Clear-Disk -Times 0
    }

    It 'resets only the explicitly selected verified temp disk and checks RAW state' {
        $result = & $resetScript -DiskNumber 1 -Force -Confirm:$false
        $result.PartitionStyle | Should -Be 'RAW'
        Should -Invoke Set-Disk -Times 1 -ParameterFilter { $Number -eq 1 -and $IsOffline -eq $false }
        Should -Invoke Set-Disk -Times 1 -ParameterFilter { $Number -eq 1 -and $IsReadOnly -eq $false }
        Should -Invoke Clear-Disk -Times 1 -ParameterFilter { $Number -eq 1 -and $RemoveData -and $RemoveOEM }
        Should -Invoke Update-HostStorageCache -Times 1
    }

    It 'surfaces disk clearing failures instead of reporting RAW success' {
        Mock Clear-Disk { throw 'Clear failed' }
        { & $resetScript -DiskNumber 1 -Force -Confirm:$false } | Should -Throw '*Clear failed*'
        Should -Invoke Update-HostStorageCache -Times 0
    }
    It 'honors WhatIf without bringing a disk online or clearing it' {
        & $resetScript -DiskNumber 1 -Force -WhatIf
        Should -Invoke Get-Disk -Times 1
        Should -Invoke Set-Disk -Times 0
        Should -Invoke Clear-Disk -Times 0
    }
    It 'fails if clearing does not achieve the required disk state: <Property>=<Value>' -ForEach @(
        @{ Property = 'PartitionStyle'; Value = 'GPT' }
        @{ Property = 'IsOffline'; Value = $true }
        @{ Property = 'IsReadOnly'; Value = $true }
    ) {
        Mock Update-HostStorageCache { $global:NvmeTest_disk.$Property = $Value }
        { & $resetScript -DiskNumber 1 -Force -Confirm:$false } | Should -Throw '*Reset did not produce a RAW, online, writable disk*'
    }
}
