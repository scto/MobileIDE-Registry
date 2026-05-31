$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$candidates = @(
    (Join-Path $root ".tina-starter/validate-core.ps1"),
    (Join-Path (Split-Path -Parent $root) "shared/validate-core.ps1")
) | Select-Object -Unique

$runner = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $runner) {
    throw "Cannot find starter validation core."
}

& $runner -PluginRoot $root
exit $LASTEXITCODE
