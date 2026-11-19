# Validated facts and maintenance reference

This is the current evidence baseline, not a deployment log. Keep resource IDs,
account/customer names, local workstation paths, credentials and raw run output
out of the repository. New results should state what was tested and what remains
unproven, without retaining environment-specific identifiers.

## Evidence scope

Validated on plain Windows Server 2022 Datacenter Azure Edition, image
`20348.5773.261025`, using Standard_D2ds_v6 with one 110-GiB temporary NVMe disk.
No SQL Server or SQL IaaS extension was installed.

Both Microsoft executables were Authenticode Valid, version
`10.0.29553.1000 (WinBuild.160101.0800)`.

| Binary | Bytes | SHA-256 |
|---|---:|---|
| autoconfig.exe | 603528 | `81B32F4E45B0F85EF9A330ABDAEE2CFB83136F2E89C0100D5AC5580470C5FBC5` |
| autoconfigw.exe | 607624 | `85BD5B5E55DEF442B1826978818180FA5D815B32E9C2AEB20CCD88257A2AB8A4` |

Behavior is specific to the tested build, not a supported or stable public API.
Microsoft binaries, disassembly and raw cloud evidence are not redistributed.

## Native configuration contract

Registry key: `HKLM\SYSTEM\CurrentControlSet\Control\AutoConfig`.

| Name | Registry type | Example |
|---|---|---|
| PhysicalDiskModel | REG_MULTI_SZ | Microsoft NVMe Direct Disk v2 |
| VolumeDriveLetter | REG_SZ | D |
| VolumeLabel | REG_SZ | SQLTemp |
| VolumePaths | REG_MULTI_SZ | `\tempdb`, `\tempdb\data`, `\tempdb\log` |
| VolumeClusterSize | REG_DWORD | 65536 |
| VirtualDiskStripeSize | REG_DWORD | 65536 |

### Folder paths

- Native code constructs `\??\<letter>:<entry>` without inserting a separator.
  `tempdb\data` therefore produces the incorrect `\??\D:tempdb\data`.
- Every native entry must start with `\`. Missing ancestors must be listed
  before children: creation is not recursive.
- The public script accepts safe relative paths or full paths on the configured
  drive, then derives case-insensitive, deduplicated parent-first native entries.
  UNC/device paths, drive-relative/root paths and mismatched drives are rejected.
- Paths with a missing parent fail with `0xC000003A`
  (STATUS_OBJECT_PATH_NOT_FOUND). Initial relative-path failures were configuration
  errors, not evidence that native AutoConfig ignores VolumePaths.
- A wrong REG_SZ/REG_DWORD VolumePaths type prevented RAW provisioning in tests.
  Removing VolumePaths allowed provisioning; empty-array behavior on Azure remains
  unverified.

### Execution and diagnostics

- `autoconfig.exe` is a native boot image, invoked through BootExecute.
  Never launch it as a normal Windows process.
- `autoconfigw.exe` is the on-demand Win32 executable. It handles directories
  even when no uninitialized disk is selected.
- Native directory creation uses one NtCreateFile per entry, with FILE_OPEN_IF
  and FILE_DIRECTORY_FILE. Existing directories can be reopened idempotently.
- Errors and successes are written to
  `C:\Windows\Logs\Autoconfig\autoconfig.log`, not stdout/stderr.
  FILE_OVERWRITE_IF replaces the log on every invocation.
- Exit code 0 can accompany registry/provisioning/directory failure. Always verify
  storage and folder postconditions; never restore a folder-creation fallback
  that could mask native failure.

Static trace points for the tested x64 build (image-relative addresses):
Win32 directory routine `0x3c7c..0x3e0d`, boot-native directory routine
`0x3738..0x38c9`, Win32 log initialization `0x477c..0x4940`.
Revalidate these addresses and behavior if the binaries change.

## Verified behavior

| Scenario | Result |
|---|---|
| Initial Bicep provisioning | Native NTFS/SQLTemp/64-KiB volume and parent/data/log folders; DVD moved off D: |
| Identical redeployment with fresh runTag | Managed command reran; initialized disk skipped; marker hash and partition layout preserved |
| Same drive, changed folder parameters | New folders created natively; old folders/data retained |
| Change initialized D: to T: | Safely rejected before guest registry/BootExecute, marker or layout changes |
| T: provisioning after approved disposable-disk RAW reset | Successful with changed folder names |
| D: and T: deallocation/start | Markers disappeared; native boot code reconstructed volume and folders |
| Explicit RAW reset followed by T: deallocation/start | Volume and folders reconstructed from verified RAW storage |

Three explicit deallocation/start cycles confirmed PowerState/deallocated before
start. No guest restarts, Bicep redeployment, on-demand AutoConfig call or folder
repair occurred between reset/start and inspection. Managed-command start/end
timestamps and typed guest configuration remained unchanged across each cycle.
The OS disk's identity, size and partition style were unchanged.

Native code was the sole folder creator. Inspection and health checks did not
repair storage. RAW resets were limited to the verified temporary disk with no
active pagefile on it. Approved disposable resources were deleted and absence
confirmed after testing.

Changing a drive parameter is not migration. A failed managed command can retain
attempted Azure parameters while guest configuration remains unchanged. Do not
interpret a failed deployment as a successful drive change, or use a destructive
lab reset as a production migration procedure.

## Invariants for future changes

- Read the existing VM's region in the entry template and pass it into the
  configuration module. The VM's region can differ from its resource group's.
  Do not restore a user-supplied location parameter or redeploy the VM itself.
- Use collection functions such as `first(skip(...))` in portal expressions.
  The CreateUiDefinition converter rejects ARM-style `split(...)[n]` indexing.
- Keep a single set of optional volume overrides; blank fields follow the preset.
  Do not rely on reactive TextBox defaults: the portal retains initialized values.
  Preserve entered overrides when switching presets; clearing them uses the preset.
  Advanced overrides affect outputs only while enabled; the effective-settings
  summary must reflect the same values. SQL defaults to 64 KiB NTFS allocation,
  general purpose to 4 KiB, and both to 64 KiB stripe size. Portal retry tags are
  generated automatically; neither preset configures applications or permissions.
- Preserve unrelated BootExecute entries and ordering; add autoconfig only once.
- Keep folder normalization in the guest script so CLI, portal and manual
  invocation share validation. Rebuild ARM whenever the embedded script changes.
- On a free/DVD letter, require matching non-system NVMe disks to be RAW, online
  and writable. During an existing-volume refresh, refuse matching RAW, offline
  or read-only disks to avoid additional provisioning.
- Reject foreign volumes and incompatible filesystems/allocation sizes. A matching
  label alone is not proof that storage belongs to this project.
- Check existing path components for files/reparse points before native execution
  on an existing volume; verify every configured component afterward.
- Never infer reconstruction from a successful start alone. Use a marker and,
  for deterministic lab evidence, an explicitly approved guarded RAW reset.

## Remaining gaps

- Automatic region discovery and the nested deployment are locally validated,
  but have not yet been deployed to Azure. Earlier cloud results predate this
  template refactoring.
- SQL permissions, tempdb placement, availability before service startup and
  supported self-installed SQL operation.
- Other OS images, VM sizes/architectures, multiple NVMe disks and stripe behavior.
- Reexecution with unchanged managed-command properties/reused runTag.
- Non-RAW disk recovery rules, boot failure/delay handling and extension upgrades.
- Portal rendering/expression execution. UI structure, parameter wiring and
  validation rules are checked locally against documented controls; this is not
  a live portal acceptance test.

## Local test coverage

The local baseline is **102 passing Pester tests** on Windows PowerShell 5.1:
**335/351 executable commands covered (95.44%)** across the three guest scripts
and the lab-only disk-reset helper.

| Script | Commands covered | Coverage |
|---|---:|---:|
| Set-NvmeAutoConfig.ps1 | 195/196 | 99.49% |
| Test-NvmeAutoConfig.ps1 | 103/118 | 87.29% |
| Remove-NvmeAutoConfig.ps1 | 18/18 | 100% |
| Reset-NvmeTempDisk.ps1 | 19/19 | 100% |

Remaining uncovered commands are SQL service discovery/query execution and one
defensive JSON-array shape guard. Coverage is measured without excluding those
commands; no live SQL connections are made by unit tests. It does not measure
branch coverage, native binaries or the Azure integration harness.

Bicep build/lint, generated/embedded-script synchronization, parser/analyzer and
static UI checks run separately. Coverage is also measured in CI, with generated
reports kept out of the repository. See [testing guidance](../tests/README.md)
before extending coverage.
