#requires -Version 5.1
[CmdletBinding()]
param([switch]$Remote, [switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:DownloadBase = 'https://raw.githubusercontent.com/GenkiBob/vps-scripts/main'
# 每个平台独立编号；Dependencies 登记此功能的全部直接和间接依赖。
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
        [IO.Path]::GetFileName($resolved) -notmatch '^vps-scripts-task-[a-f0-9]{32}$') {
        throw '临时目录校验失败，停止清理。'
    }
    if (Test-Path -LiteralPath $resolved) {
        if ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw '临时目录出现重解析点，停止清理。'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

function Get-MenuScript {
    param([string]$RelativePath, [string]$Destination)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri ($script:DownloadBase + '/' + $RelativePath) -OutFile $Destination -TimeoutSec 30 -ErrorAction Stop | Out-Null
}

function Test-MenuScript {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        throw '脚本不存在或内容为空。'
    }
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw '脚本语法检查失败，未执行。' }
}

function Invoke-MenuChild {
    param([string]$Path)
    $shellName = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh.exe' } else { 'powershell.exe' }
    $shell = Join-Path $PSHOME $shellName
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path | Out-Host
        $status = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return $status
}

function Invoke-MenuItem {
    param([object]$Item, [switch]$Online)
    $workDir = $null
    $locationChanged = $false
    try {
        $files = @($Item.Path) + @($Item.Dependencies)
        foreach ($relativePath in $files) {
            if ($relativePath -cnotmatch '^windows/scripts/([A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.ps1$') {
                throw '菜单配置中的脚本或依赖路径不合法。'
            }
        }
        $root = $script:ProjectRoot
        if ($Online) {
            $workDir = New-MenuTaskDirectory
            $root = $workDir
        }
        foreach ($relativePath in $files) {
            $destination = Join-Path $root $relativePath
            if ($Online) {
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
                Write-Host ('正在下载：' + $relativePath)
                Get-MenuScript $relativePath $destination
            }
            Test-MenuScript $destination
        }
        Push-Location -LiteralPath $root
        $locationChanged = $true
        $status = Invoke-MenuChild (Join-Path $root $Item.Path)
        if ($status -eq 0) { Write-Host '执行完成，返回主菜单。' -ForegroundColor Green }
        else { Write-Host ('执行失败（退出码：{0}），返回主菜单。' -f $status) -ForegroundColor Red }
    } catch {
        Write-Host ('执行失败：{0} 返回主菜单。' -f $_.Exception.Message) -ForegroundColor Red
    } finally {
        if ($locationChanged) { Pop-Location }
        if ($workDir) { Remove-MenuTaskDirectory $workDir }
    }
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
        Write-Host '0. 退出'
        $selection = Read-MenuSelection
        if ($null -eq $selection) { Write-Host "`n输入已结束，退出。"; return }
        if ($selection -ceq '0') { Write-Host '已退出。'; return }
        $matches = @($script:MenuItems | Where-Object { $_.Id -ceq $selection })
        if ($matches.Count -ne 1) { Write-Host '输入错误：请输入菜单中显示的编号。' -ForegroundColor Yellow; continue }
        Write-Host ('开始执行：' + $matches[0].Name)
        Invoke-MenuItem $matches[0] -Online:$Online
    }
}

if (-not $LibraryOnly) {
    try {
        if ($env:OS -ne 'Windows_NT') { throw '请在 Windows PowerShell 中运行此入口。' }
        Start-WindowsMenu -Online:$Remote
        exit 0
    } catch {
        Write-Host ('启动失败：' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
