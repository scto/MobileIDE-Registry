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

function Get-Crc32 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    if ($null -eq $script:Crc32Table) {
        $mask = [uint64]4294967295
        $polynomial = [uint64]3988292384
        $script:Crc32Table = @(for ($i = 0; $i -lt 256; $i++) {
            $crc = [uint32]$i
            for ($bit = 0; $bit -lt 8; $bit++) {
                if (($crc -band 1) -ne 0) {
                    $crc = [uint32]((([uint64]$crc -shr 1) -bxor $polynomial) -band $mask)
                } else {
                    $crc = [uint32](([uint64]$crc -shr 1) -band $mask)
                }
            }
            $crc
        })
    }

    $mask = [uint64]4294967295
    $value = [uint32]4294967295
    foreach ($byte in $Bytes) {
        $index = [int](($value -bxor [uint32]$byte) -band 0xFF)
        $value = [uint32]((([uint64]$value -shr 8) -bxor [uint64]$script:Crc32Table[$index]) -band $mask)
    }
    return [uint32](([uint64]$value -bxor $mask) -band $mask)
}

function New-DeterministicZip {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$OutputFile
    )

    if (Test-Path -LiteralPath $OutputFile) {
        Remove-Item -LiteralPath $OutputFile -Force
    }

    $sourcePath = (Resolve-Path -LiteralPath $SourceDir).Path
    $entries = Get-ChildItem -LiteralPath $sourcePath -File -Recurse -Force |
        ForEach-Object {
            [pscustomobject]@{
                File = $_
                RelativePath = Get-ArchiveRelativePath -BasePath $sourcePath -FilePath $_.FullName
            }
        } |
        Sort-Object -Property RelativePath

    $outputParent = Split-Path -Parent $OutputFile
    if ($outputParent) {
        New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
    }

    $stream = [System.IO.File]::Open($OutputFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    $writer = [System.IO.BinaryWriter]::new($stream, [System.Text.Encoding]::UTF8)
    $centralRecords = @()
    $dosTime = [uint16]0
    $dosDate = [uint16]0x5021
    $utf8Flag = [uint16]0x0800
    try {
        foreach ($entry in $entries) {
            $data = [System.IO.File]::ReadAllBytes($entry.File.FullName)
            $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($entry.RelativePath)
            $crc = Get-Crc32 -Bytes $data
            $size = [uint32]$data.Length
            $offset = [uint32]$stream.Position

            $writer.Write([uint32]0x04034B50)
            $writer.Write([uint16]20)
            $writer.Write($utf8Flag)
            $writer.Write([uint16]0)
            $writer.Write($dosTime)
            $writer.Write($dosDate)
            $writer.Write($crc)
            $writer.Write($size)
            $writer.Write($size)
            $writer.Write([uint16]$nameBytes.Length)
            $writer.Write([uint16]0)
            $writer.Write($nameBytes)
            $writer.Write($data)

            $centralRecords += [pscustomobject]@{
                NameBytes = $nameBytes
                Crc = $crc
                Size = $size
                Offset = $offset
            }
        }

        $centralOffset = [uint32]$stream.Position
        foreach ($record in $centralRecords) {
            $writer.Write([uint32]0x02014B50)
            $writer.Write([uint16]20)
            $writer.Write([uint16]20)
            $writer.Write($utf8Flag)
            $writer.Write([uint16]0)
            $writer.Write($dosTime)
            $writer.Write($dosDate)
            $writer.Write([uint32]$record.Crc)
            $writer.Write([uint32]$record.Size)
            $writer.Write([uint32]$record.Size)
            $writer.Write([uint16]$record.NameBytes.Length)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint32]0)
            $writer.Write([uint32]$record.Offset)
            $writer.Write([byte[]]$record.NameBytes)
        }
        $centralSize = [uint32]($stream.Position - $centralOffset)
        $entryCount = [uint16]$centralRecords.Count

        $writer.Write([uint32]0x06054B50)
        $writer.Write([uint16]0)
        $writer.Write([uint16]0)
        $writer.Write($entryCount)
        $writer.Write($entryCount)
        $writer.Write($centralSize)
        $writer.Write($centralOffset)
        $writer.Write([uint16]0)
    } finally {
        $writer.Dispose()
        $stream.Dispose()
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
