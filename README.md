# TinaIDE Registry
简体中文 | Aifadian - Support Open Source
Public Registry for the **TinaIDE** plugin market and dependency package market.
## Registry v2 Index
The current Registry defaults to publishing only **v2 lightweight indices** and individual detail files:
 * plugins/index.v2.json
 * plugins/<plugin-id>/plugin.json
 * packages/index.v2.json
 * packages/<package-id>/package.json
### Client Behavior & Fallback
 * **Prioritization:** The Android client prioritizes reading index.v2.json.
 * **On-Demand Loading:** The list page only downloads lightweight summaries. When opening details, installing plugins, checking for updates, or installing dependency packages, it reads individual plugin.json / package.json files on demand.
 * **V1 Deprecation:** The Android main branch has removed the old index.json fallback. If the v2 file does not exist, or if the request/parsing fails, Registry publishing issues will be directly exposed.
 * **Legacy Support:** * scripts/build-registry.ps1 generates v2-only artifacts by default. To serve older clients, explicitly append -IncludeLegacyV1 to generate plugins/index.json / packages/index.json.
   * scripts/validate-registry.ps1 asserts by default that the old v1 index does not exist, and validates v2's detail_url, detail files, download files, hashes, and lightweight field boundaries.
## Protocol Lifecycle
The v2 protocol is the active main protocol. The legacy v1 full index is deprecated and no longer generated, validated, or published by default.

| Version | Status / Actions |
| :--- | :--- |
| **0.17.11** | Android client introduces prioritized reading of v2; marks the v1 fallback as a deprecated compatibility layer. |
| **0.18.x / 0.19.x** | **Migration Window:** The Registry continues to generate both v2 and v1 artifacts. |
| **0.20.0+** | Android client removes v1 fallback code; Registry stops generating plugins/index.json / packages/index.json by default. *(To override, use -IncludeLegacyV1 and -AllowLegacyV1 flags).* |

## Android Package Artifact Rules
Android dependency packages are published under the **"one library, one logical package"** rule. They are not split into separate package IDs based on CPU architectures (e.g., -arm64 / -x86_64). Instead, compatibility and package contents are detailed via metadata:
 * **artifact_type** can be: source, header, static, shared, executable, or mixed.
 * **No ABI Restriction:** source and header packages **cannot** declare abi.
 * **Required ABI:** static, shared, and executable packages **must** declare abi.
 * **Multi-ABI Support:** A single package can contain multiple ABI directories simultaneously (e.g., lib/arm64-v8a/ and lib/x86_64/).
 * **Download Guard:** The Android client automatically intercepts and blocks downloads if the package's declared abi does not match the host device.
### 💡 Kotlin Integration Note
For Kotlin/Android developers, the package metadata can be parsed into the following model structure:
```kotlin
enum class ArtifactType {
    SOURCE, HEADER, STATIC, SHARED, EXECUTABLE, MIXED
}
data class DependencyPackage(
    val id: String,
    val version: String,
    val artifactType: ArtifactType,
    val abi: List<String>?, // Null for SOURCE/HEADER
    val detailUrl: String,
    val sha256: String,
    val fileSize: Long
)
```
## Directory Structure
Clients sequentially read the registry from the following base URLs by default:
 1. https://raw.githubusercontent.com/wuxianggujun/TinaIDE-Registry/main
 2. https://cdn.jsdelivr.net/gh/wuxianggujun/TinaIDE-Registry@main
```text
TinaIDE-Registry/
├── plugins/
│   ├── index.v2.json                     # Plugin market v2 lightweight index
│   └── <plugin-id>/
│       ├── plugin.json                   # Individual plugin details and version history
│       └── <version>/*.tinaplug          # Plugin release package
├── packages/
│   ├── index.v2.json                     # Dependency package market v2 lightweight index
│   └── <package-id>/
│       ├── package.json                  # Individual package details & download info
│       └── <version>/* # Dependency package release files
├── sources/
│   ├── plugins/** # Official plugin source code / packaging dirs
│   └── plugin-starters/** # Plugin starter templates & validation scripts
├── metadata/
│   └── *.json                            # Metadata source used to generate indices
├── scripts/
│   └── *.ps1                             # Powershell build and validation scripts
└── .github/
    └── workflows/
        └── *.yml                         # Registry validation & publishing automation
```
## CLI Reference & Scripts
### Building the Index
Run the following PowerShell command to compile the registry artifacts:
```powershell
pwsh ./scripts/build-registry.ps1
```
**What this script does:**
 1. Rebuilds the official plugin starter .zip files.
 2. Packages directories under sources/plugins/** into .tinaplug files.
 3. Automatically calculates sha256 checksums and file sizes for all plugins and dependency packages.
 4. Rewrites plugins/index.v2.json, packages/index.v2.json, and all associated detail files.
 5. Cleans up old plugins/index.json and packages/index.json by default (unless -IncludeLegacyV1 is specified).
### Validating the Index
Always run validation prior to committing changes:
```powershell
pwsh ./scripts/validate-registry.ps1
```
**The validation script asserts that:**
 * Plugin IDs, package IDs, and version numbers are strictly unique.
 * Every .tinaplug package contains a valid manifest.json in its root folder.
 * The detail_url in both index files resolves to a valid, reachable details file.
 * Lightweight v2 indices do **not** contain heavy fields (such as download URLs, checksums, or changelogs).
 * Sizes and SHA-256 hashes inside detail files exactly match the actual binary artifacts.
 * Legacy v1 files are not generated (fails by default unless -AllowLegacyV1 is set).
 * The working directory has no uncommitted artifact changes after compiling.
## CI/CD Workflow (GitHub Actions)
 * **Validate Registry:** Executes automatically on pushes to main, Pull Requests, and manual workflow dispatches. Rebuilds and verifies integrity. If built artifacts are out-of-sync with committed files, the workflow fails immediately.
 * **Publish Registry:** Manually triggered workflow for releases. It rebuilds and validates the registry, auto-commits any artifact changes if needed, and creates a git tag following the registry-yyyyMMdd-HHmmss format alongside a GitHub Release.
   > ⚠️ **Note:** The Release interface additionally uploads individual packages, indices, and detail files. The automated source zip generated by GitHub should only be used as a source snapshot, not for client-facing market downloads.
   > 
## Publishing Rules
 1. **Plugins:** Source code or complete packaging structures must be placed in sources/plugins/<plugin-id>/. The root directory must contain a manifest.json.
 2. **Dependency Packages:** Release binaries and files must be placed under packages/<package-id>/<version>/.
 3. **Large Files:** Do not commit excessively large binaries to this repository. Provide an absolute URL pointing to a trusted CDN, object storage, or a self-hosted proxy inside the metadata instead.
 4. **Scope Constraint:** Under no circumstances should Android client source code, backend APIs, databases, or administration dashboards be committed to this repository.
## Support the Project
This project is open-source and free long-term. However, continuous development, rigorous testing, updating documentation, and device adaptation require considerable time and resources.
If this project has saved you time, please consider supporting the ongoing maintenance via Aifadian:
👉 **Support Wuxiang Gujun on Aifadian**
### Funding Allocation Priority:
 * Fixing critical issues and ensuring stability in releases.
 * Creating comprehensive tutorials, practical examples, and better documentation.
 * Maintaining build infrastructure, testing devices, and supplementary services.
 * Researching and implementing new, highly requested features.
