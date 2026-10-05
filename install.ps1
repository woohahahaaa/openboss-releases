# OpenBoss installer for Windows. Run in PowerShell:
#
#   irm https://raw.githubusercontent.com/woohahahaaa/openboss-releases/main/install.ps1 | iex
#
# 安装脚本做四件事：下载最新发行版、校验 SHA256、装到固定目录并加入用户
# PATH、注册登录自启（任务计划程序）。重复执行即为升级。
#
# 环境变量：
#   $env:OPENBOSS_HOME            安装根目录（默认 %LOCALAPPDATA%\OpenBoss）
#   $env:OPENBOSS_NO_SERVICE=1    跳过自启任务注册
$ErrorActionPreference = "Stop"

$Base = "https://github.com/woohahahaaa/openboss-releases/releases/latest/download"
$Asset = "openboss-windows-amd64.zip"
$Root = if ($env:OPENBOSS_HOME) { $env:OPENBOSS_HOME } else { Join-Path $env:LOCALAPPDATA "OpenBoss" }
$AppDir = Join-Path $Root "app"
$Exe = Join-Path $AppDir "openboss.exe"

function Say([string]$Message) { Write-Host "[openboss] $Message" }

$Work = Join-Path $env:TEMP ("openboss-install-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
try {
    Say "downloading $Asset ..."
    Invoke-WebRequest -UseBasicParsing -Uri "$Base/$Asset" -OutFile (Join-Path $Work $Asset)
    Invoke-WebRequest -UseBasicParsing -Uri "$Base/SHA256SUMS" -OutFile (Join-Path $Work "SHA256SUMS")

    Say "verifying checksum ..."
    $Line = Select-String -Path (Join-Path $Work "SHA256SUMS") -Pattern ("\s+" + [regex]::Escape($Asset) + "$") | Select-Object -First 1
    if (-not $Line) { throw "$Asset is not listed in SHA256SUMS" }
    $Expected = ($Line.Line.Trim() -split '\s+')[0].ToLower()
    $Actual = (Get-FileHash (Join-Path $Work $Asset) -Algorithm SHA256).Hash.ToLower()
    if ($Actual -ne $Expected) { throw "checksum mismatch (got $Actual)" }

    Say "installing to $AppDir ..."
    # 升级时先把旧版停掉：运行中的 openboss.exe 文件被锁，覆盖会失败。
    if (Test-Path $Exe) {
        try { & $Exe service stop --quiet 2>$null | Out-Null } catch { }
    }
    Expand-Archive -Path (Join-Path $Work $Asset) -DestinationPath $Work -Force
    New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
    Copy-Item (Join-Path $Work "openboss.exe") $Exe -Force
    $EyeSrc = Join-Path $Work "EYE"
    if (Test-Path $EyeSrc) {
        $EyeDst = Join-Path $AppDir "EYE"
        Remove-Item $EyeDst -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item $EyeSrc $EyeDst -Recurse -Force
    }

    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($UserPath -notlike "*$AppDir*") {
        [Environment]::SetEnvironmentVariable("Path", ($AppDir + ";" + $UserPath), "User")
        Say "added $AppDir to the user PATH (takes effect in new terminals)"
    }

    if ($env:OPENBOSS_NO_SERVICE -ne "1") {
        Say "registering autostart task ..."
        & $Exe service install
    }

    Say ("done: openboss " + (& $Exe version))
    Say "web console: http://127.0.0.1:18799"
} finally {
    Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
}
