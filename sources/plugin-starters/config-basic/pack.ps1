$root = (Resolve-Path (Split-Path -Parent $MyInvocation.MyCommand.Path)).Path
$validateScript = Join-Path $root "validate.ps1"

& $validateScript
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$manifest = Get-Content (Join-Path $root "manifest.json") -Raw | ConvertFrom-Json
$distDir = Join-Path $root "dist"
$stagingDir = Join-Path $root ".pack"
$outFile = Join-Path $distDir ("{0}-{1}.tinaplug" -f $manifest.id, $manifest.version)

if (Test-Path $stagingDir) {
    Remove-Item $stagingDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

Get-ChildItem $root -Force | Where-Object {
    $_.Name -notin @(
        "dist",
        ".pack",
        ".tina-starter",
        "README.md",
        "pack.ps1",
        "pack.sh",
        "validate.ps1",
        "validate.sh"
    )
} | ForEach-Object {
    Copy-Item $_.FullName -Destination $stagingDir -Recurse -Force
}

if (Test-Path $outFile) {
    Remove-Item $outFile -Force
}

Compress-Archive -Path (Join-Path $stagingDir "*") -DestinationPath $outFile
Remove-Item $stagingDir -Recurse -Force
Write-Host "Packed to $outFile"
