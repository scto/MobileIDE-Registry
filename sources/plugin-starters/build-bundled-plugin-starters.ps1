$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$outputRoot = Join-Path $repoRoot "sources/plugins/tinaide.plugin.starters/templates"
$sharedRoot = Join-Path $PSScriptRoot "shared"
$stagingRoot = Join-Path $PSScriptRoot ".bundle"

$templates = @(
    @{ Name = "config-basic"; Output = "tina-config-plugin.zip" },
    @{ Name = "script-command"; Output = "tina-script-command-plugin.zip" },
    @{ Name = "script-basic"; Output = "tina-script-plugin.zip" },
    @{ Name = "lsp-basic"; Output = "tina-lsp-plugin.zip" }
)

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

function New-DeterministicZip {
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
                $entry = $zip.CreateEntry($relativePath, [System.IO.Compression.CompressionLevel]::Optimal)
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

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
if (Test-Path $stagingRoot) {
    Remove-Item $stagingRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

foreach ($template in $templates) {
    $sourceDir = Join-Path $PSScriptRoot $template.Name
    $outputZip = Join-Path $outputRoot $template.Output
    $validateScript = Join-Path $sourceDir "validate.ps1"
    $stagingDir = Join-Path $stagingRoot $template.Name

    & $validateScript
    if ($LASTEXITCODE -ne 0) {
        throw "Starter validation failed: $($template.Name)"
    }

    if (Test-Path $stagingDir) {
        Remove-Item $stagingDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

    Get-ChildItem $sourceDir -Force | Where-Object {
        $_.Name -notin @("dist", ".pack", ".bundle")
    } | ForEach-Object {
        Copy-Item $_.FullName -Destination $stagingDir -Recurse -Force
    }

    $starterSupportDir = Join-Path $stagingDir ".tina-starter"
    New-Item -ItemType Directory -Force -Path $starterSupportDir | Out-Null
    Copy-Item (Join-Path $sharedRoot "validate-core.ps1") -Destination $starterSupportDir -Force
    Copy-Item (Join-Path $sharedRoot "validate_core.py") -Destination $starterSupportDir -Force
    Copy-Item (Join-Path $sharedRoot "validation-rules.json") -Destination $starterSupportDir -Force

    New-DeterministicZip -SourceDir $stagingDir -OutputFile $outputZip
    Write-Host "Built $outputZip"
}

Remove-Item $stagingRoot -Recurse -Force
