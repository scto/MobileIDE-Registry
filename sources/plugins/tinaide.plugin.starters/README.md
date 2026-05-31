# TinaIDE Plugin Starters

这是 TinaIDE 官方内置的插件脚手架插件。

它会在“新建项目”中提供四个模板；从插件教程或设置页的
“创建插件项目”快捷入口进入时，向导会只显示这些插件模板：

- Tina Config Plugin
- Tina Script Command Plugin (Beta)
- Tina Script Plugin (Beta)
- Tina LSP Plugin

这些模板用于帮助用户快速创建可打包、可安装的 TinaIDE 插件工程。

创建出的插件项目遵循同一条开发闭环：

- 点击 **运行**：校验、打包 `.tinaplug`，并热安装到当前 IDE
- 点击 **打包**：只生成 `dist/<manifest.id>-<manifest.version>.tinaplug`
- 离线分发前，可用“设置 → 插件 → 从文件安装”再次预检生成的 `.tinaplug`
