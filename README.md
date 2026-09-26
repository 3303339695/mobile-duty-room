# 手机端值班室

在 Android 手机上通过 ZeroTermux 部署和管理 NapCat QQ 与 AstrBot 的本地值班室。

当前固定版本：

- NapCat QQ：`4.18.19`
- Linux QQ：`3.2.30-50969`
- AstrBot：`4.27.3`
- 应用：`1.3.23`

## 功能

- 一键初始化 ZeroTermux、目录授权和后台保活。
- 部署、启动、停止和卸载 NapCat QQ。
- 精确检查 Linux QQ 内核版本，部署时强制写入 `o3HookMode: 0`。
- 支持单独卸载 Linux QQ 内核，以及按 `3.2.30-50969` 重装内核。
- 从固定摘要的官方 ARM64 AppImage 提取 Linux QQ 运行内核，并校验 AArch64 架构与版本。
- 部署、启动、停止和卸载 AstrBot 运行底座。
- 创建、配置、启动、停止和备份多个 AstrBot 实例。
- 进入实例页先显示“检测中”，再根据实际端口状态显示“运行中”或“已停止”。
- 自动写入 NapCat 反向 WebSocket 连接配置。
- 部署和测试本地 MiniLM 向量服务。

详细操作见 [手机端值班室-使用说明.md](手机端值班室-使用说明.md)。

## 仓库内容

仓库只保存应用源码、构建脚本、运行脚本和说明文档。

以下内容不会上传：

- Android 签名密钥
- APK 和 ZIP 发布包
- 本地 Android SDK、JDK 和缓存
- 上游项目研究克隆
- 手机截图和旧版安装包
- 本机运行数据和备份

APK 请通过 GitHub Releases 获取。

## 构建

在 Windows PowerShell 中运行：

```powershell
.\build_apk.ps1
```

构建脚本需要 JDK 17 和 Android SDK 35。默认查找项目内的
`.tools\jdk` 与 `.tools\android-sdk`；这些本地工具目录不会上传。

生成发布文件：

```powershell
python .\tools\make_release.py . .\手机端值班室.apk
```

首次构建时，如果 `signing\zhibanshi.keystore` 不存在，脚本会自动生成
新的本地签名密钥。请妥善保管自己的密钥，不要提交到公开仓库。

## 使用条件

- Android 手机
- ZeroTermux
- Microsoft Edge，用于打开管理面板
- 足够的存储空间和稳定的后台运行权限

使用前请确认 ZeroTermux 未被系统限制后台运行，也不要启用会冻结后台进程、
清理缓存应用或限制后台进程数量的省电策略。

项目和应用统一使用不绑定具体机器人品牌的中性名称“手机端值班室”。
为保证旧版本升级兼容，ZeroTermux 内的部署目录和 Android 包名均保持不变。

## 说明

NapCat、AstrBot、ZeroTermux 和 Linux QQ 的版权归各自项目所有。本仓库只提供
手机端部署、配置和管理工具。
