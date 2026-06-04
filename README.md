# TinaIDE Registry

## Android 包产物规则

Android 依赖包按“一个库一个逻辑包”发布，不拆成 `-arm64` / `-x86_64`
这类不同包 ID。包内容和设备兼容性通过元数据表达：

- `artifact_type` 可取 `source`、`header`、`static`、`shared`、`executable`、`mixed`。
- `source` 和 `header` 包不能声明 `abi`。
- `static`、`shared`、`executable` 包必须声明 `abi`。
- 单个包可以同时包含多个 ABI 目录，例如 `lib/arm64-v8a/` 和 `lib/x86_64/`。
- Android 客户端会在下载前拦截不匹配当前设备的 `abi`。

TinaIDE 插件市场和依赖包市场的公开 Registry。

客户端默认按顺序读取：

```text
https://raw.githubusercontent.com/wuxianggujun/TinaIDE-Registry/main
https://cdn.jsdelivr.net/gh/wuxianggujun/TinaIDE-Registry@main
```

## 目录结构

```text
plugins/index.json                         # 插件市场索引
plugins/<plugin-id>/<version>/*.tinaplug   # 插件发布包
packages/index.json                        # 依赖包市场索引
packages/<package-id>/<version>/*          # 依赖包发布文件
sources/plugins/**                         # 官方插件源码或完整打包目录
sources/plugin-starters/**                 # 插件脚手架源模板和校验/打包脚本
metadata/*.json                            # 生成索引用的元数据
scripts/*.ps1                              # Registry 构建脚本
.github/workflows/*.yml                    # Registry 校验和发布自动化
```

## 构建索引

```powershell
pwsh ./scripts/build-registry.ps1
```

该脚本会：

- 重新构建官方插件脚手架 zip。
- 将 `sources/plugins/**` 打包成 `.tinaplug`。
- 计算插件包和依赖包的 `sha256` 与文件大小。
- 重写 `plugins/index.json` 和 `packages/index.json`。

## 校验索引

```powershell
pwsh ./scripts/validate-registry.ps1
```

该脚本会重新构建 Registry，并校验：

- 插件 ID、包 ID、版本号不能重复。
- `.tinaplug` 根目录必须包含 `manifest.json`。
- `plugins/index.json` 中的插件包大小和 `sha256` 必须匹配实际文件。
- `packages/index.json` 中的依赖包大小和 `sha256` 必须匹配实际文件。
- 构建后不能留下未提交的生成物差异。

## GitHub Actions

- `Validate Registry`：在 `main` push、PR 和手动触发时运行，重建并校验索引；如果生成物没有提交，会直接失败。
- `Publish Registry`：手动触发发布，重建并校验 Registry，必要时自动提交生成物，然后创建 `registry-yyyyMMdd-HHmmss` tag 和 GitHub Release。Release 会额外上传单个插件包、单个依赖包和索引文件；GitHub 自动生成的 Source code 压缩包仅用于源码快照，不用于市场下载。

## 发布规则

- 插件发布内容放在 `sources/plugins/<plugin-id>/`，根目录必须包含 `manifest.json`。
- 依赖包发布文件放在 `packages/<package-id>/<version>/`。
- 大文件可以不放入本仓库，但必须在索引中填写可信 CDN、对象存储或自建代理的绝对 URL。
- 不要把 Android 客户端源码、后端、数据库或管理后台放入本仓库。
