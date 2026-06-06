# TinaIDE Registry

## Registry v2 索引

当前 Registry 同时发布 v2 轻量索引和 v1 兼容索引：

```text
plugins/index.v2.json
plugins/<plugin-id>/plugin.json
plugins/index.json
packages/index.v2.json
packages/<package-id>/package.json
packages/index.json
```

Android 客户端优先读取 `index.v2.json`。列表页只下载轻量摘要；
打开详情、安装插件、检查更新或安装依赖包时，再按需读取单个
`plugin.json` / `package.json`。如果 v2 文件不存在、请求失败或解析失败，
客户端会自动回退旧的 `index.json`。

`scripts/build-registry.ps1` 会同时生成 v2 与 v1 产物；
`scripts/validate-registry.ps1` 会校验 v2 的 `detail_url`、详情文件和轻量字段边界。

## 协议生命周期

v2 是当前主协议，v1 只作为旧客户端兼容层保留。

- `0.17.11`：Android 客户端引入 v2 优先读取，并把 v1 fallback 标记为废弃兼容层。
- `0.18.x` / `0.19.x`：迁移窗口，Registry 继续生成 v2 与 v1 两套产物。
- `0.20.0` 起：Android 客户端可以删除 v1 fallback 代码。
- `0.21.0` 起：Registry 可以停止生成 `plugins/index.json` / `packages/index.json`。

移除 v1 前必须确认 v2 索引、详情文件和 `validate-registry.ps1` 已连续稳定通过。

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
plugins/index.v2.json                      # 插件市场 v2 轻量索引
plugins/<plugin-id>/plugin.json            # 单个插件详情和版本历史
plugins/index.json                         # 插件市场 v1 兼容索引
plugins/<plugin-id>/<version>/*.tinaplug   # 插件发布包
packages/index.v2.json                     # 依赖包市场 v2 轻量索引
packages/<package-id>/package.json         # 单个依赖包详情、版本和下载信息
packages/index.json                        # 依赖包市场 v1 兼容索引
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
- 重写 `plugins/index.v2.json`、`packages/index.v2.json`、详情文件和 v1 兼容索引。

## 校验索引

```powershell
pwsh ./scripts/validate-registry.ps1
```

该脚本会重新构建 Registry，并校验：

- 插件 ID、包 ID、版本号不能重复。
- `.tinaplug` 根目录必须包含 `manifest.json`。
- `plugins/index.v2.json` / `packages/index.v2.json` 的 `detail_url` 必须指向真实详情文件。
- v2 轻量索引不能混入下载地址、checksum、release notes 等重字段。
- v1 `plugins/index.json` 中的插件包大小和 `sha256` 必须匹配实际文件。
- v1 `packages/index.json` 中的依赖包大小和 `sha256` 必须匹配实际文件。
- 构建后不能留下未提交的生成物差异。

## GitHub Actions

- `Validate Registry`：在 `main` push、PR 和手动触发时运行，重建并校验索引；如果生成物没有提交，会直接失败。
- `Publish Registry`：手动触发发布，重建并校验 Registry，必要时自动提交生成物，然后创建 `registry-yyyyMMdd-HHmmss` tag 和 GitHub Release。Release 会额外上传单个插件包、单个依赖包、v2 轻量索引、详情文件和 v1 兼容索引；GitHub 自动生成的 Source code 压缩包仅用于源码快照，不用于市场下载。

## 发布规则

- 插件发布内容放在 `sources/plugins/<plugin-id>/`，根目录必须包含 `manifest.json`。
- 依赖包发布文件放在 `packages/<package-id>/<version>/`。
- 大文件可以不放入本仓库，但必须在索引中填写可信 CDN、对象存储或自建代理的绝对 URL。
- 不要把 Android 客户端源码、后端、数据库或管理后台放入本仓库。
