param(
    [switch]$SkipStarterBuild
)

$ErrorActionPreference = "Stop"

$registryRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $registryRoot ".build"

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($Path, $normalized, $encoding)
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function ConvertTo-VersionCode {
    param([Parameter(Mandatory = $true)][string]$Version)

    $parts = [regex]::Split($Version, "[^0-9]+") |
        Where-Object { $_ -ne "" } |
        ForEach-Object { [int]$_ }

    if ($parts.Count -eq 0) {
        return 1
    }

    $major = $parts[0]
    $minor = if ($parts.Count -gt 1) { $parts[1] } else { 0 }
    $patch = if ($parts.Count -gt 2) { $parts[2] } else { 0 }
    return ($major * 10000) + ($minor * 100) + $patch
}

function ConvertTo-JsonText {
    param([Parameter(Mandatory = $true)]$Value)

    $json = $Value | ConvertTo-Json -Depth 32 -Compress
    $builder = [System.Text.StringBuilder]::new()
    $indent = 0
    $inString = $false
    $escaped = $false

    foreach ($char in $json.ToCharArray()) {
        if ($inString) {
            [void]$builder.Append($char)
            if ($escaped) {
                $escaped = $false
            } elseif ($char -eq '\') {
                $escaped = $true
            } elseif ($char -eq '"') {
                $inString = $false
            }
            continue
        }

        switch ($char) {
            '"' {
                $inString = $true
                [void]$builder.Append($char)
            }
            { $_ -eq '{' -or $_ -eq '[' } {
                [void]$builder.Append($char)
                [void]$builder.Append("`n")
                $indent++
                [void]$builder.Append((' ' * ($indent * 2)))
            }
            { $_ -eq '}' -or $_ -eq ']' } {
                [void]$builder.Append("`n")
                $indent--
                [void]$builder.Append((' ' * ($indent * 2)))
                [void]$builder.Append($char)
            }
            ',' {
                [void]$builder.Append($char)
                [void]$builder.Append("`n")
                [void]$builder.Append((' ' * ($indent * 2)))
            }
            ':' {
                [void]$builder.Append(": ")
            }
            default {
                [void]$builder.Append($char)
            }
        }
    }

    return (($builder.ToString() -split "`n") | ForEach-Object { $_.TrimEnd() }) -join "`n"
}

function Get-ArchiveRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$FilePath
    )

    try {
        return ([System.IO.Path]::GetRelativePath($BasePath, $FilePath)).Replace("\", "/")
    } catch {
        $baseUri = [Uri]($BasePath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar)
        return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri([Uri]$FilePath).ToString())
    }
}

function New-TinaPlugArchive {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$OutputFile
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (Test-Path -LiteralPath $OutputFile) {
        Remove-Item -LiteralPath $OutputFile -Force
    }

    $sourcePath = (Resolve-Path -LiteralPath $SourceDir).Path
    $fixedTime = [DateTimeOffset]::new(2020, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $zip = [System.IO.Compression.ZipFile]::Open($OutputFile, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -LiteralPath $sourcePath -File -Recurse -Force |
            Sort-Object FullName |
            ForEach-Object {
                $relativePath = Get-ArchiveRelativePath -BasePath $sourcePath -FilePath $_.FullName
                $entry = $zip.CreateEntry($relativePath, [System.IO.Compression.CompressionLevel]::NoCompression)
                $entry.LastWriteTime = $fixedTime
                $entry.ExternalAttributes = 0
                $entryStream = $entry.Open()
                try {
                    $fileStream = [System.IO.File]::OpenRead($_.FullName)
                    try {
                        $fileStream.CopyTo($entryStream)
                    } finally {
                        $fileStream.Dispose()
                    }
                } finally {
                    $entryStream.Dispose()
                }
            }
    } finally {
        $zip.Dispose()
    }
}

if (-not $SkipStarterBuild) {
    & (Join-Path $PSScriptRoot "build-plugin-starters.ps1")
}

New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

$pluginMetadata = Get-Content -Raw -Encoding UTF8 (Join-Path $registryRoot "metadata/plugins.json") |
    ConvertFrom-Json

$pluginEntries = @()
foreach ($item in @($pluginMetadata.plugins)) {
    $sourceDir = Join-Path $registryRoot $item.source
    $manifestPath = Join-Path $sourceDir "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Plugin manifest not found: $manifestPath"
    }

    $manifest = Get-Content -Raw -Encoding UTF8 $manifestPath | ConvertFrom-Json
    $pluginId = [string]$manifest.id
    $version = [string]$manifest.version
    $outputDir = Join-Path $registryRoot ("plugins/{0}/{1}" -f $pluginId, $version)
    $outputFile = Join-Path $outputDir ("{0}.tinaplug" -f $pluginId)

    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    New-TinaPlugArchive -SourceDir $sourceDir -OutputFile $outputFile

    $archive = Get-Item -LiteralPath $outputFile
    $pluginEntries += [ordered]@{
        id = $pluginId
        plugin_id = $pluginId
        name = [string]$manifest.name
        description = [string]$manifest.description
        category = [string]$item.category
        tags = @($item.tags)
        repository_url = [string]$item.repository_url
        homepage_url = [string]$item.homepage_url
        license = [string]$item.license
        publisher = [ordered]@{
            id = [string]$item.publisher.id
            display_name = [string]$item.publisher.display_name
        }
        versions = @(
            [ordered]@{
                version = $version
                version_code = ConvertTo-VersionCode $version
                file_size = $archive.Length
                file_hash = "sha256:{0}" -f (Get-FileSha256 $archive.FullName)
                download_url = "plugins/{0}/{1}/{0}.tinaplug" -f $pluginId, $version
                changelog = [string]$item.changelog
                created_at = [string]$item.updated_at
            }
        )
        created_at = [string]$item.created_at
        updated_at = [string]$item.updated_at
    }
}

$pluginsIndex = [ordered]@{
    plugins = @($pluginEntries)
}
Write-Utf8NoBom `
    -Path (Join-Path $registryRoot "plugins/index.json") `
    -Content (ConvertTo-JsonText $pluginsIndex)

$packageMetadata = Get-Content -Raw -Encoding UTF8 (Join-Path $registryRoot "metadata/packages.json") |
    ConvertFrom-Json

$packageEntries = @()
$versionMap = [ordered]@{}
foreach ($pkg in @($packageMetadata.packages)) {
    $filePath = Join-Path $registryRoot $pkg.file
    if (-not (Test-Path -LiteralPath $filePath)) {
        throw "Package file not found: $filePath"
    }

    $file = Get-Item -LiteralPath $filePath
    $checksum = "sha256:{0}" -f (Get-FileSha256 $file.FullName)
    $packageEntries += [ordered]@{
        id = [string]$pkg.id
        name = [string]$pkg.name
        description = [string]$pkg.description
        category = [string]$pkg.category
        homepage = [string]$pkg.homepage
        android = [ordered]@{
            version = [string]$pkg.android.version
            install_type = [string]$pkg.android.install_type
            size = $file.Length
            download_url = [string]$pkg.file
            checksum = $checksum
            abi = @($pkg.android.abi)
            is_latest = [bool]$pkg.android.is_latest
            release_notes = [string]$pkg.android.release_notes
        }
    }
    $versionMap[[string]$pkg.id] = [ordered]@{
        android = @(
            [ordered]@{
                id = 2
                package_id = [string]$pkg.id
                platform = "android"
                version = [string]$pkg.android.version
                install_type = [string]$pkg.android.install_type
                download_size = $file.Length
                download_url = [string]$pkg.file
                checksum = $checksum
                abi = @($pkg.android.abi)
                is_latest = [bool]$pkg.android.is_latest
                release_notes = [string]$pkg.android.release_notes
            }
        )
    }
}

$packageCategories = @($packageMetadata.categories | ForEach-Object {
    [ordered]@{
        id = [string]$_.id
        name = [string]$_.name
        name_en = [string]$_.name_en
        sort_order = [int]$_.sort_order
    }
})

$packagesIndex = [ordered]@{
    categories = @($packageCategories)
    packages = @($packageEntries)
    versions = $versionMap
    downloads = [ordered]@{}
}
Write-Utf8NoBom `
    -Path (Join-Path $registryRoot "packages/index.json") `
    -Content (ConvertTo-JsonText $packagesIndex)

Write-Host "Registry indexes rebuilt."
