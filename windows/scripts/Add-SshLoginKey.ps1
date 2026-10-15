#requires -Version 5.1
<#
Windows OpenSSH login setup for Linux VPS servers.
Keys are stored in %USERPROFILE%\.ssh as id_<alias> and id_<alias>.pub.
-LibraryOnly loads helpers for offline checks without starting the wizard.
#>
[CmdletBinding()]
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-WindowsArgument {
    param([AllowEmptyString()][string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-SshProgram {
    param([string]$Program, [string[]]$Arguments, [int]$TimeoutSeconds = 30)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $Program
    $start.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $true
    $start.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'never'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw '无法启动 OpenSSH 程序。' }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            if ($PSVersionTable.PSVersion.Major -ge 7) { $process.Kill($true) }
            else { & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F 2>&1 | Out-Null }
            $process.WaitForExit()
            throw ('操作超过 {0} 秒，已停止本次连接。' -f $TimeoutSeconds)
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
}

function Invoke-InteractiveProgram {
    param([string]$Program, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Program @Arguments | Out-Host
        $resultCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($resultCode -ne 0) { throw ('程序执行失败，退出码：{0}' -f $resultCode) }
}

function Read-Value {
    param([string]$Prompt, [string]$Default = '')
    if ($Default) { $Prompt += ' [' + $Default + ']' }
    $answer = (Read-Host $Prompt).Trim()
    if (-not $answer) { return $Default }
    return $answer
}

function Get-KeyFingerprint {
    param([string]$Base64Key)
    $bytes = [Convert]::FromBase64String($Base64Key)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return 'SHA256:' + [Convert]::ToBase64String($sha.ComputeHash($bytes)).TrimEnd('=') }
    finally { $sha.Dispose() }
}

function Get-PublicKey {
    param([string]$Text)
    $parts = $Text.Trim() -split '\s+'
    if ($parts.Count -lt 2 -or $parts[0] -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))$') {
        throw '公钥格式不受支持；需要 OpenSSH 单行公钥。'
    }
    $fingerprint = Get-KeyFingerprint $parts[1]
    return [pscustomobject]@{ Type = $parts[0]; Data = $parts[1]; Fingerprint = $fingerprint }
}

function Select-VerifiedHostKey {
    param([string]$ScanText, [string]$ExpectedFingerprint)
    foreach ($line in ($ScanText -split '\r?\n')) {
        if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) { continue }
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -lt 3) { continue }
        try { $key = Get-PublicKey ($parts[1] + ' ' + $parts[2]) }
        catch { continue }
        if ($key.Fingerprint -ceq $ExpectedFingerprint) { return $key }
    }
    throw '指纹不匹配，或服务器未返回对应主机密钥。未信任本次扫描结果，请核对地址、端口和服务器指纹。'
}

function Resolve-VerifiedHostKey {
    param([object]$Scan, [string]$ExpectedFingerprint)
    if ($Scan.StdErr -match 'choose_kex: unsupported KEX method') {
        # A scan may return some key types before another KEX negotiation fails.
        try { return Select-VerifiedHostKey $Scan.StdOut $ExpectedFingerprint }
        catch { }
        Write-Host '主机公钥扫描工具遇到密钥交换算法兼容问题；请通过可信管理会话读取主机公钥。' -ForegroundColor Yellow
        Write-Host '在目标 VPS 的 Termius/控制台运行下面命令；每个指纹后紧跟对应的完整公钥：'
        Write-Host 'for key in /etc/ssh/ssh_host_*_key.pub; do [ -f "$key" ] && { ssh-keygen -lf "$key" -E sha256; cat "$key"; }; done' -ForegroundColor Yellow
        Write-Host '复制与刚才指纹对应的公钥一整行（以 ssh-ed25519、ssh-rsa 或 ecdsa-sha2- 开头），不要复制私钥。'
        $publicText = Read-Value '粘贴该服务器的完整主机公钥'
        $key = Get-PublicKey $publicText
        if ($key.Fingerprint -cne $ExpectedFingerprint) {
            throw '粘贴的主机公钥与刚才提供的指纹不匹配；未保存信任记录，请核对公钥和服务器。'
        }
        return $key
    }
    if ($Scan.ExitCode -ne 0 -and -not $Scan.StdOut.Trim()) {
        throw ('无法获取主机公钥：' + $Scan.StdErr.Trim())
    }
    return Select-VerifiedHostKey $Scan.StdOut $ExpectedFingerprint
}

function Get-HostKeyAlgorithms {
    param([string]$KeyType)
    if ($KeyType -eq 'ssh-rsa') { return 'rsa-sha2-512,rsa-sha2-256' }
    return $KeyType
}

function New-ServerConfig {
    param([string]$Alias, [string]$Address, [string]$LoginUser, [int]$Port,
          [string]$KeyPath, [string]$KnownHostsPath, [string]$HostKeyType, [string]$JumpAlias)
    $lines = @(
        ('# BEGIN Add-SshLoginKey ' + $Alias),
        ('Host ' + $Alias),
        ('    HostName ' + $Address),
        ('    User ' + $LoginUser),
        ('    Port ' + $Port),
        ('    IdentityFile "' + $KeyPath.Replace('\', '/') + '"'),
        '    IdentitiesOnly yes',
        ('    HostKeyAlias ' + $Alias),
        ('    UserKnownHostsFile "' + $KnownHostsPath.Replace('\', '/') + '"'),
        ('    HostKeyAlgorithms ' + (Get-HostKeyAlgorithms $HostKeyType)),
        '    StrictHostKeyChecking yes',
        '    ConnectTimeout 10',
        '    ForwardAgent no'
    )
    if ($JumpAlias) { $lines += '    ProxyJump ' + $JumpAlias }
    $lines += '# END Add-SshLoginKey ' + $Alias
    return ($lines -join "`r`n") + "`r`n"
}

function Merge-ServerConfig {
    param([string]$Original, [string]$Alias, [string]$Block)
    $name = [regex]::Escape($Alias)
    $pattern = '(?ms)^# BEGIN Add-SshLoginKey ' + $name + '\r?\n.*?^# END Add-SshLoginKey ' + $name + '(?:\r?\n|$)'
    $managedMatches = [regex]::Matches($Original, $pattern)
    if ($managedMatches.Count -gt 1) { throw '存在重复的脚本管理配置块，请先手动整理。' }
    if ($managedMatches.Count -eq 1) {
        if ($managedMatches[0].Value.Replace("`r`n", "`n").Trim() -cne $Block.Replace("`r`n", "`n").Trim()) {
            throw '该别名已有不同配置。为避免改变现有连接，请换一个新别名，或手动核对原配置。'
        }
        return $Original
    }
    foreach ($line in ($Original -split '\r?\n')) {
        if ($line -match '^\s*Host(?:\s+|\s*=\s*)(.+)$') {
            $names = (($Matches[1] -split '#', 2)[0].Trim() -split '\s+')
            if (@($names | Where-Object { $_.Trim('"') -ieq $Alias }).Count -gt 0) {
                throw '该别名已经存在于原 SSH 配置中。脚本不覆盖手动配置，请选择新别名。'
            }
        }
    }
    if ($Original -match '(?im)^\s*(Include|Match)(?:\s|=)') {
        throw '原配置使用 Include 或 Match。为避免误改隐含配置，本版脚本不自动写入，请先使用普通 Host 配置或单独手动配置。'
    }
    return $Block + "`r`n" + $Original
}

function Get-KnownHostsUpdate {
    param([string]$LookupText, [string]$Alias, [object]$VerifiedKey)
    $alreadyPresent = $false
    foreach ($line in ($LookupText -split '\r?\n')) {
        if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) { continue }
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -ge 3 -and $parts[1] -eq $VerifiedKey.Type) {
            if ($parts[2] -cne $VerifiedKey.Data) {
                throw '该别名已有不同的服务器主机密钥。脚本不会删除或替换已有信任记录，请先核实服务器是否发生变更。'
            }
            $alreadyPresent = $true
        }
    }
    if ($alreadyPresent) { return '' }
    return $Alias + ' ' + $VerifiedKey.Type + ' ' + $VerifiedKey.Data
}

function Write-BackedUpText {
    param([string]$Path, [string]$Text)
    $exists = Test-Path -LiteralPath $Path
    if ($exists) {
        $oldText = [System.IO.File]::ReadAllText($Path)
        if ($oldText -ceq $Text) { return }
        $backup = $Path + '.bak.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.' + [guid]::NewGuid().ToString('N').Substring(0, 6)
        Copy-Item -LiteralPath $Path -Destination $backup
        Write-Host ('备份：' + $backup)
    }
    $tempPath = $Path + '.tmp.' + [guid]::NewGuid().ToString('N')
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($tempPath, $Text, $utf8)
        if ($exists) { [IO.File]::Replace($tempPath, $Path, $backup) }
        else { Move-Item -LiteralPath $tempPath -Destination $Path }
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath }
    }
}

function New-LinuxInstallCommand {
    param([string]$LoginUser, [string]$Alias, [object]$PublicKey)
    $keyLine = $PublicKey.Type + ' ' + $PublicKey.Data + ' ' + $Alias
    $lines = @(
        'set -eu',
        'if [ "$(id -un)" != ''__LOGIN_USER__'' ]; then',
        '    printf ''%s\n'' ''当前登录账号不正确，请切换到目标 SSH 账号后再运行。'' >&2',
        '    exit 1',
        'fi',
        'umask 077',
        'mkdir -p "$HOME/.ssh"',
        'touch "$HOME/.ssh/authorized_keys"',
        'grep -qxF ''__PUBLIC_KEY__'' "$HOME/.ssh/authorized_keys" || printf ''\n%s\n'' ''__PUBLIC_KEY__'' >> "$HOME/.ssh/authorized_keys"',
        'chmod 700 "$HOME/.ssh"',
        'chmod 600 "$HOME/.ssh/authorized_keys"',
        'printf ''%s\n'' ''公钥已添加，请返回 Windows 脚本。'''
    )
    return ($lines -join "`n").Replace('__LOGIN_USER__', $LoginUser).Replace('__PUBLIC_KEY__', $keyLine)
}

function Enable-LocalKeyAgent {
    $service = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    if (-not $service) { throw '未找到 ssh-agent 服务，请先安装 Windows OpenSSH 客户端。' }
    if ($service.Status -ne 'Running') {
        Write-Host '需要启动 Windows 密钥代理；接下来可能弹出管理员权限确认，仅配置 ssh-agent 服务。'
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        if ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Set-Service -Name ssh-agent -StartupType Automatic
            Start-Service -Name ssh-agent
        } else {
            $command = '$ErrorActionPreference = ''Stop''; Set-Service -Name ssh-agent -StartupType Automatic; Start-Service -Name ssh-agent'
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $adminShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $elevated = Start-Process -FilePath $adminShell -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -Verb RunAs -WindowStyle Hidden -Wait -PassThru
            if ($elevated.ExitCode -ne 0) { throw '密钥代理启动失败；请由管理员启动 ssh-agent 后重新运行。' }
        }
    }
    if ((Get-Service -Name ssh-agent).Status -ne 'Running') { throw '密钥代理尚未运行。' }
}

function Invoke-LoginKeySetup {
    param([string]$SshDirectory = (Join-Path $env:USERPROFILE '.ssh'))
    $programs = @{}
    foreach ($name in @('ssh', 'ssh-keygen', 'ssh-keyscan', 'ssh-add')) {
        $commandInfo = Get-Command ($name + '.exe') -CommandType Application -ErrorAction SilentlyContinue
        if (-not $commandInfo) { throw ('缺少 {0}.exe，请先安装 Windows OpenSSH 客户端。' -f $name) }
        $programs[$name] = $commandInfo.Source
    }
    $sshDir = $SshDirectory
    if (-not (Test-Path -LiteralPath $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
    if (-not (Get-Item -LiteralPath $sshDir).PSIsContainer) { throw '.ssh 路径存在，但不是目录。' }
    $configPath = Join-Path $sshDir 'config'
    $knownHostsPath = Join-Path $sshDir 'known_hosts'
    $originalConfig = ''
    if (Test-Path -LiteralPath $configPath) { $originalConfig = [IO.File]::ReadAllText($configPath) }
    Write-Host "`nWindows / Linux VPS SSH 登录密钥配置" -ForegroundColor Cyan
    Write-Host '请使用日常进行 SSH 连接的 Windows 账号。服务器端操作通过现有可信 Termius 或服务商控制台完成。'
    $address = Read-Value '1. 输入 VPS 的 IPv4 或 IPv6 地址'
    $parsedAddress = $null
    if (-not [Net.IPAddress]::TryParse($address, [ref]$parsedAddress) -or $address.Contains('%')) { throw '请输入有效 IPv4/IPv6 地址，不支持地址范围或带区域标识的地址。' }
    $address = $parsedAddress.ToString()
    $serverAlias = Read-Value '2. 输入 OpenSSH 服务器别名（同时用作 id_ 后的文件名）'
    if ($serverAlias -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') { throw '别名只能包含字母、数字、下划线、短横线和点，且必须以字母或数字开头，最长 64 字符。' }
    $loginUser = Read-Value 'Linux 登录账号' 'root'
    if ($loginUser -notmatch '^[A-Za-z_][A-Za-z0-9_.-]*\$?$') { throw '登录账号格式不受支持。' }
    $portText = Read-Value 'SSH 端口' '22'
    $sshPort = 0
    if (-not [int]::TryParse($portText, [ref]$sshPort) -or $sshPort -lt 1 -or $sshPort -gt 65535) { throw '端口应为 1 到 65535 的整数。' }
    $jumpAlias = Read-Value '跳板机的已有 SSH 别名（不需要则直接回车）'
    if ($jumpAlias -and ($jumpAlias -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$' -or $jumpAlias -ieq $serverAlias)) { throw '跳板机别名格式不正确，或与目标别名相同。' }
    $keyPath = Join-Path $sshDir ('id_' + $serverAlias)
    $publicPath = $keyPath + '.pub'
    Write-Host ('私钥保存位置：' + $keyPath)
    if ((Test-Path -LiteralPath $keyPath) -xor (Test-Path -LiteralPath $publicPath)) { throw '同名密钥文件不完整（缺少私钥或公钥）。脚本不会覆盖或猜补，请换一个别名或先修复原文件。' }
    $reuseKey = Test-Path -LiteralPath $keyPath
    if ($reuseKey -and ((Read-Value '同名密钥已存在。输入 R 复用，其他输入退出') -ine 'R')) { throw '已退出；没有覆盖原密钥。' }
    $probeBlock = New-ServerConfig $serverAlias $address $loginUser $sshPort $keyPath $knownHostsPath 'ssh-ed25519' $jumpAlias
    $managedName = [regex]::Escape($serverAlias)
    if ($originalConfig -notmatch ('(?m)^# BEGIN Add-SshLoginKey ' + $managedName + '\r?$')) {
        $null = Merge-ServerConfig $originalConfig $serverAlias $probeBlock
    }
    Write-Host "`n3. 在目标 VPS 的可信 Termius/控制台中运行下面命令：" -ForegroundColor Cyan
    Write-Host 'for key in /etc/ssh/ssh_host_*_key.pub; do [ -f "$key" ] && ssh-keygen -lf "$key" -E sha256; done' -ForegroundColor Yellow
    $null = Read-Host '服务器命令运行完毕后按回车'
    $fingerprintInput = Read-Value '粘贴其中一行完整输出，或一个 SHA256: 指纹（优先选 ED25519）'
    $fingerprintMatches = [regex]::Matches($fingerprintInput, 'SHA256:[A-Za-z0-9+/]{43}(?![A-Za-z0-9+/=])')
    if ($fingerprintMatches.Count -ne 1) { throw '请提供一个完整的 SHA256 指纹；不要只按回车确认。' }
    $expectedFingerprint = $fingerprintMatches[0].Value
    Write-Host '正在获取服务器主机公钥，并与刚才提供的指纹比较……'
    if ($jumpAlias) {
        Write-Host '跳板机必须已完成密钥登录和主机指纹确认，且安装了 ssh-keyscan。'
        $scanCommand = 'ssh-keyscan -T 10 -p ' + $sshPort + ' -t ed25519,ecdsa,rsa ' + $address
        $scan = Invoke-SshProgram $programs['ssh'] @('-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10', '-o', 'ControlMaster=no', '-o', 'ControlPath=none', $jumpAlias, $scanCommand) 45
    } else {
        $scan = Invoke-SshProgram $programs['ssh-keyscan'] @('-T', '10', '-p', [string]$sshPort, '-t', 'ed25519,ecdsa,rsa', $address) 40
    }
    $verifiedHostKey = Resolve-VerifiedHostKey $scan $expectedFingerprint
    Write-Host ('服务器指纹核对成功：' + $verifiedHostKey.Fingerprint) -ForegroundColor Green
    $newBlock = New-ServerConfig $serverAlias $address $loginUser $sshPort $keyPath $knownHostsPath $verifiedHostKey.Type $jumpAlias
    $newConfig = Merge-ServerConfig $originalConfig $serverAlias $newBlock
    $lookup = [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = '' }
    if (Test-Path -LiteralPath $knownHostsPath) {
        $lookup = Invoke-SshProgram $programs['ssh-keygen'] @('-F', $serverAlias, '-f', $knownHostsPath)
        if ($lookup.ExitCode -gt 1) { throw ('无法读取已有主机身份记录：' + $lookup.StdErr.Trim()) }
    }
    $hostLine = Get-KnownHostsUpdate $lookup.StdOut $serverAlias $verifiedHostKey
    Write-Host "`n4. 配置登录密钥" -ForegroundColor Cyan
    if (-not $reuseKey) {
        Write-Host '下面会提示输入两次私钥口令，推荐设置口令；口令交给 OpenSSH 读取，脚本不会保存。'
        Invoke-InteractiveProgram $programs['ssh-keygen'] @('-t', 'ed25519', '-a', '64', '-f', $keyPath, '-C', $serverAlias)
    }
    $publicKey = Get-PublicKey ([IO.File]::ReadAllText($publicPath))
    $privateFingerprint = Invoke-SshProgram $programs['ssh-keygen'] @('-lf', $keyPath, '-E', 'sha256')
    if ($privateFingerprint.ExitCode -ne 0 -or -not $privateFingerprint.StdOut.Contains($publicKey.Fingerprint)) {
        throw '本机私钥和 .pub 文件无法确认匹配；请核对文件，不要上传这份公钥。'
    }
    Enable-LocalKeyAgent
    Write-Host '将登录密钥加载到本机代理；如有口令，请输入刚才设置的口令。'
    Invoke-InteractiveProgram $programs['ssh-add'] @($keyPath)
    $agentKeys = Invoke-SshProgram $programs['ssh-add'] @('-l')
    if ($agentKeys.ExitCode -ne 0 -or -not $agentKeys.StdOut.Contains($publicKey.Fingerprint)) { throw '无法确认登录密钥已加载到代理。' }
    $currentConfig = ''
    if (Test-Path -LiteralPath $configPath) { $currentConfig = [IO.File]::ReadAllText($configPath) }
    if ($currentConfig -cne $originalConfig) { throw '执行期间 SSH 配置被其他程序修改。为保护这些更改，请重新运行脚本。' }
    if ($hostLine) {
        $knownText = ''
        if (Test-Path -LiteralPath $knownHostsPath) { $knownText = [IO.File]::ReadAllText($knownHostsPath) }
        if (Test-Path -LiteralPath $knownHostsPath) {
            $latestLookup = Invoke-SshProgram $programs['ssh-keygen'] @('-F', $serverAlias, '-f', $knownHostsPath)
            if ($latestLookup.ExitCode -gt 1) { throw '无法复核已有主机身份记录。' }
            $hostLine = Get-KnownHostsUpdate $latestLookup.StdOut $serverAlias $verifiedHostKey
        }
        if ($hostLine) { Write-BackedUpText $knownHostsPath ($knownText.TrimEnd("`r", "`n") + "`r`n" + $hostLine + "`r`n") }
    }
    Write-BackedUpText $configPath $newConfig
    Write-Host "`n请在 VPS 上以目标登录账号运行下面整段命令：" -ForegroundColor Cyan
    Write-Host (New-LinuxInstallCommand $loginUser $serverAlias $publicKey) -ForegroundColor Yellow
    $null = Read-Host '服务器显示“公钥已添加”后按回车，开始连接检测'
    Write-Host "`n5. 正在测试公钥登录……" -ForegroundColor Cyan
    $testCommand = "printf 'SSH_KEY_SETUP_OK\n'; id -un"
    $test = Invoke-SshProgram $programs['ssh'] @('-T', '-F', $configPath, '-o', 'BatchMode=yes', '-o', 'PreferredAuthentications=publickey', '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no', '-o', 'StrictHostKeyChecking=yes', '-o', 'ControlMaster=no', '-o', 'ControlPath=none', '-o', 'ControlPersist=no', $serverAlias, $testCommand) 30
    Write-Host ('私钥：' + $keyPath)
    Write-Host ('公钥：' + $publicPath)
    Write-Host ('SSH 配置：' + $configPath)
    $testLines = @($test.StdOut -split '\r?\n' | Where-Object { $_.Trim() })
    if ($test.ExitCode -eq 0 -and $testLines -ccontains 'SSH_KEY_SETUP_OK' -and $testLines -ccontains $loginUser) {
        Write-Host '连接成功：已验证公钥登录和目标账号，测试连接已结束。' -ForegroundColor Green
        Write-Host ('以后使用：ssh ' + $serverAlias)
        return
    }
    Write-Host '连接失败：未通过公钥登录检测。' -ForegroundColor Red
    Write-Host ('退出码：' + $test.ExitCode)
    if ($test.StdErr.Trim()) { Write-Host $test.StdErr.Trim() }
    if ($test.StdOut.Trim()) { Write-Host $test.StdOut.Trim() }
    Write-Host '请核对目标账号、公钥安装、目录权限和服务器公钥认证设置；使用跳板机时也要核对转发权限。'
    Write-Host '已生成的密钥和配置保留，可以复用同名密钥重新检测；原配置备份仍保留。'
    throw '连接检测失败，脚本未将本次配置标记为成功。'
}

if (-not $LibraryOnly) {
    try { Invoke-LoginKeySetup }
    catch {
        Write-Host ("`n未完成：" + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
