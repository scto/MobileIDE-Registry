# TinaIDE Registry
简体中文
Aifadian - Support Open Source
## Registry v2 Index
The current Registry defaults to publishing only v2 lightweight indices and individual detail files:
```text
plugins/index.v2.json
plugins/<plugin-id>/plugin.json
packages/index.v2.json
packages/<package-id>/package.json

```
The Android client prioritizes reading index.v2.json. The list page only downloads lightweight summaries;
When opening details, installing plugins, checking for updates, or installing dependency packages, it reads individual
plugin.json / package.json files on demand. The Android main branch has removed the old index.json
fallback; if the v2 file does not exist, the request fails, or parsing fails, Registry publishing issues will be directly exposed.
scripts/build-registry.ps1 generates v2-only artifacts by default; if it is absolutely necessary to serve older clients,
you can explicitly add -IncludeLegacyV1 to generate plugins/index.json / packages/index.json.
scripts/validate-registry.ps1 requires by default that the old v1 index does not exist, and validates v2's
detail_url, detail files, download files, hashes, and lightweight field boundaries.
## Protocol Lifecycle
v2 is the current main protocol. The old v1 full index is only applicable to historical clients and is no longer generated, validated, or published by default.
 * 0.17.11: The Android client introduces prioritized reading of v2 and marks the v1 fallback as a deprecated compatibility layer.
 * 0.18.x / 0.19.x: Migration window, the Registry continues to generate both v2 and v1 artifacts.
 * From 0.20.0 onwards: The Android client removes the v1 fallback code;
   the Registry stops generating plugins/index.json / packages/index.json by default.
   If temporary compatibility with older clients is needed, you can use build-registry.ps1 -IncludeLegacyV1 and
   validate-registry.ps1 -AllowLegacyV1.
## Android Package Artifact Rules
Android dependency packages are published as "one library, one logical package" and are not split into different package IDs like -arm64 / -x86_64.
Package content and device compatibility are expressed through metadata:
 * artifact_type can be source, header, static, shared, executable, or mixed.
 * source and header packages cannot declare abi.
 * static, shared, and executable packages must declare abi.
 * A single package can contain multiple ABI directories simultaneously, such as lib/arm64-v8a/ and lib/x86_64/.
 * The Android client will intercept and block downloads if the abi does not match the current device.
Public Registry for the TinaIDE plugin market and dependency package market.
Clients read sequentially by default:
```text
[https://raw.githubusercontent.com/wuxianggujun/TinaIDE-Registry/main](https://raw.githubusercontent.com/wuxianggujun/TinaIDE-Registry/main)
[https://cdn.jsdelivr.net/gh/wuxianggujun/TinaIDE-Registry@main](https://cdn.jsdelivr.net/gh/wuxianggujun/TinaIDE-Registry@main)

```
## Directory Structure
```text
plugins/index.v2.json                      # Plugin market v2 lightweight index
plugins/<plugin-id>/plugin.json            # Individual plugin details and version history
plugins/<plugin-id>/<version>/*.tinaplug   # Plugin release package
packages/index.v2.json                     # Dependency package market v2 lightweight index
packages/<package-id>/package.json         # Individual dependency package details, version, and download info
packages/<package-id>/<version>/* # Dependency package release files
sources/plugins/** # Official plugin source code or complete packaging directory
sources/plugin-starters/** # Plugin starter source templates and validation/packaging scripts
metadata/*.json                            # Metadata used to generate indices
scripts/*.ps1                              # Registry build scripts
.github/workflows/*.yml                    # Registry validation and publishing automation

```
## Building the Index
```powershell
pwsh ./scripts/build-registry.ps1

```
This script will:
 * Rebuild the official plugin starter zips.
 * Package sources/plugins/** into .tinaplug files.
 * Calculate the sha256 and file size for plugin packages and dependency packages.
 * Rewrite plugins/index.v2.json, packages/index.v2.json, and the detail files.
 * Remove the old plugins/index.json / packages/index.json by default; if compatibility with older clients is needed,
   explicitly add -IncludeLegacyV1.
## Validating the Index
```powershell
pwsh ./scripts/validate-registry.ps1

```
This script will rebuild the Registry and validate that:
 * Plugin IDs, package IDs, and version numbers cannot be duplicated.
 * The .tinaplug root directory must contain a manifest.json.
 * The detail_url in plugins/index.v2.json / packages/index.v2.json must point to real detail files.
 * V2 lightweight indices must not mix in heavy fields like download URLs, checksums, or release notes.
 * The size and sha256 of plugin packages and dependency packages in the detail files must match the actual files.
 * Generation of the old plugins/index.json / packages/index.json is prohibited by default.
 * No uncommitted artifact differences can be left after building.
## GitHub Actions
 * Validate Registry: Runs on main pushes, PRs, and manual triggers to rebuild and validate the index; it will fail immediately if artifacts are not committed.
 * Publish Registry: Manually triggered for publishing. It rebuilds and validates the Registry, automatically commits artifacts if necessary, and then creates a registry-yyyyMMdd-HHmmss tag and GitHub Release. The Release will additionally upload individual plugin packages, individual dependency packages, v2 lightweight indices, and detail files; the Source code zip automatically generated by GitHub is only used for source snapshots, not for market downloads.
## Publishing Rules
 * Plugin release content is placed in sources/plugins/<plugin-id>/, and the root directory must contain manifest.json.
 * Dependency package release files are placed in packages/<package-id>/<version>/.
 * Large files do not need to be placed in this repository, but an absolute URL to a trusted CDN, object storage, or self-hosted proxy must be provided in the index.
 * Do not place Android client source code, backend code, databases, or admin panels into this repository.
## Support the Project
This project is open-source and free long-term, but continuous development, testing, document maintenance, and device adaptation require time and resources.
If it has saved you time, you are welcome to support my continued maintenance via Aifadian:
Support Wuxiang Gujun to continue open source
Your support will be prioritized for:
 * Fixing issues and maintaining stable versions.
 * Supplementing documentation, tutorials, and examples.
 * Maintaining build environments, test devices, and related services.
 * Driving long-term updates for more practical tools.
