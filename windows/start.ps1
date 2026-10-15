#requires -Version 5.1
[CmdletBinding()]
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Start-OnlineWindowsMenu {
    $workDir = Join-Path ([IO.Path]::GetTempPath()) ('vps-scripts-menu-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path (Join-Path $workDir 'windows')
    try {
        $menuPath = Join-Path $workDir 'windows/main.ps1'
        $menuUrl = 'https://raw.githubusercontent.com/GenkiBob/vps-scripts/main/windows/main.ps1'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Host '正在下载 Windows 菜单……'
        Invoke-WebRequest -UseBasicParsing -Uri $menuUrl -OutFile $menuPath -TimeoutSec 30 -ErrorAction Stop | Out-Null
        if (-not (Test-Path -LiteralPath $menuPath -PathType Leaf) -or (Get-Item -LiteralPath $menuPath).Length -eq 0) {
            throw '菜单不存在或内容为空。'
        }
        $tokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($menuPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw '菜单语法检查失败，停止启动。' }
        $shellName = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh.exe' } else { 'powershell.exe' }
        $shell = Join-Path $PSHOME $shellName
        & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $menuPath -Remote | Out-Host
        if ($LASTEXITCODE -ne 0) { throw ('菜单退出码：' + $LASTEXITCODE) }
    } finally {
        $resolved = [IO.Path]::GetFullPath($workDir)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
        if (-not ([IO.Path]::GetDirectoryName($resolved)).Equals($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notmatch '^vps-scripts-menu-[a-f0-9]{32}$') {
            throw '临时目录校验失败，停止清理。'
        }
        if (Test-Path -LiteralPath $resolved) {
            if ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw '临时目录出现重解析点，停止清理。'
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

if (-not $LibraryOnly) {
    try {
        if ($env:OS -ne 'Windows_NT') { throw '请在 Windows PowerShell 中运行此入口。' }
        Start-OnlineWindowsMenu
        exit 0
    } catch {
        Write-Host ('启动失败：' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
