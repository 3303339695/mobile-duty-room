# 手机端值班室

在 Android 手机上通过 ZeroTermux 部署和管理 NapCat QQ 与 AstrBot 的本地值班室。

当前固定版本：

- NapCat QQ：`4.18.19`
- Linux QQ：`3.2.30-50969`
- AstrBot：`4.27.3`
- 应用：`1.3.34`

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
- 日志按组件和日期分文件存放，超限自动轮转、过期自动清理，界面只读尾部内容。

详细操作见 [手机端值班室-使用说明.md](手机端值班室-使用说明.md)。

## 日志机制（改动前请先读完）

日志目录结构：

```
logs/<组件>/<日期>.log          组件当天的日志
logs/astrbot/<实例ID>/<日期>.log  单个 AstrBot 实例的日志
logs/<组件>/<日期>.log.1        轮转出来的历史副本（编号越大越旧）
```

规则：

- 单个日志文件超过 `LOG_MAX_BYTES`（默认 10 MB）就地轮转成 `.1`，只保留这一份副本。
- 超过 `LOG_KEEP_DAYS`（默认 7 天）的日志在守护进程巡检时自动删除，不需要手动清理。
- 正在被进程打开的日志一律不轮转、不删除：服务长时间不重启时会一直写启动那天的文件，
  那个文件的修改时间会永远停在启动日，直接按天数删掉的话服务会继续写一个已删除的 inode，
  日志就"凭空消失"了。`log_in_use()` 通过 `/proc/<pid>/fd` 反查占用情况。
- 加了 15 分钟安静期：刚写过（`ROTATE_QUIET_SECONDS` 内）的文件不轮转，避开和正在写入的服务抢。
- 界面读取只取**尾部 256 KB**，所以日志再大也不会卡住日志栏。
- 前端选「全部 AstrBot」时，App 会遍历 `logs/astrbot/` 下各实例子目录，把当天有内容的日志汇总显示
  （每个实例最多 64 KB、最多合并 6 个实例）。实例日志在磁盘上始终是分开的，汇总发生在读取侧，
  所以脚本侧不需要为了"汇总"多写一份文件，也就避免为了双写而引入管道。
- 轮转由 `bin/log_rotate.sh` 完成，由 `bin/watchdog.sh` 每 20 秒巡检一次。

**重要：服务的输出只能直接追加到文件，禁止接任何管道消费者。**
不要写回 `> >(bash log_daily.sh ...)` 或 `| tee`。原因：

- 管道消费者一旦变慢（比如逐行做一次磁盘写入），管道会被填满，
  服务的每一次 `write` 都会阻塞，保活巡检和业务循环一起卡死。
- 管道消费者一旦被系统杀掉，服务下一次写 stdout 会收到 `SIGPIPE`，
  默认行为是**直接终止进程**。`watchdog.sh` 就挂在这根管道上，它一死就再没人拉起服务。
- 典型症状就是「手机息屏一会儿，NapCat / AstrBot 全停」。

轮转用的是 `cp` 加就地截断（copytruncate），不能改成 `mv`：
服务进程持有原文件的 inode，`mv` 之后它会继续往一个已经改名的文件里写，日志看起来就凭空消失了。

## 图标与视觉

应用图标和界面风格从一开始就基于同一张原始设计稿：

```
design/app-icon-source.jpg      原始设计稿（只作存档，不参与打包）
        │
        ├─转码─▶ assets/galaxy-mark.png          界面左上角的星云标志
        └─转码─▶ res/mipmap-*/ic_launcher.png    启动图标（xhdpi ~ xxxhdpi）
```

`design/` 目录只放设计原始稿，**不会被打进 APK**（`assets/` 和 `res/` 下的才是运行时资源）。
要换图标或调整色调时，请以 `design/app-icon-source.jpg` 为准重新导出上述 PNG，
不要直接手改 `res/` 里已经降采样的图。

## 仓库内容

仓库只保存应用源码、构建脚本、运行脚本、设计原始稿和说明文档。

以下内容不会上传：

- Android 签名密钥
- APK 和 ZIP 发布包
- 本地 Android SDK、JDK 和缓存
- 上游项目研究克隆
- 手机截图和旧版安装包
- 本机运行数据和备份

APK 请通过 GitHub Releases 获取。

日志逻辑改动后，可以在 Termux 里跑一遍验收脚本：

```bash
cd ~/手机端值班室 && bash tools/test_log_rotate.sh
```

它会用临时的假部署目录验证日切路径、超限轮转、过期清理、占用保护和旧版遗留单文件兼容，
不会碰你真实的日志。

改了 shell 脚本之后，可以先做一次真实的语法校验：

```bash
bash tools/check_shell_syntax.sh
```

它会用 `bash -n` 检查 `assets/bin` 与 `tools` 下的全部脚本，输出 `共检查 N 个脚本，失败 0 个` 即为通过
（`build_apk.ps1` 在能启动 Git Bash 的环境里也会自动做这一步）。

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
