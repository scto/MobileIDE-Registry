param(
    [switch]$SkipBuild,
    [switch]$SkipGitDiffCheck
)

$ErrorActionPreference = "Stop"

$registryRoot = Split-Path -Parent $PSScriptRoot

function Assert-RegistryCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Resolve-RegistryFile {
    param([Parameter(Mandatory = $true)][string]$UrlOrPath)

    $value = $UrlOrPath.Trim()
    if ($value.StartsWith("http://") -or $value.StartsWith("https://")) {
        return $null
    }

    $relative = $value.TrimStart("/", "\").Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $registryRoot $relative))
    $rootPath = [System.IO.Path]::GetFullPath($registryRoot)
    Assert-RegistryCondition `
        -Condition $fullPath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase) `
        -Message "Registry path escapes repository root: $UrlOrPath"
    return $fullPath
}

function Assert-UniqueValues {
    param(
        [Parameter(Mandatory = $true)][object[]]$Values,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $duplicates = $Values |
        Group-Object |
        Where-Object { $_.Count -gt 1 } |
        ForEach-Object { $_.Name }
    Assert-RegistryCondition `
        -Condition ($duplicates.Count -eq 0) `
        -Message ("Duplicate {0}: {1}" -f $Name, ($duplicates -join ", "))
}

function Get-StringArrayOrNull {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $items = @($Value) |
        ForEach-Object { [string]$_ } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($items.Count -eq 0) {
        return $null
    }

    return ,@($items)
}

function Test-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-AndroidArtifactMetadata {
    param(
        [Parameter(Mandatory = $true)]$AndroidPackage,
        [Parameter(Mandatory = $true)][string]$PackageId
    )

    $validArtifactTypes = @("source", "header", "static", "shared", "executable", "mixed")
    $validAbis = @("arm64-v8a", "x86_64", "armeabi-v7a", "x86")
    $artifactType = ([string]$AndroidPackage.artifact_type).Trim()
    $abiValues = Get-StringArrayOrNull $AndroidPackage.abi

    Assert-RegistryCondition `
        -Condition (-not [string]::IsNullOrWhiteSpace($artifactType)) `
        -Message "Android package missing artifact_type: $PackageId"
    Assert-RegistryCondition `
        -Condition ($artifactType -in $validArtifactTypes) `
        -Message "Invalid artifact_type for ${PackageId}: $artifactType"

    if ($null -ne $abiValues) {
        Assert-UniqueValues -Values $abiValues -Name "ABI for $PackageId"
        foreach ($abi in $abiValues) {
            Assert-RegistryCondition `
                -Condition ($abi -in $validAbis) `
                -Message "Invalid ABI for ${PackageId}: $abi"
        }
    }

    if ($artifactType -in @("source", "header")) {
        Assert-RegistryCondition `
            -Condition ($null -eq $abiValues) `
            -Message "ABI-independent package must not declare abi: $PackageId"
    }

    if ($artifactType -in @("static", "shared", "executable")) {
        Assert-RegistryCondition `
            -Condition ($null -ne $abiValues -and $abiValues.Count -gt 0) `
            -Message "Binary Android package must declare abi: $PackageId"
    }
}

function Assert-LightweightCatalogAndroidPackage {
    param(
        $AndroidPackage,
        [Parameter(Mandatory = $true)][string]$PackageId
    )

    if ($null -eq $AndroidPackage) {
        return
    }

    Assert-AndroidArtifactMetadata -AndroidPackage $AndroidPackage -PackageId $PackageId
    $heavyFields = @(
        "download_url",
        "download_sources",
        "checksum",
        "dependencies",
        "release_notes"
    )
    foreach ($field in $heavyFields) {
        Assert-RegistryCondition `
            -Condition (-not (Test-JsonProperty -Object $AndroidPackage -Name $field)) `
            -Message "Package v2 catalog must not contain heavy field ${PackageId}.android.${field}"
    }
}

function Assert-FileDigest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$ExpectedSize = -1,
        [string]$ExpectedHash = ""
    )

    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $Path -PathType Leaf) -Message "File not found: $Path"

    $file = Get-Item -LiteralPath $Path
    if ($ExpectedSize -ge 0) {
        Assert-RegistryCondition `
            -Condition ($file.Length -eq $ExpectedSize) `
            -Message "File size mismatch: $Path expected=$ExpectedSize actual=$($file.Length)"
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedHash)) {
        $expected = $ExpectedHash.Substring($ExpectedHash.IndexOf(":") + 1).ToLowerInvariant()
        $actual = Get-FileSha256 -Path $Path
        Assert-RegistryCondition `
            -Condition ($actual -eq $expected) `
            -Message "File hash mismatch: $Path expected=$expected actual=$actual"
    }
}

function Assert-TinaPlugManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $hasManifest = $zip.Entries | Where-Object { $_.FullName -eq "manifest.json" } | Select-Object -First 1
        Assert-RegistryCondition -Condition ($null -ne $hasManifest) -Message "Tinaplug missing root manifest.json: $Path"
    } finally {
        $zip.Dispose()
    }
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot "build-registry.ps1")
}

$pluginsIndexPath = Join-Path $registryRoot "plugins/index.json"
$packagesIndexPath = Join-Path $registryRoot "packages/index.json"
$pluginsIndexV2Path = Join-Path $registryRoot "plugins/index.v2.json"
$packagesIndexV2Path = Join-Path $registryRoot "packages/index.v2.json"

Assert-RegistryCondition -Condition (Test-Path -LiteralPath $pluginsIndexPath) -Message "Missing plugins/index.json"
Assert-RegistryCondition -Condition (Test-Path -LiteralPath $packagesIndexPath) -Message "Missing packages/index.json"
Assert-RegistryCondition -Condition (Test-Path -LiteralPath $pluginsIndexV2Path) -Message "Missing plugins/index.v2.json"
Assert-RegistryCondition -Condition (Test-Path -LiteralPath $packagesIndexV2Path) -Message "Missing packages/index.v2.json"

$pluginsIndex = Get-Content -Raw -Encoding UTF8 $pluginsIndexPath | ConvertFrom-Json
$packagesIndex = Get-Content -Raw -Encoding UTF8 $packagesIndexPath | ConvertFrom-Json
$pluginsIndexV2 = Get-Content -Raw -Encoding UTF8 $pluginsIndexV2Path | ConvertFrom-Json
$packagesIndexV2 = Get-Content -Raw -Encoding UTF8 $packagesIndexV2Path | ConvertFrom-Json

$plugins = @($pluginsIndex.plugins)
$packages = @($packagesIndex.packages)
$pluginCatalog = @($pluginsIndexV2.plugins)
$packageCatalog = @($packagesIndexV2.packages)

Assert-RegistryCondition -Condition ([int]$pluginsIndexV2.schema_version -eq 2) -Message "Invalid plugins/index.v2.json schema_version"
Assert-RegistryCondition -Condition ([int]$packagesIndexV2.schema_version -eq 2) -Message "Invalid packages/index.v2.json schema_version"
Assert-RegistryCondition -Condition ($pluginCatalog.Count -eq $plugins.Count) -Message "Plugin v2 catalog count does not match v1 index"
Assert-RegistryCondition -Condition ($packageCatalog.Count -eq $packages.Count) -Message "Package v2 catalog count does not match v1 index"
Assert-UniqueValues -Values @($plugins | ForEach-Object { $_.plugin_id }) -Name "plugin_id"
Assert-UniqueValues -Values @($packages | ForEach-Object { $_.id }) -Name "package id"
Assert-UniqueValues -Values @($pluginCatalog | ForEach-Object { $_.plugin_id }) -Name "plugin v2 plugin_id"
Assert-UniqueValues -Values @($packageCatalog | ForEach-Object { $_.id }) -Name "package v2 id"

foreach ($plugin in $pluginCatalog) {
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$plugin.plugin_id)) -Message "Plugin v2 id is blank"
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$plugin.detail_url)) -Message "Plugin v2 detail_url is blank: $($plugin.plugin_id)"

    $detailPath = Resolve-RegistryFile -UrlOrPath ([string]$plugin.detail_url)
    Assert-RegistryCondition -Condition ($null -ne $detailPath) -Message "Plugin v2 detail_url must be repository-relative: $($plugin.plugin_id)"
    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $detailPath -PathType Leaf) -Message "Plugin v2 detail file missing: $($plugin.detail_url)"

    $detail = Get-Content -Raw -Encoding UTF8 $detailPath | ConvertFrom-Json
    Assert-RegistryCondition -Condition ([string]$detail.plugin_id -eq [string]$plugin.plugin_id) -Message "Plugin v2 detail id mismatch: $($plugin.plugin_id)"
    Assert-RegistryCondition -Condition (@($detail.versions).Count -gt 0) -Message "Plugin v2 detail has no versions: $($plugin.plugin_id)"
}

foreach ($package in $packageCatalog) {
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$package.id)) -Message "Package v2 id is blank"
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$package.detail_url)) -Message "Package v2 detail_url is blank: $($package.id)"
    Assert-LightweightCatalogAndroidPackage -AndroidPackage $package.android -PackageId ([string]$package.id)

    $detailPath = Resolve-RegistryFile -UrlOrPath ([string]$package.detail_url)
    Assert-RegistryCondition -Condition ($null -ne $detailPath) -Message "Package v2 detail_url must be repository-relative: $($package.id)"
    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $detailPath -PathType Leaf) -Message "Package v2 detail file missing: $($package.detail_url)"

    $detail = Get-Content -Raw -Encoding UTF8 $detailPath | ConvertFrom-Json
    Assert-RegistryCondition -Condition ([string]$detail.package.id -eq [string]$package.id) -Message "Package v2 detail id mismatch: $($package.id)"
    Assert-RegistryCondition -Condition ($null -ne $detail.versions) -Message "Package v2 detail has no versions: $($package.id)"
}

foreach ($plugin in $plugins) {
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$plugin.plugin_id)) -Message "Plugin id is blank"
    $versions = @($plugin.versions)
    Assert-RegistryCondition -Condition ($versions.Count -gt 0) -Message "Plugin has no versions: $($plugin.plugin_id)"
    Assert-UniqueValues -Values @($versions | ForEach-Object { $_.version }) -Name "plugin version for $($plugin.plugin_id)"

    foreach ($version in $versions) {
        $downloadPath = Resolve-RegistryFile -UrlOrPath ([string]$version.download_url)
        if ($null -ne $downloadPath) {
            Assert-FileDigest -Path $downloadPath -ExpectedSize ([long]$version.file_size) -ExpectedHash ([string]$version.file_hash)
            Assert-TinaPlugManifest -Path $downloadPath
        }
    }
}

foreach ($package in $packages) {
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$package.id)) -Message "Package id is blank"
    if ($null -ne $package.android) {
        Assert-AndroidArtifactMetadata -AndroidPackage $package.android -PackageId ([string]$package.id)

        if (-not [string]::IsNullOrWhiteSpace([string]$package.android.download_url)) {
            $downloadPath = Resolve-RegistryFile -UrlOrPath ([string]$package.android.download_url)
            if ($null -ne $downloadPath) {
                Assert-FileDigest `
                    -Path $downloadPath `
                    -ExpectedSize ([long]$package.android.size) `
                    -ExpectedHash ([string]$package.android.checksum)
            }
        }
    }
}

$versionEntries = @()
if ($null -ne $packagesIndex.versions) {
    foreach ($packageVersionGroup in $packagesIndex.versions.PSObject.Properties) {
        foreach ($platformVersions in $packageVersionGroup.Value.PSObject.Properties) {
            foreach ($version in @($platformVersions.Value)) {
                $versionEntries += $version
            }
        }
    }
}

foreach ($version in $versionEntries) {
    if ([string]$version.platform -eq "android") {
        Assert-AndroidArtifactMetadata -AndroidPackage $version -PackageId ([string]$version.package_id)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$version.download_url)) {
        $downloadPath = Resolve-RegistryFile -UrlOrPath ([string]$version.download_url)
        if ($null -ne $downloadPath) {
            Assert-FileDigest `
                -Path $downloadPath `
                -ExpectedSize ([long]$version.download_size) `
                -ExpectedHash ([string]$version.checksum)
        }
    }
}

if (-not $SkipGitDiffCheck) {
    $diff = git -C $registryRoot status --porcelain
    Assert-RegistryCondition -Condition ([string]::IsNullOrWhiteSpace(($diff -join "`n"))) -Message "Registry build produced uncommitted changes."
}

Write-Host ("Registry validation passed: plugins={0}, packages={1}" -f $plugins.Count, $packages.Count)
