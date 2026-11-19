#requires -Version 5.1
<#
.SYNOPSIS
Checks templates, embedded PowerShell and portal input rules on Windows PowerShell 5.1.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw 'Run this script with Windows PowerShell 5.1 to validate the actual target parser.'
}
Import-Module PSScriptAnalyzer -MinimumVersion 1.24.0 -ErrorAction Stop
$root = Split-Path $PSScriptRoot -Parent
$temporary = Join-Path $env:TEMP ("nvme-build-{0}.json" -f [guid]::NewGuid().ToString('N'))
try {
    $build = @(& az bicep build --file (Join-Path $root 'nvme-autoconfig.bicep') --outfile $temporary 2>&1 | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
    if ($LASTEXITCODE -ne 0 -or $build.Count -gt 0) { throw "S1 build diagnostics: $($build -join [Environment]::NewLine)" }
    $lint = @(& az bicep lint --file (Join-Path $root 'nvme-autoconfig.bicep') 2>&1 | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
    if ($LASTEXITCODE -ne 0 -or $lint.Count -gt 0) { throw "S1 lint diagnostics: $($lint -join [Environment]::NewLine)" }
    Write-Output 'S1 PASS: Bicep build and lint, zero diagnostics.'
    $generated = [IO.File]::ReadAllText($temporary).Replace("`r`n", "`n")
    $committed = [IO.File]::ReadAllText((Join-Path $root 'azuredeploy.json')).Replace("`r`n", "`n")
    if ($generated -cne $committed) { throw 'S2: azuredeploy.json is stale. Rebuild with the pinned Bicep version.' }
    $template = $generated | ConvertFrom-Json
    $deployments = @($template.resources.PSObject.Properties.Value |
        Where-Object type -eq 'Microsoft.Resources/deployments')
    if ($template.parameters.PSObject.Properties['location'] -or $deployments.Count -ne 1) {
        throw 'S2: region discovery requires one nested deployment and no public location parameter.'
    }
    $deployment = $deployments[0]
    if ($deployment.properties.parameters.location.value -cne "[reference('vm', '2025-04-01', 'full').location]" -or
        $deployment.properties.expressionEvaluationOptions.scope -ne 'inner' -or
        $deployment.properties.PSObject.Properties['templateLink']) {
        throw 'S2: the module must receive the existing VM region and use an embedded, inner-scoped template.'
    }
    $configurationTemplate = $deployment.properties.template
    foreach ($name in $template.parameters.PSObject.Properties.Name) {
        if ($deployment.properties.parameters.$name.value -cne "[parameters('$name')]") {
            throw "S2: module parameter '$name' does not forward the public input."
        }
    }
    foreach ($scopeTemplate in @($template, $configurationTemplate)) {
        $vms = @($scopeTemplate.resources.PSObject.Properties.Value |
            Where-Object type -eq 'Microsoft.Compute/virtualMachines')
        if ($vms.Count -ne 1 -or $vms[0].existing -ne $true) {
            throw 'S2: both templates must reference the VM without redeploying it.'
        }
    }
    $extensions = @($configurationTemplate.resources.PSObject.Properties.Value |
        Where-Object type -eq 'Microsoft.Compute/virtualMachines/extensions')
    $runCommands = @($configurationTemplate.resources.PSObject.Properties.Value |
        Where-Object type -eq 'Microsoft.Compute/virtualMachines/runCommands')
    if ($extensions.Count -ne 1 -or $runCommands.Count -ne 1 -or
        $extensions[0].location -cne "[parameters('location')]" -or
        $runCommands[0].location -cne "[parameters('location')]" -or
        $runCommands[0].dependsOn -notcontains 'localStoragePrep') {
        throw 'S2: extension and managed command must use the discovered region and preserve execution order.'
    }
    foreach ($name in @('runCommandName', 'checkResult')) {
        if ($template.outputs.$name.value -cne "[reference('configuration').outputs.$name.value]") {
            throw "S2: public output '$name' does not forward the module output."
        }
    }
    Write-Output 'S2 PASS: generated ARM matches azuredeploy.json; automatic VM-region/module wiring is valid.'

    $files = @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts'), (Join-Path $root 'tests') -Filter '*.ps1' -Recurse)
    foreach ($file in $files) {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw "S3 parse errors in $($file.Name): $parseErrors" }
        $diagnostics = @(Invoke-ScriptAnalyzer -Path $file.FullName -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1'))
        if ($diagnostics.Count -gt 0) { throw "S3 analyzer: $($diagnostics | Out-String)" }
    }
    $runCommand = $runCommands[0]
    $embeddedScript = $runCommand.properties.source.script
    if ($embeddedScript -match '^\[variables\(''([^'']+)''\)\]$') {
        $embeddedScript = $configurationTemplate.variables.($Matches[1])
    }
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($embeddedScript, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "S3 embedded-script errors: $parseErrors" }
    if ($embeddedScript -cne [IO.File]::ReadAllText((Join-Path $root 'scripts\Set-NvmeAutoConfig.ps1'))) {
        throw 'S3: embedded script differs from the single source of truth.'
    }
    Write-Output 'S3 PASS: PowerShell 5.1 parser (files and embedded script) and PSScriptAnalyzer.'

    $ui = Get-Content -LiteralPath (Join-Path $root 'createUiDefinition.json') -Raw | ConvertFrom-Json
    if ($ui.handler -ne 'Microsoft.Azure.CreateUIDef' -or $ui.version -ne '0.1.2-preview' -or
        $ui.parameters.config.isWizard -ne $true -or $ui.parameters.config.basics.resourceGroup.allowExisting -ne $true) {
        throw 'S4: unexpected UI handler, version or existing-resource wizard configuration.'
    }
    $basicsNames = @($ui.parameters.basics | ForEach-Object name)
    if (@($basicsNames | Select-Object -Unique).Count -ne $basicsNames.Count) { throw 'S4: duplicate Basics control names.' }
    $readme = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
    foreach ($name in @('disclaimer','componentWarning','sqlWarning')) {
        $warning = @($ui.parameters.basics | Where-Object name -eq $name)
        if ($warning.Count -ne 1 -or $warning[0].type -ne 'Microsoft.Common.InfoBox' -or
            $warning[0].visible -ne $true -or $warning[0].options.icon -ne 'Warning' -or
            [string]::IsNullOrWhiteSpace($warning[0].options.text) -or -not $readme.Contains($warning[0].options.text) -or
            [array]::IndexOf($basicsNames, $name) -ge [array]::IndexOf($basicsNames, 'confirmation')) {
            throw "S4: warning '$name' must mirror the README and be visible before confirmation."
        }
    }
    $selector = $ui.parameters.basics | Where-Object name -eq 'vmSelector'
    if ($selector.type -ne 'Microsoft.Solutions.ResourceSelector' -or
        $selector.resourceType -ne 'Microsoft.Compute/virtualMachines' -or
        $selector.options.filter.subscription -ne 'onBasics' -or $selector.options.filter.location -ne 'all') {
        throw 'S4: selector must target existing VMs in the chosen subscription across regions.'
    }
    $details = $ui.parameters.basics | Where-Object name -eq 'vmDetails'
    if ($details.type -ne 'Microsoft.Solutions.ArmApiControl' -or $details.request.method -ne 'GET' -or
        $details.request.path -ne "[concat(basics('vmSelector').id, '?api-version=2025-04-01&`$expand=instanceView')]") {
        throw 'S4: VM details must read OS and instance-view state from the selected VM.'
    }
    $confirmation = $ui.parameters.basics | Where-Object name -eq 'confirmation'
    if (-not $confirmation.constraints.required -or $confirmation.constraints.validations[0].regex -cne '^CONFIRM$') {
        throw 'S4: explicit experimental-change confirmation is required.'
    }
    $expectedVmValidations = @(
        "[equals(toLower(split(basics('vmSelector').id, '/')[4]), toLower(resourceGroup().name))]"
        "[equals(basics('vmDetails').properties.storageProfile.osDisk.osType, 'Windows')]"
        "[contains(string(basics('vmDetails').properties.instanceView.statuses), 'PowerState/running')]"
    )
    foreach ($expression in $expectedVmValidations) {
        if (@($confirmation.constraints.validations | Where-Object { $_.PSObject.Properties['isValid'] -and $_.isValid -ceq $expression }).Count -ne 1) {
            throw 'S4: missing selected-VM group/OS/running-state validation.'
        }
    }
    $templateNames = @($template.parameters.PSObject.Properties.Name | Sort-Object)
    $uiNames = @($ui.parameters.outputs.PSObject.Properties.Name | Sort-Object)
    if (Compare-Object $templateNames $uiNames) { throw 'S4: UI output names do not exactly match template parameter names.' }
    foreach ($output in $ui.parameters.outputs.PSObject.Properties) {
        $expression = $output.Value
        $type = 'string'
        if ($expression -match '^\[split\(') { $type = 'array' }
        if ($expression -match '^\[parse\(') { $type = 'int' }
        if ($type -ne $template.parameters.($output.Name).type) { throw "S4: output type mismatch for $($output.Name)" }
    }
    $expectedOutputs = @{
        vmName = "[basics('vmSelector').name]"
        driveLetter = "[toUpper(if(equals(steps('settings').profile, 'sql'), steps('settings').sqlDriveLetter, steps('settings').customDriveLetter))]"
        volumeLabel = "[if(equals(steps('settings').profile, 'sql'), steps('settings').sqlVolumeLabel, steps('settings').customVolumeLabel)]"
        volumePaths = "[split(if(equals(steps('settings').profile, 'sql'), steps('settings').sqlVolumePaths, steps('settings').customVolumePaths), ';')]"
        diskModels = "[split(if(equals(steps('settings').profile, 'sql'), steps('settings').sqlDiskModels, steps('settings').customDiskModels), ';')]"
        volumeClusterSize = "[parse(if(equals(steps('settings').profile, 'sql'), steps('settings').sqlClusterSize, steps('settings').customClusterSize))]"
        virtualDiskStripeSize = "[parse(if(equals(steps('settings').profile, 'sql'), steps('settings').sqlStripeSize, steps('settings').customStripeSize))]"
        runTag = "[steps('settings').runTag]"
    }
    foreach ($name in $expectedOutputs.Keys) {
        if ($ui.parameters.outputs.$name -cne $expectedOutputs[$name]) { throw "S4: wrong selected-profile binding for $name." }
    }
    foreach ($profileName in @('sql', 'custom')) {
        $controls = @{}
        foreach ($control in $ui.parameters.steps[0].elements) { $controls[$control.name] = $control }
        foreach ($suffix in @('DriveLetter', 'VolumeLabel', 'VolumePaths', 'ClusterSize', 'StripeSize', 'DiskModels')) {
            $control = $controls["$profileName$suffix"]
            if ($control.visible -ne "[equals(steps('settings').profile, '$profileName')]") { throw "S4: wrong visibility for $($control.name)" }
            if ($control.defaultValue -match '^\[') { throw 'S4: profile defaults must not depend on controls.' }
        }
        foreach ($suffix in @('DriveLetter', 'VolumeLabel', 'VolumePaths')) {
            $control = $controls["$profileName$suffix"]
            $regex = $control.constraints.validations[0].regex
            if ($control.defaultValue -cnotmatch $regex) { throw "S4: invalid default for $($control.name)" }
        }
        foreach ($letter in @('A', 'B', 'C', 'DD')) {
            if ($letter -cmatch $controls["${profileName}DriveLetter"].constraints.validations[0].regex) { throw "S5 UI accepted $letter" }
        }
        foreach ($label in @("bad'label", 'bad"label', ('x' * 33))) {
            if ($label -cmatch $controls["${profileName}VolumeLabel"].constraints.validations[0].regex) { throw 'S5 UI accepted invalid label.' }
        }
        foreach ($path in @('..\data', 'C:\data', '\data', "bad'path", 'bad"path', 'con', 'nul.txt', 'D:\aUx', 'data\lPt1.log')) {
            if ($path -cmatch $controls["${profileName}VolumePaths"].constraints.validations[0].regex) { throw "S5 UI accepted invalid path: $path" }
        }
        foreach ($path in @('D:\tempdb\data', 't:\temp\data;temp\log', 'tempdb\data;D:\tempdb\log')) {
            if ($path -cnotmatch $controls["${profileName}VolumePaths"].constraints.validations[0].regex) { throw "S5 UI rejected valid path syntax: $path" }
        }
        foreach ($path in @('D:\', 'D:data', 'D:\..\data', 'D:\data\\logs', '\\server\share')) {
            if ($path -cmatch $controls["${profileName}VolumePaths"].constraints.validations[0].regex) { throw "S5 UI accepted invalid full path: $path" }
        }
        $allowedClusters = @($controls["${profileName}ClusterSize"].constraints.allowedValues | ForEach-Object { [int]$_.value })
        if (Compare-Object $allowedClusters $template.parameters.volumeClusterSize.allowedValues) { throw 'S4 cluster choices differ from template.' }
        $allowedStripes = @($controls["${profileName}StripeSize"].constraints.allowedValues | ForEach-Object { [int]$_.value })
        if (Compare-Object $allowedStripes @(4096,8192,16384,32768,65536,131072,262144,524288,1048576)) {
            throw 'S4: stripe choices must match the guest power-of-two range.'
        }
    }
    Write-Output 'S4 PASS: UI warnings, VM guards, output/profile bindings and defaults. Portal execution requires sandbox testing.'
    Write-Output 'S5 UI PASS: invalid inputs rejected; guest validation is covered by Pester.'
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
