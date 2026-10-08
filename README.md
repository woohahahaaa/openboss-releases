# OpenBoss

OpenBoss 是一个本地常驻的 AI 编程助手监控台：用 EYE 插件接入各类客户端，实时显示每个会话的进度，卡住时提醒你。

## 安装

### macOS

先打开「终端」（Terminal）：按 `Command + 空格` 打开聚焦搜索（Spotlight），输入「终端」或「Terminal」，回车即可；也可以打开「访达」→「应用程序」→「实用工具」→「终端」。

然后把下面这行复制进终端窗口，回车：

```sh
curl -fsSL https://raw.githubusercontent.com/woohahahaaa/openboss-releases/main/install.sh | sh
```

### Windows

先打开 PowerShell：点「开始」按钮（或按键盘上的 Win 键），直接输入 `PowerShell`，在搜索结果里点「Windows PowerShell」；Windows 11 也可以搜「终端」（Terminal）。不需要管理员身份。

然后把下面这行复制进窗口，回车：

```powershell
irm https://raw.githubusercontent.com/woohahahaaa/openboss-releases/main/install.ps1 | iex
```

安装脚本会下载最新版本、放到固定目录、加进 PATH，并注册登录自启；macOS 还会在桌面生成 `OpenBoss.app` 启动器，双击用完整 Chrome 窗口打开控制台（`OPENBOSS_NO_DESKTOP=1` 可跳过）。想让程序坞显示 OpenBoss 自己的图标，在页面地址栏点「安装」把控制台装成 PWA 即可（这一步只能由浏览器完成）。想手动安装，可从 [Releases](https://github.com/woohahahaaa/openboss-releases/releases) 下载对应平台的压缩包，解压后保持 `openboss`（Windows 为 `openboss.exe`）与 `EYE/` 同目录即可。

装好后浏览器打开 <http://127.0.0.1:18799>。默认端口 18799，实际端口写在 `~/.openboss/port`（Windows 在 `%USERPROFILE%\.openboss\port`），EYE 插件启动时读这个文件。

Center 默认监听所有网卡：同一局域网的设备可以直接用 `http://<本机IP>:18799` 打开；想只限本机，把 `~/.openboss/config.json` 里的 `bindHost` 设为 `127.0.0.1`（Windows 首次监听会弹防火墙授权，选择允许）。

## 运行机制

安装完成后后端即常驻：登录自动启动，进程挂了自动重拉。

- **登录自启**：macOS 注册 LaunchAgent（`RunAtLoad`），Windows 注册登录任务（任务计划程序）。开机登录后无需手动做任何事，后端自动运行。
- **确认自启装好了**：终端运行 `openboss service status`。退出码 `0`=已安装且运行中、`4`=已安装但暂停（下次登录仍会自启）、`3`=未安装。curl / irm 安装脚本会用这个码校验，装不上会直接报错退出，不会静默略过。
- **崩溃自动重启**：macOS 由 launchd 的 `KeepAlive` 拉起；Windows 由 `openboss up --supervise` 守护循环负责（退出 1 秒后重拉）。日志都在 `~/.openboss/log/center.log`。
- **手动管理**：
  - `openboss service status | start | stop` — 查看、启动、暂停自启服务；`stop` 只是暂停，下次登录会自动恢复。
  - `openboss serve` — 前台运行；`openboss up` — 确保后端在跑（幂等）。
- **局域网与反向代理**：默认监听 `0.0.0.0`，界面、API、WebSocket 共用同一个端口，反代整个端口即可（记得放行 WebSocket 的 `Upgrade`/`Connection` 头）。Center 没有内置登录，局域网内任何人都能操作——请只在可信网络使用，或由反代加一层认证；只限本机时把 `config.json` 的 `bindHost` 设为 `127.0.0.1`。
- **升级**：检测到新版本时，侧边栏「系统设置」会出现「检测可更新」小标，进设置首页点「升级」即可（Center 自动下载并重启到新版本，页面自动刷新）；也可以在终端运行 `openboss upgrade`。
- **开发**：在源码仓库用 `./alive.sh` 本地重建并运行（默认生产模式；`./alive.sh dev` 切换 Vite 热更新）。构建产物写在 `~/.openboss/app/`，与安装版、一键升级共用同一位置，互相覆盖。运行时会临时暂停已安装的自启服务，下次登录自动恢复。
