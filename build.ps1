[CmdletBinding()]
param(
    # AdGuard Home 版本标签（写入 build-info.txt / 作为产物名的一部分）。
    # 传 'local' 表示本地未跟踪版本。
    [ValidateNotNullOrEmpty()]
    [string]$AghVersion = 'local',

    # 若 bin/AdGuardHome 不存在，自动从 GitHub 官方 Release 下载指定架构的二进制。
    # 下载版本由 $AghVersion 决定（'local' 时回退到 latest release）。
    [switch]$DownloadBinary,

    # 目标架构，仅当 $DownloadBinary 时生效。
    [ValidateSet('arm64', 'arm', 'amd64')]
    [string]$Arch = 'arm64'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Stage = Join-Path $Root 'dist/stage/AdGuardHomeFree'
$OutDir = Join-Path $Root 'dist'
$Artifact = Join-Path $OutDir "AdGuardHomeFree-$AghVersion-module.zip"

$AghRepo = 'AdguardTeam/AdGuardHome'

function Write-Step([string]$Message) {
    Write-Host "==> $Message"
}

function Write-Err([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# 可选：下载 AdGuard Home 官方二进制（与 CI workflow 保持一致的资产命名规则）
# ---------------------------------------------------------------------------
function Get-AdGuardHomeBinary {
    param([string]$Version, [string]$TargetArch)

    $assetMap = @{
        arm64 = 'AdGuardHome_linux_arm64.tar.gz'
        arm   = 'AdGuardHome_linux_armv7.tar.gz'
        amd64 = 'AdGuardHome_linux_amd64.tar.gz'
    }
    $asset = $assetMap[$TargetArch]
    if (-not $asset) {
        Write-Err "Unsupported arch: $TargetArch"
        throw "Unsupported arch: $TargetArch"
    }

    $dest = Join-Path $Root "bin/AdGuardHome"
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("agh-dl-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    try {
        $url = "https://github.com/$AghRepo/releases/download/v$Version/$asset"
        Write-Step "Downloading AdGuard Home v$Version ($asset)"
        # GitHub 发布资产在部分地区较慢，加大超时并重试
        $dlErr = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmpDir 'agh.tar.gz') -UseBasicParsing -TimeoutSec 300
                $dlErr = $null
                break
            } catch {
                $dlErr = $_
                Write-Warning "下载第 $attempt 次失败：$($_.Exception.Message)"
                Start-Sleep -Seconds 5
            }
        }
        if ($dlErr) { throw "下载 AdGuard Home 二进制失败：$($dlErr.Exception.Message)" }

        Write-Step "Extracting"
        tar -xzf (Join-Path $tmpDir 'agh.tar.gz') -C $tmpDir
        # 包内可能是裸二进制 AdGuardHome，也可能含子目录，递归查找
        $bin = Get-ChildItem -Path $tmpDir -Recurse -File |
            Where-Object { $_.Name -eq 'AdGuardHome' -or $_.Name -like 'AdGuardHome-*' } |
            Select-Object -First 1
        if (-not $bin) {
            Write-Err "AdGuardHome binary not found in archive"
            throw "AdGuardHome binary not found in archive"
        }

        # 校验：读取 ELF 魔数（0x7F 'E' 'L' 'F'），不依赖外部 `file` 命令
        $head = [System.IO.File]::ReadAllBytes($bin.FullName)
        $isElf = ($head.Length -ge 4 -and
                  $head[0] -eq 0x7F -and
                  $head[1] -eq 0x45 -and  # E
                  $head[2] -eq 0x4C -and  # L
                  $head[3] -eq 0x46)      # F
        if (-not $isElf) {
            Write-Err "Downloaded file is not an ELF binary (bad magic): $($bin.FullName)"
            throw "Downloaded file is not an ELF binary"
        }

        New-Item -ItemType Directory -Force -Path (Join-Path $Root 'bin') | Out-Null
        Copy-Item -LiteralPath $bin.FullName -Destination $dest -Force
        Write-Step "Binary saved to bin/AdGuardHome ($($bin.Length) bytes)"
    }
    finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 校验 / 准备
# ---------------------------------------------------------------------------
$Required = @(
    'module.prop',
    'customize.sh',
    'post-fs-data.sh',
    'service.sh',
    'uninstall.sh',
    'sepolicy.rule',
    'bin/AdGuardHome.yaml',
    'scripts/common.sh',
    'scripts/iptables.sh',
    'scripts/watchdog.sh',
    'scripts/control.sh',
    'scripts/api.cgi',
    'webroot/index.html'
)

$Missing = @()
foreach ($Rel in $Required) {
    $Full = Join-Path $Root $Rel
    if (-not (Test-Path -LiteralPath $Full)) {
        $Missing += $Rel
    }
}
if ($Missing.Count -gt 0) {
    Write-Warning "缺少以下必需文件："
    $Missing | ForEach-Object { Write-Warning "  - $_" }
    Write-Error "请先补齐缺失文件，或使用 -DownloadBinary 让脚本自动获取 AdGuard Home 二进制。"
}

# 若二进制缺失：尝试下载，否则报错
$BinPath = Join-Path $Root 'bin/AdGuardHome'
if (-not (Test-Path -LiteralPath $BinPath)) {
    if ($DownloadBinary) {
        $dlVer = if ($AghVersion -eq 'local') {
            Write-Step "AghVersion=local，解析 GitHub latest release..."
            $resp = Invoke-RestMethod -Uri "https://api.github.com/repos/$AghRepo/releases/latest" -Headers @{ 'User-Agent' = 'AdGuardHomeFree-build' }
            ($resp.tag_name -replace '^v', '')
        } else {
            ($AghVersion -replace '^v', '')
        }
        Get-AdGuardHomeBinary -Version $dlVer -TargetArch $Arch
        # 把解析出的真实版本回写到 $AghVersion：否则 -DownloadBinary 下产物仍叫
        # AdGuardHomeFree-local-module.zip，与 CI 的 AdGuardHomeFree-<ver>-module.zip
        # 以及 update.json 的 zipUrl 全都对不上，用户会拿到一个「看起来不是正式版」的包。
        $AghVersion = $dlVer
        $Artifact = Join-Path $OutDir "AdGuardHomeFree-$AghVersion-module.zip"
    } else {
        Write-Error "未找到 bin/AdGuardHome。请将 arm64 可执行文件放入 bin\AdGuardHome，或使用 -DownloadBinary 自动下载。"
    }
}

# 确保二进制可执行（ZIP 打包后由 customize.sh 再 chmod，这里也兜底）
if (-not (Test-Path -LiteralPath $BinPath)) {
    Write-Error "bin/AdGuardHome 仍缺失，无法继续。"
}

# ---------------------------------------------------------------------------
# 归一化 shell 脚本的行尾与 BOM（与 CI 的 "Normalize shell script line endings to LF" 对齐）
# ---------------------------------------------------------------------------
# 这些 .sh 由 Android 的 sh 解析，customize.sh 更是被安装器 source 进安装器自己的
# shell。Windows 上编辑后若带 CRLF，\r 会被当成命令/参数的一部分，表现为
# "'\r': not found" 之类的诡异报错；被 source 的脚本尤其致命。
# CI 已有该步骤，本地打包同样需要，否则会出现「CI 打的包能装、本地打的装不上」。
# 按字节处理（去 BOM + 去掉所有 CR），不解码重编码，避免破坏 UTF-8 中文注释。
Write-Step 'Normalizing shell script line endings (LF, no BOM)'
$ShFiles = @(
    'customize.sh',
    'post-fs-data.sh',
    'service.sh',
    'uninstall.sh',
    'scripts/common.sh',
    'scripts/iptables.sh',
    'scripts/watchdog.sh',
    'scripts/control.sh',
    'scripts/api.cgi'
)
foreach ($Rel in $ShFiles) {
    $Full = Join-Path $Root $Rel
    if (-not (Test-Path -LiteralPath $Full)) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($Full)
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $start = 3
    }
    $changed = ($start -ne 0)
    $out = New-Object 'System.Collections.Generic.List[byte]'
    for ($i = $start; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0D) { $changed = $true; continue }
        $out.Add($bytes[$i])
    }
    if ($changed) {
        [System.IO.File]::WriteAllBytes($Full, $out.ToArray())
        Write-Host "  normalized: $Rel"
    }
}

# ---------------------------------------------------------------------------
# 打包
# ---------------------------------------------------------------------------
Write-Step "Cleaning dist"
if (Test-Path -LiteralPath $OutDir) {
    Remove-Item -LiteralPath $OutDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

Write-Step "Copying module files"
$CopyItems = @(
    'module.prop',
    'customize.sh',
    'post-fs-data.sh',
    'service.sh',
    'uninstall.sh',
    'sepolicy.rule',
    'update.json',
    'NOTICE'
)
foreach ($Rel in $CopyItems) {
    $src = Join-Path $Root $Rel
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $Stage -Force
    }
}

New-Item -ItemType Directory -Force -Path (Join-Path $Stage 'bin') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Stage 'scripts') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Stage 'webroot') | Out-Null

Copy-Item -LiteralPath (Join-Path $Root 'bin/AdGuardHome.yaml') -Destination (Join-Path $Stage 'bin') -Force
if (Test-Path -LiteralPath $BinPath) {
    Copy-Item -LiteralPath $BinPath -Destination (Join-Path $Stage 'bin') -Force
}
foreach ($Rel in @('scripts/common.sh', 'scripts/iptables.sh', 'scripts/watchdog.sh', 'scripts/control.sh', 'scripts/api.cgi')) {
    Copy-Item -LiteralPath (Join-Path $Root $Rel) -Destination (Join-Path $Stage 'scripts') -Force
}

$WebRoot = Join-Path $Root 'webroot'
if (Test-Path -LiteralPath $WebRoot) {
    # 注意：必须用 -Path（而非 -LiteralPath）才能展开通配符 *，
    # 否则 index.html 不会被打包进去。
    Copy-Item -Path (Join-Path $WebRoot '*') -Destination (Join-Path $Stage 'webroot') -Force
}

# build-info.txt
$BuildTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$Commit = 'local'
try {
    $Commit = (git -C $Root rev-parse HEAD 2>$null).Trim()
    if ([string]::IsNullOrWhiteSpace($Commit)) { $Commit = 'local' }
} catch {
    $Commit = 'local'
}
$BuildInfo = @('module_id=adguardhomefree', "agh_version=$AghVersion", "build_time=$BuildTime", "commit=$Commit")
# 必须写成「无 BOM 的 UTF-8」：PowerShell 5.1 的 Set-Content -Encoding utf8 会写入
# BOM(EF BB BF)，Android 端 grep '^agh_version=' 首行匹配失败，模块 WebUI 版本显示
# 会退化成 module.prop 的值。UTF8Encoding($false) 在 5.1 / 7.x 下行为一致。
$BuildInfoPath = Join-Path $Stage 'build-info.txt'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($BuildInfoPath, (($BuildInfo -join "`n") + "`n"), $Utf8NoBom)

Write-Step "Creating ZIP"
if (Test-Path -LiteralPath $Artifact) {
    Remove-Item -LiteralPath $Artifact -Force
}

# 必须生成“正斜杠、无 ./ 前缀”的 ZIP 条目，Magisk/KernelSU/APatch 的安装器用 unzip
# 按 module.prop 精确匹配；Windows 的 Compress-Archive 会写入反斜杠（bin\AdGuardHome），
# 导致模块结构损坏。这里用系统自带 tar（bsdtar）打包，条目为 module.prop、bin/…、scripts/…
# （目录以 / 结尾）。执行位由 customize.sh 在安装时 chmod，不依赖 ZIP 中的 mode。
$ZipItems = @(
    'module.prop', 'customize.sh', 'post-fs-data.sh', 'service.sh', 'uninstall.sh',
    'sepolicy.rule', 'update.json', 'NOTICE', 'build-info.txt',
    'bin', 'scripts', 'webroot'
)
tar -a -cf $Artifact -C $Stage $ZipItems
if ($LASTEXITCODE -ne 0) {
    Write-Error "tar 打包失败（退出码 $LASTEXITCODE）。请确认系统 tar（bsdtar）可用。"
}

Write-Step "Package created"
Get-Item -LiteralPath $Artifact | Select-Object Name, Length | Format-Table -AutoSize

# 校验 ZIP 结构（正斜杠条目）
Write-Step "Verifying ZIP contents"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($Artifact)
try {
    $names = $zip.Entries | ForEach-Object { $_.FullName }
    foreach ($must in @('module.prop', 'customize.sh', 'service.sh', 'bin/AdGuardHome', 'scripts/common.sh', 'scripts/control.sh', 'webroot/index.html')) {
        if ($names -notcontains $must) {
            Write-Warning "ZIP 中缺少条目: $must"
        }
    }
    # 反斜杠条目检查（Magisk 无法正确解包）
    if ($names | Where-Object { $_ -match '\\' }) {
        Write-Error "ZIP 中含反斜杠条目，会导致 Magisk 安装失败！"
    }
    Write-Host "  ZIP entries: $($names.Count)"
} finally {
    $zip.Dispose()
}

# 额外产出一份无版本名副本：CI 的 Release 除带版本号的包之外，还会上传
# AdGuardHomeFree-module.zip 作为「始终指向最新」的资产，update.json 的 zipUrl
# 就指向它（releases/latest/download/AdGuardHomeFree-module.zip）。
# 本地打包同样产出一份，方便直接替换 Release 资产或验证自动更新链路。
$LatestArtifact = Join-Path $OutDir 'AdGuardHomeFree-module.zip'
if ($Artifact -ne $LatestArtifact) {
    Copy-Item -LiteralPath $Artifact -Destination $LatestArtifact -Force
    Write-Step "Latest alias -> $LatestArtifact"
}

Write-Step "Done -> $Artifact"
