[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$AghVersion = 'local'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Stage = Join-Path $Root 'dist/stage/AdGuardHomeFree'
$OutDir = Join-Path $Root 'dist'
$Artifact = Join-Path $OutDir "AdGuardHomeFree-$AghVersion-module.zip"

function Write-Step([string]$Message) {
    Write-Host "==> $Message"
}

$Required = @(
    'module.prop',
    'customize.sh',
    'post-fs-data.sh',
    'service.sh',
    'uninstall.sh',
    'sepolicy.rule',
    'bin/AdGuardHome',
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
    Write-Error "请先补齐缺失文件，例如将 AdGuard Home arm64 可执行文件放入 bin\AdGuardHome 后重试。"
}

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
    'sepolicy.rule'
)
foreach ($Rel in $CopyItems) {
    Copy-Item -LiteralPath (Join-Path $Root $Rel) -Destination $Stage -Force
}

New-Item -ItemType Directory -Force -Path (Join-Path $Stage 'bin') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Stage 'scripts') | Out-Null

foreach ($Rel in @('bin/AdGuardHome', 'bin/AdGuardHome.yaml')) {
    Copy-Item -LiteralPath (Join-Path $Root $Rel) -Destination (Split-Path (Join-Path $Stage $Rel) -Parent) -Force
}
foreach ($Rel in @('scripts/common.sh', 'scripts/iptables.sh', 'scripts/watchdog.sh')) {
    Copy-Item -LiteralPath (Join-Path $Root $Rel) -Destination (Split-Path (Join-Path $Stage $Rel) -Parent) -Force
}

$WebRoot = Join-Path $Root 'webroot'
if (Test-Path -LiteralPath $WebRoot) {
    Copy-Item -LiteralPath $WebRoot -Destination $Stage -Recurse -Force
}

$BuildTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$Commit = ''
try {
    $Commit = git -C $Root rev-parse HEAD 2>$null
} catch {
}
if ([string]::IsNullOrWhiteSpace($Commit)) {
    $Commit = 'local'
}

$BuildInfo = @('module_id=adguardhomefree', "agh_version=$AghVersion", "build_time=$BuildTime", "commit=$Commit")
$BuildInfo | Set-Content -LiteralPath (Join-Path $Stage 'build-info.txt') -Encoding utf8

Write-Step "Creating ZIP"
if (Test-Path -LiteralPath $Artifact) {
    Remove-Item -LiteralPath $Artifact -Force
}
Compress-Archive -LiteralPath (Join-Path $Stage '*') -DestinationPath $Artifact -Force

Write-Step "Package created"
Write-Host $Artifact
Get-ChildItem -LiteralPath $Artifact | Select-Object Name, Length | Format-Table -AutoSize

