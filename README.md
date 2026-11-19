# Azure temp NVMe autoconfiguration

Configure native boot-time preparation of temporary NVMe storage on an
**existing Windows Azure VM**. The configuration provisions a volume and folders
for workloads that can tolerate losing their temporary data, such as caches,
scratch files or SQL Server tempdb.

**SQL Server is a use case, not a requirement.** Use the portal's Custom profile
or template parameters to choose the drive letter, volume label and folders for
your workload. This project does not install or configure applications.

> [!WARNING]
> **Disclaimer:** This is an independently driven project, not a Microsoft service or product. There are no implicit or explicit obligations related to this project; it is provided "as is", with no warranties, and confers no rights.
>
> **Undocumented components:** LocalStoragePrepExtension and the autoconfig binaries are undocumented and may change without notice. This changes Windows BootExecute. Test on a disposable VM first. Support for self-installed SQL Server is not confirmed.
>
> **SQL readiness:** This is not a verified end-to-end unattended SQL tempdb recovery solution. SQL permissions, startup ordering and readiness remain unverified. No SQL placement or permission changes are performed.

## Requirements

- A running Windows VM with temporary NVMe storage and a healthy Azure VM agent.
- Permission to read the VM and deploy nested deployments, VM extensions and
  managed Run Commands.
- Only ephemeral data on the target disk; never specify a persistent-disk model.
- Back up BootExecute and AutoConfig settings outside temporary storage.

## Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fgibet-code%2Faz-nvme-autoconfig%2Fmain%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fgibet-code%2Faz-nvme-autoconfig%2Fmain%2FcreateUiDefinition.json)

Select an existing running Windows VM and choose a storage preset:

| Preset | Drive | Label | Folders | NTFS allocation unit |
|---|---|---|---|---|
| SQL Server tempdb | D | SQLTemp | tempdb\data;tempdb\log | 64 KiB |
| General purpose | T | TempNVMe | temp\data;temp\log | 4 KiB |

Both presets use one form and the same native storage mechanism. Leave the optional
drive, label and folder overrides blank to follow the selected preset; placeholders
show its defaults. Entered overrides are preserved when switching presets. Review
the effective-settings summary after changing presets or editing values.
**Advanced** enables allocation-unit, stripe-size and
exact temporary-disk model overrides; unchecking it restores the preset's storage
settings without changing drive, label or folders. Allocation defaults to **Use
preset** until explicitly overridden. Stripe size defaults to 64 KiB
for both presets and is separate from the NTFS allocation unit.

The SQL allocation size is a preset, not a universal tempdb requirement;
[Microsoft's guidance](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/performance-guidelines-best-practices-storage)
distinguishes data disks from the existing temporary D: drive. Match the folders
to your SQL instance; deployment does not move tempdb, configure services or grant
permissions. Existing volumes are not reformatted to change allocation size.
The portal generates a retry tag automatically for each new deployment session.

Alternatively, use your selected Azure CLI subscription. The template reads the VM's
actual region automatically without modifying the VM resource itself:

```powershell
$rg = '<resource-group>'
$vm = '<vm-name>'
az deployment group create -g $rg -f .\nvme-autoconfig.bicep `
    -p vmName=$vm
```

| Parameter | Default | Notes |
|---|---|---|
| vmName | Required | Existing VM in the deployment resource group |
| driveLetter | D | Single letter D-Z |
| volumeLabel | SQLTemp | Label used to recognize an existing volume |
| volumePaths | tempdb\data, tempdb\log | Relative folders or full paths on driveLetter |
| diskModels | Microsoft NVMe Direct Disk v2 | Exact temporary-disk model names only |
| volumeClusterSize | 65536 | NTFS allocation unit in bytes |
| virtualDiskStripeSize | 65536 | Power of two, 4096-1048576; multi-disk behavior unverified |
| runTag | utcNow() | Use a fresh value when retrying saved parameters |

CLI defaults use SQL-oriented names; override the label and folders for other
workloads.

Paths are normalized and missing parent entries added automatically. For example,
`D:\work\data` and `work\log` become `\work`, `\work\data`,
`\work\log` in native configuration. Unsafe paths and mismatched drives are rejected.

## Behavior and repeat deployment

The template installs LocalStoragePrepExtension, writes typed AutoConfig settings,
preserves other BootExecute entries, and invokes native AutoConfig. Native code
creates folders; the script verifies the volume and every configured folder.
Only a DVD can be moved off the target drive letter.

- New provisioning requires all matching disks to be RAW, online and writable.
- An existing matching labelled volume is not reformatted. Settings are refreshed
  and missing folders created natively; removed paths are not deleted from disk.
- Changing the drive letter does **not** migrate an initialized volume.
- A label is not proof of ownership: inspect existing storage before deploying.
- Application configuration, service startup ordering and folder permissions are
  your responsibility.

## SQL Server use case

For SQL Server VMs using temporary NVMe storage, two existing approaches are:

1. Redeploy SQL Server on a new VM through the Azure portal; see
   [Microsoft's drive-readiness guidance](https://learn.microsoft.com/troubleshoot/sql/azure-sql/sql-deployment-fails-drive-not-ready).
2. Use [custom startup automation from Azure Samples](https://github.com/Azure-Samples/azuresandbox/tree/main/extras/scripts/vm-mssql-win/NVMe)
   to prepare storage and start SQL Server.

For this use case, this repository offers a **third option**: configure native
storage preparation on the existing VM. SQL file placement, service configuration
and permissions remain separate tasks; see the SQL readiness warning above.

## Verify and remove

```powershell
az vm run-command show -g $rg --vm-name $vm `
    --run-command-name nvmeAutoConfigRunCommand --instance-view
az vm run-command invoke -g $rg -n $vm --command-id RunPowerShellScript `
    --scripts '@scripts\Test-NvmeAutoConfig.ps1'
```

Inspect `C:\Windows\Logs\Autoconfig\autoconfig.log` on the VM when native
provisioning fails. The log is overwritten on every invocation; exit code 0
alone does not prove success.

Before removing boot provisioning, reconfigure workloads that depend on the
temporary drive (for example, move SQL tempdb elsewhere), or arrange another
recovery mechanism. Run elevated inside the guest:

```powershell
.\scripts\Remove-NvmeAutoConfig.ps1 -WhatIf
.\scripts\Remove-NvmeAutoConfig.ps1
```

This removes AutoConfig settings and only the autoconfig boot entry. It does not
delete data, restore a moved DVD letter or uninstall the extension. Deleting Azure
resources alone does not revert guest settings.

## Validation and development

- [Validated facts, native contract and limitations](docs/VALIDATION.md)
- [Test commands and integration scenarios](tests/README.md)
- [NVMe FAQ](https://learn.microsoft.com/azure/virtual-machines/enable-nvme-temp-faqs)
- [SQL drive-not-ready guidance](https://learn.microsoft.com/troubleshoot/sql/azure-sql/sql-deployment-fails-drive-not-ready)

The SQL guidance does not establish support for this approach. Microsoft binaries
are not redistributed. Licensed under [Apache-2.0](LICENSE).
