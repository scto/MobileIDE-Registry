param(
    [switch]$SkipBuild,
    [switch]$SkipGitDiffCheck,
    [switch]$AllowLegacyV1
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
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
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

function Assert-NoHeavyFields {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$ObjectName,
        [Parameter(Mandatory = $true)][string[]]$Fields
    )

    foreach ($field in $Fields) {
        Assert-RegistryCondition `
            -Condition (-not (Test-JsonProperty -Object $Object -Name $field)) `
            -Message "$ObjectName must not contain heavy field: $field"
    }
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

function Assert-LightweightPluginCatalogEntry {
    param([Parameter(Mandatory = $true)]$Plugin)

    Assert-NoHeavyFields `
        -Object $Plugin `
        -ObjectName "Plugin v2 catalog $($Plugin.plugin_id)" `
        -Fields @(
            "repository_url",
            "homepage_url",
            "license",
            "versions",
            "download_url",
            "file_hash",
            "file_size",
            "changelog",
            "download_count",
            "rating_avg",
            "rating_count"
        )
}

function Assert-LightweightPackageCatalogEntry {
    param([Parameter(Mandatory = $true)]$Package)

    if ($null -eq $Package.android) {
        return
    }

    Assert-AndroidArtifactMetadata -AndroidPackage $Package.android -PackageId ([string]$Package.id)
    Assert-NoHeavyFields `
        -Object $Package.android `
        -ObjectName "Package v2 catalog $($Package.id).android" `
        -Fields @(
            "download_url",
            "download_sources",
            "checksum",
            "dependencies",
            "release_notes"
        )
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

function Assert-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$UrlOrPath,
        [long]$ExpectedSize = -1,
        [string]$ExpectedHash = "",
        [switch]$RequireTinaplugManifest
    )

    Assert-RegistryCondition `
        -Condition (-not [string]::IsNullOrWhiteSpace($UrlOrPath)) `
        -Message "Download URL is blank"

    $downloadPath = Resolve-RegistryFile -UrlOrPath $UrlOrPath
    if ($null -eq $downloadPath) {
        return
    }

    Assert-FileDigest -Path $downloadPath -ExpectedSize $ExpectedSize -ExpectedHash $ExpectedHash
    if ($RequireTinaplugManifest) {
        Assert-TinaPlugManifest -Path $downloadPath
    }
}

function Get-PackageVersionEntries {
    param($Versions)

    $entries = @()
    if ($null -eq $Versions) {
        return ,@($entries)
    }

    foreach ($packageVersionGroup in $Versions.PSObject.Properties) {
        foreach ($version in @($packageVersionGroup.Value)) {
            $entries += $version
        }
    }

    return ,@($entries)
}

if (-not $SkipBuild) {
    if ($AllowLegacyV1) {
        & (Join-Path $PSScriptRoot "build-registry.ps1") -IncludeLegacyV1
    } else {
        & (Join-Path $PSScriptRoot "build-registry.ps1")
    }
}

$pluginsIndexV2Path = Join-Path $registryRoot "plugins/index.v2.json"
$packagesIndexV2Path = Join-Path $registryRoot "packages/index.v2.json"
$pluginsIndexPath = Join-Path $registryRoot "plugins/index.json"
$packagesIndexPath = Join-Path $registryRoot "packages/index.json"

Assert-RegistryCondition -Condition (Test-Path -LiteralPath $pluginsIndexV2Path) -Message "Missing plugins/index.v2.json"
Assert-RegistryCondition -Condition (Test-Path -LiteralPath $packagesIndexV2Path) -Message "Missing packages/index.v2.json"

if ($AllowLegacyV1) {
    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $pluginsIndexPath) -Message "Missing legacy plugins/index.json"
    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $packagesIndexPath) -Message "Missing legacy packages/index.json"
} else {
    Assert-RegistryCondition -Condition (-not (Test-Path -LiteralPath $pluginsIndexPath)) -Message "Legacy plugins/index.json must not be generated by default"
    Assert-RegistryCondition -Condition (-not (Test-Path -LiteralPath $packagesIndexPath)) -Message "Legacy packages/index.json must not be generated by default"
}

$pluginsIndexV2 = Get-Content -Raw -Encoding UTF8 $pluginsIndexV2Path | ConvertFrom-Json
$packagesIndexV2 = Get-Content -Raw -Encoding UTF8 $packagesIndexV2Path | ConvertFrom-Json

$pluginCatalog = @($pluginsIndexV2.plugins)
$packageCatalog = @($packagesIndexV2.packages)
$packageCategories = @($packagesIndexV2.categories)

Assert-RegistryCondition -Condition ([int]$pluginsIndexV2.schema_version -eq 2) -Message "Invalid plugins/index.v2.json schema_version"
Assert-RegistryCondition -Condition ([int]$packagesIndexV2.schema_version -eq 2) -Message "Invalid packages/index.v2.json schema_version"
Assert-UniqueValues -Values @($pluginCatalog | ForEach-Object { $_.plugin_id }) -Name "plugin v2 plugin_id"
Assert-UniqueValues -Values @($packageCatalog | ForEach-Object { $_.id }) -Name "package v2 id"
Assert-UniqueValues -Values @($packageCategories | ForEach-Object { $_.id }) -Name "package category id"

$categoryIds = @($packageCategories | ForEach-Object { [string]$_.id })

foreach ($plugin in $pluginCatalog) {
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$plugin.plugin_id)) -Message "Plugin v2 id is blank"
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$plugin.detail_url)) -Message "Plugin v2 detail_url is blank: $($plugin.plugin_id)"
    Assert-LightweightPluginCatalogEntry -Plugin $plugin

    $detailPath = Resolve-RegistryFile -UrlOrPath ([string]$plugin.detail_url)
    Assert-RegistryCondition -Condition ($null -ne $detailPath) -Message "Plugin v2 detail_url must be repository-relative: $($plugin.plugin_id)"
    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $detailPath -PathType Leaf) -Message "Plugin v2 detail file missing: $($plugin.detail_url)"

    $detail = Get-Content -Raw -Encoding UTF8 $detailPath | ConvertFrom-Json
    Assert-RegistryCondition -Condition ([string]$detail.plugin_id -eq [string]$plugin.plugin_id) -Message "Plugin v2 detail id mismatch: $($plugin.plugin_id)"

    $versions = @($detail.versions)
    Assert-RegistryCondition -Condition ($versions.Count -gt 0) -Message "Plugin v2 detail has no versions: $($plugin.plugin_id)"
    Assert-UniqueValues -Values @($versions | ForEach-Object { $_.version }) -Name "plugin version for $($plugin.plugin_id)"

    $versionNames = @($versions | ForEach-Object { [string]$_.version })
    Assert-RegistryCondition -Condition ([string]$plugin.latest_version -in $versionNames) -Message "Plugin v2 latest_version missing from detail versions: $($plugin.plugin_id)"

    foreach ($version in $versions) {
        Assert-DownloadFile `
            -UrlOrPath ([string]$version.download_url) `
            -ExpectedSize ([long]$version.file_size) `
            -ExpectedHash ([string]$version.file_hash) `
            -RequireTinaplugManifest
    }
}

foreach ($package in $packageCatalog) {
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$package.id)) -Message "Package v2 id is blank"
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$package.detail_url)) -Message "Package v2 detail_url is blank: $($package.id)"
    Assert-LightweightPackageCatalogEntry -Package $package

    if (-not [string]::IsNullOrWhiteSpace([string]$package.category)) {
        Assert-RegistryCondition -Condition ([string]$package.category -in $categoryIds) -Message "Package v2 category is not declared: $($package.id)"
    }

    $detailPath = Resolve-RegistryFile -UrlOrPath ([string]$package.detail_url)
    Assert-RegistryCondition -Condition ($null -ne $detailPath) -Message "Package v2 detail_url must be repository-relative: $($package.id)"
    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $detailPath -PathType Leaf) -Message "Package v2 detail file missing: $($package.detail_url)"

    $detail = Get-Content -Raw -Encoding UTF8 $detailPath | ConvertFrom-Json
    Assert-RegistryCondition -Condition ([string]$detail.package.id -eq [string]$package.id) -Message "Package v2 detail id mismatch: $($package.id)"
    Assert-RegistryCondition -Condition ($null -ne $detail.versions) -Message "Package v2 detail has no versions: $($package.id)"

    if ($null -ne $detail.package.android) {
        Assert-AndroidArtifactMetadata -AndroidPackage $detail.package.android -PackageId ([string]$package.id)
        if (-not [string]::IsNullOrWhiteSpace([string]$detail.package.android.download_url)) {
            Assert-DownloadFile `
                -UrlOrPath ([string]$detail.package.android.download_url) `
                -ExpectedSize ([long]$detail.package.android.size) `
                -ExpectedHash ([string]$detail.package.android.checksum)
        }
    }

    $versionEntries = Get-PackageVersionEntries $detail.versions
    Assert-RegistryCondition -Condition ($versionEntries.Count -gt 0) -Message "Package v2 detail has no version entries: $($package.id)"
    Assert-UniqueValues `
        -Values @($versionEntries | ForEach-Object { "{0}:{1}" -f $_.platform, $_.version }) `
        -Name "package version for $($package.id)"

    foreach ($version in $versionEntries) {
        if ([string]$version.platform -eq "android") {
            Assert-AndroidArtifactMetadata -AndroidPackage $version -PackageId ([string]$version.package_id)
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$version.download_url)) {
            Assert-DownloadFile `
                -UrlOrPath ([string]$version.download_url) `
                -ExpectedSize ([long]$version.download_size) `
                -ExpectedHash ([string]$version.checksum)
        }
    }

    if ($null -ne $detail.downloads) {
        foreach ($downloadEntry in $detail.downloads.PSObject.Properties) {
            foreach ($source in @($downloadEntry.Value.sources)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$source.url)) {
                    Assert-DownloadFile `
                        -UrlOrPath ([string]$source.url) `
                        -ExpectedSize ([long]$downloadEntry.Value.size) `
                        -ExpectedHash ([string]$downloadEntry.Value.checksum)
                }
            }
        }
    }
}

if ($AllowLegacyV1) {
    $pluginsIndex = Get-Content -Raw -Encoding UTF8 $pluginsIndexPath | ConvertFrom-Json
    $packagesIndex = Get-Content -Raw -Encoding UTF8 $packagesIndexPath | ConvertFrom-Json
    $legacyPlugins = @($pluginsIndex.plugins)
    $legacyPackages = @($packagesIndex.packages)
    Assert-RegistryCondition -Condition ($legacyPlugins.Count -eq $pluginCatalog.Count) -Message "Legacy plugin index count does not match v2 catalog"
    Assert-RegistryCondition -Condition ($legacyPackages.Count -eq $packageCatalog.Count) -Message "Legacy package index count does not match v2 catalog"
}

if (-not $SkipGitDiffCheck) {
    $diff = git -C $registryRoot status --porcelain
    Assert-RegistryCondition -Condition ([string]::IsNullOrWhiteSpace(($diff -join "`n"))) -Message "Registry build produced uncommitted changes."
}

Write-Host ("Registry validation passed: plugins={0}, packages={1}, legacyV1={2}" -f $pluginCatalog.Count, $packageCatalog.Count, [bool]$AllowLegacyV1)
