# 权限说明

当前模板默认申请：

- `ui.notification`
- `editor.read`
- `editor.selection`
- `editor.write`
- `command.execute`

如果你后续需要：

- 只读活动编辑器：保留 `editor.read`
- 读取选择区：保留 `editor.selection`
- 修改当前编辑器：保留 `editor.write`
- 注册插件命令或调用宿主命令：保留 `command.execute`

如果不需要：

- 不读选择区，就删除 `editor.selection`
- 不写编辑器，就删除 `editor.write`
- 不注册插件命令，也不转发宿主命令，就删除 `command.execute`

建议始终按最小权限原则逐步增加。
