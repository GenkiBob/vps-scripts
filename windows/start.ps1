#requires -Version 5.1
[CmdletBinding()]
param([switch]$Update, [switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:InstallRoot = if ($env:VPS_SCRIPTS_HOME) { [IO.Path]::GetFullPath($env:VPS_SCRIPTS_HOME) } else { Join-Path $env:LOCALAPPDATA 'VpsScripts' }

function Invoke-StartChild {
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
function Get-CurrentInstalledRoot {
    $pointer = Join-Path $script:InstallRoot 'current'
    if (-not (Test-Path -LiteralPath $pointer -PathType Leaf)) { return '' }
    $version = [IO.File]::ReadAllText($pointer).Trim()
    if ($version -cnotmatch '^[a-f0-9]{40}-[a-f0-9]{32}$') { throw '本地版本指针不合法。' }
    $root = Join-Path $script:InstallRoot ('versions/' + $version)
    if (-not (Test-Path -LiteralPath (Join-Path $root 'windows/main.ps1') -PathType Leaf)) { throw '本地菜单缺失。' }
    return $root
}
function Test-StartupScript {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -eq 0) { throw '下载脚本不存在或内容为空。' }
    $tokens=$null; $parseErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw '脚本语法检查失败。' }
}
function Get-StartupFile {
    param([string]$Uri,[string]$Destination,[hashtable]$Headers=@{})
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers $Headers -OutFile $Destination -TimeoutSec 30 -ErrorAction Stop | Out-Null
}
function Publish-InstalledFile {
    param([string]$Source,[string]$Destination)
    if (Test-Path -LiteralPath $Destination) {
        # PowerShell 5.1 将空备份参数转换为空字符串，因此使用明确的临时备份路径。
        $backup=$Destination+'.backup-'+[guid]::NewGuid().ToString('N')
        try { [IO.File]::Replace($Source,$Destination,$backup) }
        finally { if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force } }
    } else { [IO.File]::Move($Source,$Destination) }
}
function Remove-PendingVersion {
    param([string]$Path)
    $resolved=[IO.Path]::GetFullPath($Path)
    $parent=[IO.Path]::GetFullPath((Join-Path $script:InstallRoot 'versions')).TrimEnd('\','/')
    if (-not ([IO.Path]::GetDirectoryName($resolved)).Equals($parent,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -cnotmatch '^[a-f0-9]{40}-[a-f0-9]{32}$') { throw '待清理版本目录校验失败。' }
    if (Test-Path -LiteralPath $resolved) {
        if ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '待清理目录出现重解析点。' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
function Install-NewVersion {
    param([string]$PreviousRoot)
    $queryPath=Join-Path $script:InstallRoot ('.query-' + [guid]::NewGuid().ToString('N'))
    $stage=''; $launcherTemp=''; $pointerTemp=''
    try {
        Write-Host '正在检查版本……'
        Get-StartupFile 'https://api.github.com/repos/GenkiBob/vps-scripts/commits/main' $queryPath @{Accept='application/vnd.github.sha'}
        $revision=[IO.File]::ReadAllText($queryPath).Trim()
        if ($revision -cnotmatch '^[a-f0-9]{40}$') { throw '远端版本格式错误。' }
        if ($PreviousRoot -and [IO.File]::ReadAllText((Join-Path $PreviousRoot '.revision')).Trim() -ceq $revision) {
            Write-Host ('当前已是最新版本：' + $revision.Substring(0,12)); return
        }
        $name=$revision+'-'+[guid]::NewGuid().ToString('N')
        $stage=Join-Path $script:InstallRoot ('versions/'+$name)
        $null=New-Item -ItemType Directory -Path (Join-Path $stage 'windows')
        [IO.File]::WriteAllText((Join-Path $stage '.revision'),$revision)
        foreach ($path in @('windows/start.ps1','windows/main.ps1')) {
            Write-Host ('正在下载：' + $path)
            $destination=Join-Path $stage $path
            Get-StartupFile ('https://raw.githubusercontent.com/GenkiBob/vps-scripts/'+$revision+'/'+$path) $destination
            Test-StartupScript $destination
        }
        if ($PreviousRoot) {
            $status=Invoke-StartChild (Join-Path $stage 'windows/main.ps1') @('-PrepareUpdate',$PreviousRoot)
            if ($status -ne 0) { throw '已使用功能更新失败，未切换版本。' }
        }
        $launcherTemp=Join-Path $script:InstallRoot ('.launcher-'+[guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath (Join-Path $stage 'windows/start.ps1') -Destination $launcherTemp
        Publish-InstalledFile $launcherTemp (Join-Path $script:InstallRoot 'start.ps1')
        $launcherTemp=''
        $pointerTemp=Join-Path $script:InstallRoot ('.current-'+[guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($pointerTemp,$name)
        Publish-InstalledFile $pointerTemp (Join-Path $script:InstallRoot 'current')
        $pointerTemp=''; $stage=''
        Write-Host ('安装或更新完成，本地入口：' + (Join-Path $script:InstallRoot 'start.ps1'))
    } finally {
        foreach ($file in @($queryPath,$launcherTemp,$pointerTemp)) {
            if ($file -and (Test-Path -LiteralPath $file)) { Remove-Item -LiteralPath $file -Force }
        }
        if ($stage) { Remove-PendingVersion $stage }
    }
}
function Start-OnlineWindowsMenu {
    param([switch]$Refresh)
    $null=New-Item -ItemType Directory -Path (Join-Path $script:InstallRoot 'versions') -Force
    $previous=Get-CurrentInstalledRoot
    if (-not $previous -or $Refresh) {
        try { Install-NewVersion $previous }
        catch {
            if (-not $previous) { throw }
            Write-Host ('更新失败，保留并使用原有本地版本：' + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    $selected=Get-CurrentInstalledRoot
    $menuPath=Join-Path $selected 'windows/main.ps1'
    Test-StartupScript $menuPath
    $revision=[IO.File]::ReadAllText((Join-Path $selected '.revision')).Trim()
    Write-Host ("使用本地菜单：{0}`n版本：{1}" -f $menuPath,$revision)
    $status=Invoke-StartChild $menuPath @('-Remote')
    if ($status -ne 0) { throw ('菜单退出码：'+$status) }
}
if (-not $LibraryOnly) {
    try {
        if ($env:OS -ne 'Windows_NT') { throw '请在 Windows PowerShell 中运行此入口。' }
        Start-OnlineWindowsMenu -Refresh:$Update
        exit 0
    } catch { Write-Host ('启动失败：'+$_.Exception.Message) -ForegroundColor Red; exit 1 }
}
