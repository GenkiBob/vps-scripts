# 运行方法

## Linux

需要 Bash、wget 和 mktemp。在 Bash 中下载并启动：

```bash
wget -O vps-start.sh https://raw.githubusercontent.com/GenkiBob/vps-scripts/main/start.sh && bash vps-start.sh
```

已下载完整项目时，在项目目录运行：

```bash
bash main.sh
```

输入菜单编号并回车执行，执行结束返回菜单，输入 `0` 退出。

在线启动只下载菜单；选中项目后下载对应脚本及其依赖，执行后清理临时文件。

## Windows

使用 Windows PowerShell 5.1 或 PowerShell 7，在 PowerShell 窗口中执行：

```powershell
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/GenkiBob/vps-scripts/main/windows/start.ps1' -OutFile "$env:TEMP\vps-start.ps1" -ErrorAction Stop; if ($?) { powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\vps-start.ps1" }
```

已下载完整项目时，在项目目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\main.ps1
```

Windows 菜单仅显示 Windows 项目，按选择下载并运行，执行结束返回菜单，输入 `0` 退出；执行策略参数仅对本次进程生效。

“配置 SSH 登录密钥”需要 Windows OpenSSH 客户端（ssh、ssh-keygen、ssh-keyscan、ssh-add），用于配置 Windows 到 Linux VPS 的登录。请使用日常 SSH 账号运行；目标地址、别名、账号等按提示输入，服务器端操作通过已有可信终端或控制台完成。脚本保留已有配置并备份修改，密钥保存在当前用户的 `.ssh` 中；启动 ssh-agent 服务时可能出现管理员确认。
