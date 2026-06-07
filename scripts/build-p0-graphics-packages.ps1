param(
    [string]$OutputRoot = "",
    [string]$WorkRoot = "",
    [string]$AndroidSdkRoot = "",
    [string]$AndroidNdkRoot = "",
    [string]$CMakePath = "",
    [string]$NinjaPath = "",
    [string]$Sdl3PackageArchive = "",
    [switch]$SkipExisting
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$registryRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputRoot) {
    $OutputRoot = Join-Path $registryRoot "packages"
}
if (-not $WorkRoot) {
    $runId = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss", [System.Globalization.CultureInfo]::InvariantCulture)
    $WorkRoot = Join-Path $registryRoot ".build\p0-graphics-packages\$runId"
}
if (-not $Sdl3PackageArchive) {
    $Sdl3PackageArchive = Join-Path $registryRoot "packages\sdl3\3.5.0\sdl3.tar.xz"
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($Path, $normalized, $encoding)
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = ""
    )

    if ($WorkingDirectory) {
        & $FilePath @Arguments 1>$null
    } else {
        & $FilePath @Arguments 1>$null
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $FilePath $($Arguments -join ' ')"
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = ""
    )

    if ($WorkingDirectory) {
        & git -C $WorkingDirectory @Arguments 1>$null
    } else {
        & git @Arguments 1>$null
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git failed: git $($Arguments -join ' ')"
    }
}

function Get-VersionSortKey {
    param([Parameter(Mandatory = $true)][string]$Name)

    $parts = [regex]::Split($Name, "[^0-9]+") |
        Where-Object { $_ -ne "" } |
        ForEach-Object { [int]$_ }
    while ($parts.Count -lt 4) {
        $parts += 0
    }
    return "{0:D6}.{1:D6}.{2:D6}.{3:D6}" -f $parts[0], $parts[1], $parts[2], $parts[3]
}

function Resolve-AndroidSdkRoot {
    if ($AndroidSdkRoot) {
        return (Resolve-Path -LiteralPath $AndroidSdkRoot).Path
    }

    foreach ($candidate in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, "D:\Programs\Android\Sdk", (Join-Path $env:LOCALAPPDATA "Android\Sdk"))) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Container)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw "Android SDK not found. Pass -AndroidSdkRoot."
}

function Resolve-AndroidNdkRoot {
    param([Parameter(Mandatory = $true)][string]$SdkRoot)

    if ($AndroidNdkRoot) {
        return (Resolve-Path -LiteralPath $AndroidNdkRoot).Path
    }

    $ndkRoot = Join-Path $SdkRoot "ndk"
    $candidate = Get-ChildItem -LiteralPath $ndkRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object @{ Expression = { Get-VersionSortKey $_.Name } } -Descending |
        Select-Object -First 1
    if ($null -eq $candidate) {
        throw "Android NDK not found under $ndkRoot. Pass -AndroidNdkRoot."
    }
    return $candidate.FullName
}

function Resolve-CMakeExe {
    param([Parameter(Mandatory = $true)][string]$SdkRoot)

    if ($CMakePath) {
        return (Resolve-Path -LiteralPath $CMakePath).Path
    }

    $cmakeRoot = Join-Path $SdkRoot "cmake"
    $candidate = Get-ChildItem -LiteralPath $cmakeRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object @{ Expression = { Get-VersionSortKey $_.Name } } -Descending |
        ForEach-Object { Join-Path $_.FullName "bin\cmake.exe" } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if ($candidate) {
        return $candidate
    }

    $command = Get-Command cmake -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    throw "cmake not found. Pass -CMakePath."
}

function Resolve-NinjaExe {
    param([Parameter(Mandatory = $true)][string]$SdkRoot)

    if ($NinjaPath) {
        return (Resolve-Path -LiteralPath $NinjaPath).Path
    }

    $cmakeRoot = Join-Path $SdkRoot "cmake"
    $candidate = Get-ChildItem -LiteralPath $cmakeRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object @{ Expression = { Get-VersionSortKey $_.Name } } -Descending |
        ForEach-Object { Join-Path $_.FullName "bin\ninja.exe" } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if ($candidate) {
        return $candidate
    }

    $command = Get-Command ninja -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    throw "ninja not found. Pass -NinjaPath."
}

function Get-UpstreamSource {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $sourceDir = Join-Path $Root $Package.Id
    if (-not (Test-Path -LiteralPath (Join-Path $sourceDir ".git"))) {
        Invoke-Git -Arguments @("clone", "--depth", "1", "--branch", $Package.Ref, $Package.Repository, $sourceDir)
    } else {
        Invoke-Git -Arguments @("fetch", "--depth", "1", "origin", $Package.Ref) -WorkingDirectory $sourceDir
        Invoke-Git -Arguments @("checkout", "--detach", "FETCH_HEAD") -WorkingDirectory $sourceDir
    }

    $actualCommit = (& git -C $sourceDir rev-parse HEAD).Trim()
    if ($actualCommit -ne $Package.Commit) {
        throw "Unexpected commit for $($Package.Id): expected=$($Package.Commit) actual=$actualCommit"
    }

    foreach ($submodule in @($Package.Submodules)) {
        Invoke-Git -Arguments @("submodule", "update", "--init", "--depth", "1", $submodule) -WorkingDirectory $sourceDir
    }
    return $sourceDir
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        throw "Required directory not found: $SourcePath"
    }
    New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null
    Get-ChildItem -LiteralPath $SourcePath -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $DestinationPath -Recurse -Force
    }
}

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Required file not found: $SourcePath"
    }
    $parent = Split-Path -Parent $DestinationPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
}

function Write-PkgConfigFile {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [string]$Libs = "",
        [string]$Requires = ""
    )

    $requiresLine = if ($Requires) { "Requires: $Requires`n" } else { "" }
    $libsLine = if ($Libs) { "Libs: $Libs`n" } else { "" }
    $content = @"
prefix=$Prefix
includedir=`${prefix}/include
libdir=`${prefix}/lib

Name: $($Package.PkgConfigName)
Description: $($Package.Description)
Version: $($Package.Version)
$requiresLine$libsLine`Cflags: -I`${includedir}
"@

    Write-Utf8NoBom -Path $Path -Content ($content.TrimEnd() + [Environment]::NewLine)
}

function Write-PackageMetadata {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Abis = @()
    )

    $files = [ordered]@{
        include = "include"
    }
    if ($Package.ArtifactType -in @("static", "shared")) {
        $files.lib = "lib"
        $files.cmake = "lib/cmake/$($Package.CMakePackageName)"
        $files.pkgconfig = "lib/pkgconfig/$($Package.PkgConfigFile)"
    } else {
        $files.pkgconfig = "pkgconfig/$($Package.PkgConfigFile)"
    }

    $metadata = [ordered]@{
        id = $Package.Id
        name = $Package.Name
        version = $Package.Version
        packageRevision = 1
        upstreamName = $Package.UpstreamName
        upstreamVersion = $Package.Version
        upstreamTag = $Package.Ref
        upstreamCommit = $Package.Commit
        description = $Package.Description
        platform = "android"
        artifactType = $Package.ArtifactType
        installType = "download"
        category = "library"
        homepage = $Package.Homepage
        license = $Package.License
        files = $files
    }
    if ($Abis.Count -gt 0) {
        $metadata.abis = @($Abis)
    }
    if (@($Package.Dependencies).Count -gt 0) {
        $metadata.dependencies = @($Package.Dependencies)
    }

    Write-Utf8NoBom -Path $Path -Content (($metadata | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
}

function Write-BuildInfo {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Abis = @()
    )

    $dependencies = (@($Package.Dependencies) -join ",")
    $content = @"
package_id=$($Package.Id)
package_version=$($Package.Version)
package_revision=1
artifact_type=$($Package.ArtifactType)
upstream_tag=$($Package.Ref)
upstream_commit=$($Package.Commit)
upstream_version=$($Package.Version)
abis=$($Abis -join ",")
dependencies=$dependencies
"@
    Write-Utf8NoBom -Path $Path -Content $content
}

function Invoke-CMakePackageBuild {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$BuildDir,
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$CMakeExe,
        [Parameter(Mandatory = $true)][string]$NinjaExe,
        [Parameter(Mandatory = $true)][string]$NdkRoot,
        [string]$Sdl3Prefix = ""
    )

    New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
    $toolchainFile = (Join-Path $NdkRoot "build\cmake\android.toolchain.cmake").Replace("\", "/")
    $args = @(
        "-S", $SourceDir.Replace("\", "/"),
        "-B", $BuildDir.Replace("\", "/"),
        "-G", "Ninja",
        "-DCMAKE_MAKE_PROGRAM:FILEPATH=$($NinjaExe.Replace("\", "/"))",
        "-DCMAKE_TOOLCHAIN_FILE=$toolchainFile",
        "-DANDROID_ABI=arm64-v8a",
        "-DANDROID_PLATFORM=24",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_INSTALL_PREFIX=$($InstallDir.Replace("\", "/"))"
    )
    if ($Sdl3Prefix) {
        $args += "-DSDL3_DIR=$($Sdl3Prefix.Replace("\", "/"))/lib/cmake/SDL3"
    }
    foreach ($option in @($Package.CMakeOptions)) {
        $args += $option
    }

    & $CMakeExe @args
    if ($LASTEXITCODE -ne 0) {
        throw "CMake configure failed for $($Package.Id)"
    }
    & $CMakeExe --build $BuildDir.Replace("\", "/") --config Release
    if ($LASTEXITCODE -ne 0) {
        throw "CMake build failed for $($Package.Id)"
    }
    & $CMakeExe --install $BuildDir.Replace("\", "/") --config Release
    if ($LASTEXITCODE -ne 0) {
        throw "CMake install failed for $($Package.Id)"
    }
}

function New-PackageArchive {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )

    if (Test-Path -LiteralPath $ArchivePath) {
        throw "Archive already exists: $ArchivePath"
    }

    Push-Location $PackageRoot
    try {
        tar -caf $ArchivePath *
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create archive: $ArchivePath"
        }
    } finally {
        Pop-Location
    }

    $hash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "Built package: $ArchivePath"
    Write-Host "Package version: $($Package.Version)"
    Write-Host "Artifact type: $($Package.ArtifactType)"
    Write-Host "ABI: $($Package.Abi -join ',')"
    Write-Host "SHA256: $hash"
}

function Build-HeaderPackage {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$PackageRoot
    )

    Copy-RequiredFile -SourcePath (Join-Path $SourceDir "miniaudio.h") -DestinationPath (Join-Path $PackageRoot "include\miniaudio.h")
    Copy-RequiredFile -SourcePath (Join-Path $SourceDir "LICENSE") -DestinationPath (Join-Path $PackageRoot "LICENSE")
    New-Item -ItemType Directory -Force -Path (Join-Path $PackageRoot "pkgconfig") | Out-Null
    Write-PkgConfigFile `
        -Package $Package `
        -Path (Join-Path $PackageRoot "pkgconfig\$($Package.PkgConfigFile)") `
        -Prefix '${pcfiledir}/..'
    Write-PackageMetadata -Package $Package -Path (Join-Path $PackageRoot "package.json") -Abis @()
    Write-BuildInfo -Package $Package -Path (Join-Path $PackageRoot "BUILD-INFO.txt") -Abis @()
}

function Build-NativePackage {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$CMakeExe,
        [Parameter(Mandatory = $true)][string]$NinjaExe,
        [Parameter(Mandatory = $true)][string]$NdkRoot,
        [string]$Sdl3Prefix = ""
    )

    $buildDir = Join-Path $WorkRoot "build\$($Package.Id)-arm64-v8a"
    $installDir = Join-Path $WorkRoot "install\$($Package.Id)-arm64-v8a"
    Invoke-CMakePackageBuild `
        -Package $Package `
        -SourceDir $SourceDir `
        -BuildDir $buildDir `
        -InstallDir $installDir `
        -CMakeExe $CMakeExe `
        -NinjaExe $NinjaExe `
        -NdkRoot $NdkRoot `
        -Sdl3Prefix $Sdl3Prefix

    Copy-DirectoryContents -SourcePath $installDir -DestinationPath $PackageRoot
    $pkgConfigPath = Join-Path $PackageRoot "lib\pkgconfig\$($Package.PkgConfigFile)"
    if (Test-Path -LiteralPath $pkgConfigPath -PathType Leaf) {
        $requires = if (@($Package.Dependencies).Count -gt 0) { @($Package.Dependencies) -join " " } else { "" }
        Write-PkgConfigFile `
            -Package $Package `
            -Path $pkgConfigPath `
            -Prefix '${pcfiledir}/../..' `
            -Libs (("-L" + '${libdir}') + " -l$($Package.LinkName)") `
            -Requires $requires
    }

    $licenseSource = Join-Path $SourceDir $Package.LicensePath
    if (Test-Path -LiteralPath $licenseSource -PathType Leaf) {
        Copy-RequiredFile -SourcePath $licenseSource -DestinationPath (Join-Path $PackageRoot "LICENSE")
    }
    Write-PackageMetadata -Package $Package -Path (Join-Path $PackageRoot "package.json") -Abis @($Package.Abi)
    Write-BuildInfo -Package $Package -Path (Join-Path $PackageRoot "BUILD-INFO.txt") -Abis @($Package.Abi)
}

$sdkRoot = Resolve-AndroidSdkRoot
$ndkRoot = Resolve-AndroidNdkRoot -SdkRoot $sdkRoot
$cmakeExe = Resolve-CMakeExe -SdkRoot $sdkRoot
$ninjaExe = Resolve-NinjaExe -SdkRoot $sdkRoot

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$WorkRoot = (Resolve-Path -LiteralPath $WorkRoot).Path
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path

if (-not (Test-Path -LiteralPath $Sdl3PackageArchive -PathType Leaf)) {
    throw "SDL3 package archive not found: $Sdl3PackageArchive"
}
$sdl3Prefix = Join-Path $WorkRoot "sdl3-prefix"
New-Item -ItemType Directory -Force -Path $sdl3Prefix | Out-Null
tar -xf $Sdl3PackageArchive -C $sdl3Prefix
if ($LASTEXITCODE -ne 0) {
    throw "Failed to extract SDL3 package: $Sdl3PackageArchive"
}

$packages = @(
    [pscustomobject]@{
        Id = "sdl3-image"
        Name = "SDL3_image"
        UpstreamName = "SDL_image"
        Version = "3.4.4"
        Repository = "https://github.com/libsdl-org/SDL_image.git"
        Ref = "release-3.4.4"
        Commit = "bec9134a26c7d0f31b36d6083c25296e04cabff5"
        ArtifactType = "shared"
        Abi = @("arm64-v8a")
        Description = "Image loading library for SDL3 with lightweight built-in backends"
        Homepage = "https://github.com/libsdl-org/SDL_image"
        License = "Zlib"
        LicensePath = "LICENSE.txt"
        PkgConfigName = "sdl3-image"
        PkgConfigFile = "sdl3-image.pc"
        CMakePackageName = "SDL3_image"
        LinkName = "SDL3_image"
        Dependencies = @("sdl3")
        Submodules = @()
        CMakeOptions = @(
            "-DBUILD_SHARED_LIBS=ON",
            "-DSDLIMAGE_INSTALL=ON",
            "-DSDLIMAGE_SAMPLES=OFF",
            "-DSDLIMAGE_TESTS=OFF",
            "-DSDLIMAGE_VENDORED=ON",
            "-DSDLIMAGE_DEPS_SHARED=OFF",
            "-DSDLIMAGE_AVIF=OFF",
            "-DSDLIMAGE_JXL=OFF",
            "-DSDLIMAGE_TIF=OFF",
            "-DSDLIMAGE_WEBP=OFF",
            "-DSDLIMAGE_PNG_LIBPNG=OFF"
        )
    },
    [pscustomobject]@{
        Id = "sdl3-ttf"
        Name = "SDL3_ttf"
        UpstreamName = "SDL_ttf"
        Version = "3.2.2"
        Repository = "https://github.com/libsdl-org/SDL_ttf.git"
        Ref = "release-3.2.2"
        Commit = "a1ce3670aec736ecbf0936c43f2f0cc53aa61e5b"
        ArtifactType = "shared"
        Abi = @("arm64-v8a")
        Description = "TrueType font rendering library for SDL3 using vendored FreeType"
        Homepage = "https://github.com/libsdl-org/SDL_ttf"
        License = "Zlib"
        LicensePath = "LICENSE.txt"
        PkgConfigName = "sdl3-ttf"
        PkgConfigFile = "sdl3-ttf.pc"
        CMakePackageName = "SDL3_ttf"
        LinkName = "SDL3_ttf"
        Dependencies = @("sdl3")
        Submodules = @("external/freetype")
        CMakeOptions = @(
            "-DBUILD_SHARED_LIBS=ON",
            "-DSDLTTF_INSTALL=ON",
            "-DSDLTTF_SAMPLES=OFF",
            "-DSDLTTF_VENDORED=ON",
            "-DSDLTTF_HARFBUZZ=OFF",
            "-DSDLTTF_PLUTOSVG=OFF"
        )
    },
    [pscustomobject]@{
        Id = "box2d"
        Name = "Box2D"
        UpstreamName = "Box2D"
        Version = "3.1.1"
        Repository = "https://github.com/erincatto/box2d.git"
        Ref = "v3.1.1"
        Commit = "8c661469c9507d3ad6fbd2fea3f1aa71669c2fe3"
        ArtifactType = "static"
        Abi = @("arm64-v8a")
        Description = "2D physics engine for games"
        Homepage = "https://box2d.org/"
        License = "MIT"
        LicensePath = "LICENSE"
        PkgConfigName = "box2d"
        PkgConfigFile = "box2d.pc"
        CMakePackageName = "box2d"
        LinkName = "box2d"
        Dependencies = @()
        Submodules = @()
        CMakeOptions = @(
            "-DBUILD_SHARED_LIBS=OFF",
            "-DBOX2D_SAMPLES=OFF",
            "-DBOX2D_UNIT_TESTS=OFF",
            "-DBOX2D_BENCHMARKS=OFF",
            "-DBOX2D_DOCS=OFF"
        )
    },
    [pscustomobject]@{
        Id = "miniaudio"
        Name = "miniaudio"
        UpstreamName = "miniaudio"
        Version = "0.11.25"
        Repository = "https://github.com/mackron/miniaudio.git"
        Ref = "0.11.25"
        Commit = "9634bedb5b5a2ca38c1ee7108a9358a4e233f14d"
        ArtifactType = "header"
        Abi = @()
        Description = "Single-file audio playback and capture library"
        Homepage = "https://miniaud.io/"
        License = "MIT OR Unlicense"
        LicensePath = "LICENSE"
        PkgConfigName = "miniaudio"
        PkgConfigFile = "miniaudio.pc"
        CMakePackageName = ""
        LinkName = ""
        Dependencies = @()
        Submodules = @()
        CMakeOptions = @()
    }
)

foreach ($package in $packages) {
    $archiveDir = Join-Path $OutputRoot "$($package.Id)\$($package.Version)"
    $archivePath = Join-Path $archiveDir "$($package.Id).tar.xz"
    if ($SkipExisting -and (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        Write-Host "Skipping existing package: $archivePath"
        continue
    }

    $sourceDir = Get-UpstreamSource -Package $package -Root (Join-Path $WorkRoot "upstreams")
    $packageRoot = Join-Path $WorkRoot "packages\$($package.Id)-$($package.Version)"
    if (Test-Path -LiteralPath $packageRoot) {
        throw "Package work directory already exists: $packageRoot"
    }
    New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null

    if ($package.ArtifactType -eq "header") {
        Build-HeaderPackage -Package $package -SourceDir $sourceDir -PackageRoot $packageRoot
    } else {
        $sdlDependencyPrefix = if (@($package.Dependencies) -contains "sdl3") { $sdl3Prefix } else { "" }
        Build-NativePackage `
            -Package $package `
            -SourceDir $sourceDir `
            -PackageRoot $packageRoot `
            -CMakeExe $cmakeExe `
            -NinjaExe $ninjaExe `
            -NdkRoot $ndkRoot `
            -Sdl3Prefix $sdlDependencyPrefix
    }

    New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null
    New-PackageArchive -Package $package -PackageRoot $packageRoot -ArchivePath $archivePath
}
