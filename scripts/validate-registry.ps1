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

Assert-RegistryCondition -Condition (Test-Path -LiteralPath $pluginsIndexPath) -Message "Missing plugins/index.json"
Assert-RegistryCondition -Condition (Test-Path -LiteralPath $packagesIndexPath) -Message "Missing packages/index.json"

$pluginsIndex = Get-Content -Raw -Encoding UTF8 $pluginsIndexPath | ConvertFrom-Json
$packagesIndex = Get-Content -Raw -Encoding UTF8 $packagesIndexPath | ConvertFrom-Json

$plugins = @($pluginsIndex.plugins)
$packages = @($packagesIndex.packages)

Assert-UniqueValues -Values @($plugins | ForEach-Object { $_.plugin_id }) -Name "plugin_id"
Assert-UniqueValues -Values @($packages | ForEach-Object { $_.id }) -Name "package id"

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
