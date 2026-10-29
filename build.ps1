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
    'scripts/watchdog.sh'
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
    } else {
        Write-Error "未找到 bin/AdGuardHome。请将 arm64 可执行文件放入 bin\AdGuardHome，或使用 -DownloadBinary 自动下载。"
    }
}

# 确保二进制可执行（ZIP 打包后由 customize.sh 再 chmod，这里也兜底）
if (-not (Test-Path -LiteralPath $BinPath)) {
    Write-Error "bin/AdGuardHome 仍缺失，无法继续。"
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
$BuildInfo | Set-Content -LiteralPath (Join-Path $Stage 'build-info.txt') -Encoding utf8

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

Write-Step "Done -> $Artifact"
