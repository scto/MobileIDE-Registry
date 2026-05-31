$ErrorActionPreference = "Stop"

$registryRoot = Split-Path -Parent $PSScriptRoot
$starterRoot = Join-Path $registryRoot "sources/plugin-starters"
$buildScript = Join-Path $starterRoot "build-bundled-plugin-starters.ps1"

& $buildScript
