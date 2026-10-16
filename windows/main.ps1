#requires -Version 5.1
[CmdletBinding()]
param([switch]$Remote, [switch]$LibraryOnly, [string]$PrepareUpdate)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:DownloadBase = 'https://raw.githubusercontent.com/GenkiBob/vps-scripts'
$script:Revision = ''
if (Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.revision')) {
    $script:Revision = [IO.File]::ReadAllText((Join-Path $script:ProjectRoot '.revision')).Trim()
    if ($script:Revision -cnotmatch '^[a-f0-9]{40}$') { throw '本地版本文件错误。' }
}
$script:MenuItems = @(
    [pscustomobject]@{
        Id = '1'
        Name = '配置 SSH 登录密钥'
        Path = 'windows/scripts/Add-SshLoginKey.ps1'
        Dependencies = @()
    }
)

function New-MenuTaskDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('vps-scripts-task-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $path
    return $path
}
function Remove-MenuTaskDirectory {
    param([string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if (-not ([IO.Path]::GetDirectoryName($resolved)).Equals($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^vps-scripts-task-[a-f0-9]{32}$') { throw '临时目录校验失败，停止清理。' }
    if (Test-Path -LiteralPath $resolved) {
        if ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '临时目录出现重解析点，停止清理。' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
function Get-MenuScript {
    param([string]$RelativePath, [string]$Destination)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri ($script:DownloadBase + '/' + $script:Revision + '/' + $RelativePath) -OutFile $Destination -TimeoutSec 30 -ErrorAction Stop | Out-Null
}
function Test-MenuScript {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -eq 0) { throw '脚本不存在或内容为空。' }
    $tokens = $null; $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw '脚本语法检查失败，未执行。' }
}
function Invoke-MenuChild {
    param([string]$Path, [string[]]$Arguments = @())
    $shellName = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh.exe' } else { 'powershell.exe' }
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & (Join-Path $PSHOME $shellName) -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments | Out-Host
        $status = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return $status
}
function Get-MenuItemFiles {
    param([object]$Item)
    if ($Item.Id -cnotmatch '^[1-9][0-9]*$') { throw '菜单编号不合法。' }
    $files = @($Item.Path) + @($Item.Dependencies)
    foreach ($path in $files) {
        if ($path -cnotmatch '^windows/scripts/([A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.ps1$') { throw '菜单配置中的脚本或依赖路径不合法。' }
    }
    return $files
}
function Ensure-CachedMenuItem {
    param([object]$Item)
    if (-not $script:Revision) { throw '未安装本地版本，请运行 start.ps1。' }
    $files = @(Get-MenuItemFiles $Item)
    $marker = Join-Path $script:ProjectRoot ('.installed/' + $Item.Id)
    $complete = Test-Path -LiteralPath $marker -PathType Leaf
    if ($complete) {
        foreach ($path in $files) {
            try { Test-MenuScript (Join-Path $script:ProjectRoot $path) } catch { $complete = $false; break }
        }
    }
    if ($complete) {
        Write-Host ("使用本地版本：{0}`n版本：{1}" -f (Join-Path $script:ProjectRoot $Item.Path), $script:Revision.Substring(0,12))
        return
    }
    $workDir = New-MenuTaskDirectory
    try {
        foreach ($path in $files) {
            $destination = Join-Path $workDir $path
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
            Write-Host ('首次下载或准备更新：' + $path)
            Get-MenuScript $path $destination
            Test-MenuScript $destination
        }
        foreach ($path in $files) {
            $destination = Join-Path $script:ProjectRoot $path
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
            Move-Item -LiteralPath (Join-Path $workDir $path) -Destination $destination -Force
        }
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $marker) -Force
        [IO.File]::WriteAllText($marker, $Item.Path)
        Write-Host ("已保存：{0}`n版本：{1}" -f (Join-Path $script:ProjectRoot $Item.Path), $script:Revision.Substring(0,12))
    } finally { Remove-MenuTaskDirectory $workDir }
}
function Prepare-InstalledUpdate {
    param([string]$PreviousRoot)
    foreach ($item in $script:MenuItems) {
        $null = Get-MenuItemFiles $item
        if (Test-Path -LiteralPath (Join-Path $PreviousRoot ('.installed/' + $item.Id)) -PathType Leaf) {
            Write-Host ('准备更新已使用功能：' + $item.Name)
            Ensure-CachedMenuItem $item
        }
    }
}
function Invoke-MenuItem {
    param([object]$Item, [switch]$Online)
    $locationChanged = $false
    try {
        $files = @(Get-MenuItemFiles $Item)
        if ($Online) { Ensure-CachedMenuItem $Item }
        else { foreach ($path in $files) { Test-MenuScript (Join-Path $script:ProjectRoot $path) } }
        Push-Location -LiteralPath $script:ProjectRoot
        $locationChanged = $true
        $status = Invoke-MenuChild (Join-Path $script:ProjectRoot $Item.Path)
        if ($status -eq 0) { Write-Host '执行完成，返回主菜单。' -ForegroundColor Green }
        else { Write-Host ('执行失败（退出码：{0}），返回主菜单。' -f $status) -ForegroundColor Red }
    } catch { Write-Host ('执行失败：{0} 返回主菜单。' -f $_.Exception.Message) -ForegroundColor Red }
    finally { if ($locationChanged) { Pop-Location } }
}
function Read-MenuSelection {
    Write-Host '请输入编号并按回车：' -NoNewline
    return [Console]::ReadLine()
}
function Start-WindowsMenu {
    param([switch]$Online)
    while ($true) {
        Write-Host "`n========== Windows 脚本菜单 =========="
        foreach ($item in $script:MenuItems) { Write-Host ('{0}. {1}' -f $item.Id, $item.Name) }
        Write-Host 'u. 检查并更新脚本'
        Write-Host '0. 退出'
        $selection = Read-MenuSelection
        if ($null -eq $selection) { Write-Host "`n输入已结束，退出。"; return }
        if ($selection -ceq '0') { Write-Host '已退出。'; return }
        if ($selection -ceq 'u') {
            $status = Invoke-MenuChild (Join-Path $PSScriptRoot 'start.ps1') -Arguments @('-Update')
            if ($status -ne 0) { Write-Host '更新入口运行失败。' -ForegroundColor Red; continue }
            return
        }
        $items = @($script:MenuItems | Where-Object { $_.Id -ceq $selection })
        if ($items.Count -ne 1) { Write-Host '输入错误：请输入菜单中显示的编号。' -ForegroundColor Yellow; continue }
        Write-Host ('开始执行：' + $items[0].Name)
        Invoke-MenuItem $items[0] -Online:$Online
    }
}
if (-not $LibraryOnly) {
    try {
        if ($env:OS -ne 'Windows_NT') { throw '请在 Windows PowerShell 中运行此入口。' }
        if ($PrepareUpdate) { Prepare-InstalledUpdate $PrepareUpdate }
        elseif ($Remote -and -not $script:Revision) {
            $status = Invoke-MenuChild (Join-Path $PSScriptRoot 'start.ps1')
            exit $status
        } else { Start-WindowsMenu -Online:$Remote }
        exit 0
    } catch { Write-Host ('启动失败：' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
}
