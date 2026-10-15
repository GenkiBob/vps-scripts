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

“配置 SmartDNS”需要 root，支持 Debian/Ubuntu + systemd、amd64/arm64，且 `/etc/resolv.conf` 为普通静态文件；不接管已有 SmartDNS、resolved/NetworkManager 或检测到的 DHCP 配置。需先准备工具：

```bash
apt install dnsutils curl python3 ca-certificates iproute2 util-linux
```

选择菜单 `2`，按提示输入 DNS 地址。脚本测试通过后下载并校验官方 SmartDNS，保存原 DNS；首选断连使用原 DNS，恢复后重新优先首选。成功后显示 9 项服务的访问测试，HTTP 拒绝或限流不代表解锁成功。使用独立 DNS/DoH 的应用不受系统 DNS 控制。

原配置备份在 `/var/lib/vps-smartdns/original-resolv.conf`，中断后可重新运行；需要手动恢复最初系统 DNS 时，以 root 执行：

```bash
cat /var/lib/vps-smartdns/original-resolv.conf > /etc/resolv.conf && systemctl disable --now vps-smartdns.service
```

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
