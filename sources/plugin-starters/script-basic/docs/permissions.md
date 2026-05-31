# 权限说明

当前模板默认申请：

- `ui.notification`
- `editor.read`
- `editor.selection`
- `editor.write`
- `diagnostics.read`
- `workspace.read`
- `command.execute`

如果你后续需要：

- 读取选择区：保留 `editor.selection`
- 修改当前编辑器：保留 `editor.write`
- 读项目文件：保留 `workspace.read`
- 写项目文件：增加 `workspace.write`
- 读取诊断快照：保留 `diagnostics.read`
- 注册插件命令或调用宿主命令：保留 `command.execute`
- 本地存储：增加 `storage.local`
- SQLite：增加 `storage.database`
- 网络访问：增加 `network.fetch`

建议始终按最小权限原则逐步增加。
