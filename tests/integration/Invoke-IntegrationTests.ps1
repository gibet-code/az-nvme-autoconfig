#requires -Version 5.1
<#
.SYNOPSIS
Plans a disposable Azure lab. Makes NO Azure calls unless -Execute is supplied.
.DESCRIPTION
Execute only after reviewing the printed commands and obtaining approval.
Automates I1-I4 (I4 marker/health only, not service ordering), I9 and I13.
All resources are in a unique tagged resource group, deleted in finally.
SQL installation/I7 and boot timing evidence remain manual test-plan steps.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidatePattern('^[a-z0-9]+$')]
    [string] $Location = 'eastus2',
    [switch] $Execute,
    [System.Management.Automation.PSCredential] $Credential,
    [string] $ResultsDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
if ([string]::IsNullOrWhiteSpace($ResultsDirectory)) { $ResultsDirectory = Join-Path $PSScriptRoot 'results' }
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
$group = "nvme-lab-$runId"
Write-Output @"
PLAN ONLY unless -Execute is supplied AFTER approval.
Region: $Location
Sizes: Standard_D2ds_v6 (1 x 110 GiB temp NVMe), Standard_D2s_v6 (negative control).
Image: MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:<resolved version>
Resources: 1 tagged RG ($group), 2 VMs, 2 managed OS disks, 2 NICs,
1 VNet/subnet, 1 NSG denying inbound, 1 NAT gateway + 1 outbound public IP,
LocalStoragePrepExtension on both VMs and nvmeAutoConfigRunCommand on the NVMe VM.
No inbound public IPs, SQL installation, persistent data disks or credentials in files.
Commands (credential supplied in memory, never printed):
az account show --query id -o tsv (must match Get-AzContext)
az vm list-skus --location $Location --resource-type virtualMachines
az vm image show --location $Location --urn MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest
az vm extension image list --publisher Microsoft.Azure.HostStorage --location $Location
az group create --name $group --location $Location --tags purpose=nvme-autoconfig-test run=$runId
New-AzResourceGroupDeployment -ResourceGroupName $group -TemplateFile tests\integration\lab.bicep -adminPassword <secure>
az deployment group create -g $group -f nvme-autoconfig.bicep -p vmName=nvme-lab-0
az vm run-command invoke -g $group -n nvme-lab-0 --command-id RunPowerShellScript --scripts @scripts\Test-NvmeAutoConfig.ps1
az deployment group create -g $group -f nvme-autoconfig.bicep -p vmName=nvme-lab-0
az vm run-command invoke -g $group -n nvme-lab-0 --command-id RunPowerShellScript --scripts Restart-Computer
az vm deallocate -g $group -n nvme-lab-0
az vm start -g $group -n nvme-lab-0
az vm extension set -g $group --vm-name nvme-lab-1 --publisher Microsoft.Azure.HostStorage --name LocalStoragePrepExtension --version 0.1
az vm run-command invoke (I9 read-only no-disk preflight; I13 revert, then deallocate/start)
az group delete --name $group --yes
"@
if (-not $Execute) { return }
if (-not $Credential) { throw 'Supply a temporary lab -Credential. No password is written to disk or printed.' }
Import-Module Az.Resources -ErrorAction Stop
if (-not $PSCmdlet.ShouldProcess("$group in $Location", 'CREATE, restart, deallocate and DELETE disposable lab resources')) { return }

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..1] -join ' ')" }
    if ($result) { $result | ConvertFrom-Json }
}
function Invoke-Guest {
    param([string] $Name = 'nvme-lab-0', [Parameter(Mandatory)][string] $Script)
    $result = Invoke-AzCli -Arguments @('vm', 'run-command', 'invoke', '-g', $group, '-n', $Name,
        '--command-id', 'RunPowerShellScript', '--scripts', $Script)
    $messages = @($result.value | ForEach-Object { $_.message }) -join "`n"
    if ($messages -notmatch 'GUEST_EXIT=0') { throw "Guest command failed or did not finish: $messages" }
    $messages
}
function Get-GuestWrapper {
    param([string] $Script)
    "try { `$ErrorActionPreference = 'Stop'; & { $Script }; Write-Output 'GUEST_EXIT=0' } catch { Write-Output 'GUEST_EXIT=1'; throw }"
}
function Test-LabHealth {
    $healthScript = [IO.File]::ReadAllText((Join-Path $root 'scripts\Test-NvmeAutoConfig.ps1'))
    $health = Invoke-Guest -Script (Get-GuestWrapper -Script $healthScript)
    if ($health -notmatch '(?m)^OK:') { throw "Health check did not report OK: $health" }
    $health
}

$created = $false
$imageVersion = 'not-resolved'
$cleanupError = $null
$null = New-Item -ItemType Directory -Path $ResultsDirectory -Force
$records = [System.Collections.Generic.List[object]]::new()
try {
    $account = Invoke-AzCli -Arguments @('account', 'show')
    $context = Get-AzContext
    if (-not $context -or $context.Subscription.Id -ne $account.id) {
        throw 'Azure CLI and Az PowerShell must use the same explicitly selected subscription.'
    }
    $image = Invoke-AzCli -Arguments @('vm', 'image', 'show', '-l', $Location,
        '--urn', 'MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest')
    $imageVersion = $image.name
    $null = Invoke-AzCli -Arguments @('group', 'create', '-n', $group, '-l', $Location,
        '--tags', 'purpose=nvme-autoconfig-test', "run=$runId")
    $created = $true
    $null = New-AzResourceGroupDeployment -ResourceGroupName $group -TemplateFile (Join-Path $PSScriptRoot 'lab.bicep') `
        -location $Location -adminUsername $Credential.UserName -adminPassword $Credential.Password -imageVersion $imageVersion
    foreach ($case in @('I1', 'I2')) {
        $null = Invoke-AzCli -Arguments @('deployment', 'group', 'create', '-g', $group,
            '-f', (Join-Path $root 'nvme-autoconfig.bicep'), '-p', 'vmName=nvme-lab-0')
        $health = Test-LabHealth
        $records.Add(@{ Case = $case; Status = 'PASS'; Evidence = $health })
    }
    # Schedule an in-guest restart after Run Command has returned its success marker.
    $null = Invoke-Guest -Script (Get-GuestWrapper -Script 'shutdown.exe /r /t 15; if ($LASTEXITCODE -ne 0) { throw "shutdown failed" }')
    Start-Sleep -Seconds 90
    $records.Add(@{ Case = 'I3'; Status = 'PASS'; Evidence = (Test-LabHealth) })
    $null = Invoke-Guest -Script (Get-GuestWrapper -Script "Set-Content -LiteralPath 'D:\nvme-marker.txt' -Value '$runId'")
    $null = Invoke-AzCli -Arguments @('vm', 'deallocate', '-g', $group, '-n', 'nvme-lab-0')
    $null = Invoke-AzCli -Arguments @('vm', 'start', '-g', $group, '-n', 'nvme-lab-0')
    $health = Test-LabHealth
    $marker = Invoke-Guest -Script (Get-GuestWrapper -Script "if (Test-Path -LiteralPath 'D:\nvme-marker.txt') { throw 'Marker survived; disk wipe not proven' }")
    $records.Add(@{ Case = 'I4'; Status = 'PARTIAL'; Evidence = "$health`n$marker`nService ordering NOT tested." })

    $preflight = @'
$beforeBoot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').BootExecute -join '|'
$beforeKey = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\AutoConfig'
$message = $null
try { & { __SET_SCRIPT__ } } catch { $message = $_.Exception.Message }
if ($message -notlike '*No disk matches*') { throw "Unexpected rejection: $message" }
if ($beforeBoot -ne ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').BootExecute -join '|')) { throw 'BootExecute changed' }
if ($beforeKey -ne (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\AutoConfig')) { throw 'AutoConfig changed' }
'@
    $null = Invoke-AzCli -Arguments @('vm', 'extension', 'set', '-g', $group, '--vm-name', 'nvme-lab-1',
        '--publisher', 'Microsoft.Azure.HostStorage', '--name', 'LocalStoragePrepExtension', '--version', '0.1')
    $setScript = [IO.File]::ReadAllText((Join-Path $root 'scripts\Set-NvmeAutoConfig.ps1'))
    $negative = Invoke-Guest -Name 'nvme-lab-1' -Script (Get-GuestWrapper -Script $preflight.Replace('__SET_SCRIPT__', $setScript))
    $records.Add(@{ Case = 'I9'; Status = 'PASS'; Evidence = $negative })
    $removeScript = [IO.File]::ReadAllText((Join-Path $root 'scripts\Remove-NvmeAutoConfig.ps1'))
    $null = Invoke-Guest -Script (Get-GuestWrapper -Script $removeScript)
    $null = Invoke-AzCli -Arguments @('vm', 'deallocate', '-g', $group, '-n', 'nvme-lab-0')
    $null = Invoke-AzCli -Arguments @('vm', 'start', '-g', $group, '-n', 'nvme-lab-0')
    $revertCheck = @'
if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').BootExecute -contains 'autoconfig') { throw 'Boot entry remains' }
if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\AutoConfig') { throw 'Registry key remains' }
if (Get-Volume -DriveLetter D -ErrorAction SilentlyContinue) { throw 'D: still exists after revert/deallocate' }
$disks = @(Get-Disk | Where-Object FriendlyName -eq 'Microsoft NVMe Direct Disk v2')
if ($disks.Count -eq 0 -or @($disks | Where-Object PartitionStyle -ne 'RAW').Count -gt 0) { throw 'Expected RAW temp disk' }
'@
    $records.Add(@{ Case = 'I13'; Status = 'PASS'; Evidence = (Invoke-Guest -Script (Get-GuestWrapper -Script $revertCheck)) })
} catch {
    $records.Add(@{ Case = 'RUN'; Status = 'FAIL'; Evidence = $_.Exception.Message })
    throw
} finally {
    if ($created) {
        try {
            $null = Invoke-AzCli -Arguments @('group', 'delete', '-n', $group, '--yes')
            $records.Add(@{ Case = 'CLEANUP'; Status = 'PASS'; Evidence = 'Dedicated lab resource group deleted.' })
        } catch {
            $cleanupError = $_
            $records.Add(@{ Case = 'CLEANUP'; Status = 'FAIL'; Evidence = "Delete $group manually. $($_.Exception.Message)" })
            Write-Error "Cleanup failed. Delete ONLY resource group $group after checking its test tag." -ErrorAction Continue
        }
    }
    $report = @{
        Date = (Get-Date).ToUniversalTime().ToString('o'); Region = $Location
        Sizes = @('Standard_D2ds_v6', 'Standard_D2s_v6'); Image = $imageVersion
        Run = $runId; Results = $records.ToArray()
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ResultsDirectory "$runId.json") -Encoding UTF8
    if ($cleanupError) { throw $cleanupError }
}
