# Testing

Validated behavior and remaining gaps are recorded in [VALIDATION.md](../docs/VALIDATION.md).
Keep raw evidence outside Git: reports can contain machine paths and Azure IDs.

## Local checks

Use Windows PowerShell 5.1, Bicep 0.49.2, Pester 5.7.1 and PSScriptAnalyzer
1.24.0. Install dependencies through your organization's approved feeds.
The scripts do not install packages automatically.

```powershell
az bicep build --file .\nvme-autoconfig.bicep --outfile .\azuredeploy.json
powershell.exe -NoProfile -File .\tests\Invoke-StaticTests.ps1
powershell.exe -NoProfile -Command "Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester .\tests\NvmeAutoConfig.Tests.ps1 -Output Detailed -CI"
```

| Check | Coverage |
|---|---|
| S1-S2 | Bicep build/lint, exact generated ARM synchronization and automatic VM-region/module wiring |
| S3 | Actual PowerShell 5.1 parsing, embedded-source equality and analyzer |
| S4-S5 | Shared presets, optional folder modes, Advanced outputs/summary, warnings and input validation |
| U1-U8 | Typed settings, disk/volume/path guards, DVD relocation, native execution, postconditions and repeat configuration |
| U9 | Revert preserves other boot entries and is repeatable |
| Additional Pester cases | Native path health checks, RAW-reset guards and no PowerShell folder-creation fallback |

To measure command coverage, run in Windows PowerShell 5.1:

```powershell
Import-Module Pester -RequiredVersion 5.7.1
$config = New-PesterConfiguration
$config.Run.Path = '.\tests\NvmeAutoConfig.Tests.ps1'
$config.Run.PassThru = $true
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = @('.\scripts\*.ps1', '.\tests\integration\Reset-NvmeTempDisk.ps1')
$config.CodeCoverage.OutputPath = Join-Path $env:TEMP 'nvme-coverage.xml'
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0 -or $result.PassedCount -eq 0) { throw 'Pester tests failed' }
```

CI measures the same three guest scripts and lab-only disk-reset helper, keeping output in runner
temporary storage. Command coverage is not branch coverage or proof of native,
SQL or Azure integration behavior. Build/template/UI checks run separately.

## Azure lab harness

Azure tests do not run in CI. Never create, clear, restart, deallocate or delete
resources without approval of the subscription, region, inventory, destructive
steps and cleanup plan. Use disposable storage, never production SQL/data.

Print a plan without Azure calls:

```powershell
.\tests\integration\Invoke-IntegrationTests.ps1 -Location '<approved-region>'
```

The harness proposes two plain Windows Server 2022 VMs: Standard_D2ds_v6 and a
Standard_D2s_v6 no-NVMe negative control, plus OS disks/NICs, VNet/subnet, inbound-deny
NSG and NAT/outbound public IP. It has no inbound VM public IP. Availability and
quota must be checked in the selected region.

After approval, supply a temporary credential in memory:

```powershell
$credential = Get-Credential -Message 'Temporary lab administrator'
.\tests\integration\Invoke-IntegrationTests.ps1 -Location '<approved-region>' `
    -Credential $credential -Execute
```

Azure CLI and Az PowerShell subscription contexts must match. The harness writes
to the ignored integration results directory and attempts resource-group cleanup
in finally; independently confirm deletion. It automates initial/repeated
deployment (I1-I2), an ordinary restart (I3), partial marker-loss/deallocation
checks (I4), no-disk rejection (I9), and revert/recovery checks (I13).
The complete two-VM harness has not been validated end to end.

## Native recovery and redeployment regression

Use the following sequence for a separately approved fresh single-VM lab:

1. Verify a plain image, one empty non-system/non-boot temp NVMe and no SQL.
   Deploy Bicep with D:/SQLTemp/64-KiB and default folders. Verify deployed source,
   native log, registry types, BootExecute and health.
2. Write/hash a marker. Redeploy identical parameters with a fresh runTag.
   Verify managed-command reexecution and marker/partition-layout preservation.
3. Explicitly deallocate, confirm PowerState/deallocated, start and inspect
   without redeployment or on-demand AutoConfig. Record marker loss/retention,
   native log, folders and unchanged managed-command timestamps.
4. Redeploy with changed folder names on the same drive, including full and
   relative paths. Verify native entries/new folders and retention of old data.
5. Attempt a different drive letter while the current volume is initialized.
   Expect rejection and unchanged guest configuration, data and partition layout.
6. Only with explicit destructive approval, verify disk identity, volume ownership
   and absence of an active pagefile on the temp disk, then use
   [Reset-NvmeTempDisk.ps1](integration/Reset-NvmeTempDisk.ps1). Verify RAW, online,
   writable, no partitions and no old volume. Redeploy with the new drive/folders.
7. Test deallocation/start again. For deterministic reconstruction evidence,
   repeat the guarded RAW reset and deallocation/start without configuration
   execution in between. Verify both volume and folders and unchanged settings.
8. Recover logs/evidence before ownership-checked cleanup; confirm group absence.

Never treat marker retention as proof of reconstruction. Do not claim SQL service
readiness from storage health alone.

## Additional acceptance coverage

- **SQL:** On a disposable SQL instance, verify tempdb data/log placement, actual
  service-account ACLs after storage loss, startup timing and ERRORLOG errors 3/5.
- **Portal:** Use the [CreateUiDefinition sandbox](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/SandboxBlade)
  and a published template. Check visible disclaimers/confirmation, SQL/general
  preset defaults and switching after edits, preset/custom/no-folder modes,
  full/relative paths, numeric outputs
  and current VM region. Check Advanced overrides, unchecking Advanced to restore
  preset storage values, summary/output agreement and automatic retry tags. Reject
  Linux, stopped or cross-resource-group VMs and unsafe inputs.
- **Region discovery:** Deploy to an existing VM whose region differs from its
  resource group's region, using only vmName and configuration inputs. Verify
  both child resources use the VM's region through the embedded nested template.
  This template refactoring has not yet been validated in Azure.
- **Compatibility:** Other OS versions/architectures, multiple disks, non-RAW
  layouts, extension upgrades and actual installed portal SQL components require
  separate approval and evidence.
