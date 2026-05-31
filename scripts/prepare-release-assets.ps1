param(
    [string]$OutputDir = "release-assets"
)

$ErrorActionPreference = "Stop"

$registryRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir
} else {
    Join-Path $registryRoot $OutputDir
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
    if (-not $fullPath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Registry path escapes repository root: $UrlOrPath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Registry file not found: $UrlOrPath"
    }
    return $fullPath
}

function Copy-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$AssetName
    )

    $target = Join-Path $outputRoot $AssetName
    if (Test-Path -LiteralPath $target) {
        throw "Duplicate release asset name: $AssetName"
    }
    Copy-Item -LiteralPath $SourcePath -Destination $target -Force
}

if (Test-Path -LiteralPath $outputRoot) {
    Remove-Item -LiteralPath $outputRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$pluginsIndexPath = Join-Path $registryRoot "plugins/index.json"
$packagesIndexPath = Join-Path $registryRoot "packages/index.json"
Copy-ReleaseAsset -SourcePath $pluginsIndexPath -AssetName "plugins.index.json"
Copy-ReleaseAsset -SourcePath $packagesIndexPath -AssetName "packages.index.json"

$plugins = (Get-Content $pluginsIndexPath -Raw -Encoding UTF8 | ConvertFrom-Json).plugins
foreach ($plugin in @($plugins)) {
    foreach ($version in @($plugin.versions)) {
        $source = Resolve-RegistryFile -UrlOrPath ([string]$version.download_url)
        if ($null -eq $source) {
            continue
        }
        $assetName = "{0}-{1}.tinaplug" -f $plugin.plugin_id, $version.version
        Copy-ReleaseAsset -SourcePath $source -AssetName $assetName
    }
}

$packages = (Get-Content $packagesIndexPath -Raw -Encoding UTF8 | ConvertFrom-Json).packages
foreach ($package in @($packages)) {
    if ($null -eq $package.android -or [string]::IsNullOrWhiteSpace([string]$package.android.download_url)) {
        continue
    }
    $source = Resolve-RegistryFile -UrlOrPath ([string]$package.android.download_url)
    if ($null -eq $source) {
        continue
    }
    $leaf = Split-Path -Leaf $source
    $assetName = "{0}-{1}-{2}" -f $package.id, $package.android.version, $leaf
    Copy-ReleaseAsset -SourcePath $source -AssetName $assetName
}

$count = (Get-ChildItem -LiteralPath $outputRoot -File).Count
Write-Host "Prepared $count release asset(s): $outputRoot"
