# OpenBoss installer for Windows. Run in PowerShell:
#
#   irm https://raw.githubusercontent.com/woohahahaaa/openboss-releases/main/install.ps1 | iex
#
# 安装脚本做这些事：下载最新发行版、校验 SHA256、装到固定目录并加入用户
# PATH、注册登录自启（任务计划程序）、在桌面放 OpenBoss 快捷方式（发行包里
# 带 WinForms + WebView2 外壳时）。重复执行即为升级。
#
# 环境变量：
#   $env:OPENBOSS_HOME            安装根目录（默认 %LOCALAPPDATA%\OpenBoss）
#   $env:OPENBOSS_NO_SERVICE=1    跳过自启任务注册
#   $env:OPENBOSS_NO_DESKTOP=1    跳过桌面快捷方式
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

    if ($env:OPENBOSS_NO_DESKTOP -ne "1") {
        $ShellSrc = Join-Path $Work "OpenBoss"
        if (Test-Path (Join-Path $ShellSrc "OpenBoss.exe")) {
            Say "installing desktop app ..."
            $ShellDst = Join-Path $AppDir "OpenBoss"
            $ShellExe = Join-Path $ShellDst "OpenBoss.exe"
            # 升级时先关掉正在运行的外壳；只关路径匹配的那个，别误伤后端
            # openboss.exe（PowerShell 名字匹配不区分大小写）。
            Get-Process -Name "OpenBoss" -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    if ($_.Path -eq $ShellExe) { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
                } catch { }
            }
            Remove-Item $ShellDst -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $ShellDst) {
                Say "WARN: could not clear $ShellDst (desktop app still running?); skipping the desktop app"
            } else {
                New-Item -ItemType Directory -Path $ShellDst -Force | Out-Null
                # 拷目录内容而不是整个目录：目标已存在时 Copy-Item 会把源目录再
                # 套一层（app\OpenBoss\OpenBoss\...），外壳就会因缺 dll 起不来。
                Copy-Item (Join-Path $ShellSrc "*") $ShellDst -Recurse -Force

                $Missing = @()
                foreach ($f in "OpenBoss.exe", "Microsoft.Web.WebView2.Core.dll", "Microsoft.Web.WebView2.WinForms.dll", "WebView2Loader.dll") {
                    $p = Join-Path $ShellDst $f
                    if (-not (Test-Path $p) -or (Get-Item $p).Length -le 0) { $Missing += $f }
                }
                if ($Missing.Count -gt 0) {
                    Say ("WARN: desktop app files are incomplete (" + ($Missing -join ", ") + "); skipping the shortcut")
                } else {
                    $Desktop = [Environment]::GetFolderPath("Desktop")
                    if (Test-Path $Desktop) {
                        $Link = Join-Path $Desktop "OpenBoss.lnk"
                        $Made = $false
                        try {
                            $Ws = New-Object -ComObject WScript.Shell
                            $Shortcut = $Ws.CreateShortcut($Link)
                            $Shortcut.TargetPath = $ShellExe
                            $Shortcut.WorkingDirectory = $ShellDst
                            $Shortcut.IconLocation = "$ShellExe,0"
                            $Shortcut.Description = "OpenBoss 控制台"
                            $Shortcut.Save()
                            $Made = $true
                        } catch { }
                        if (-not $Made) {
                            # 受限会话/安全软件不让直接往桌面写 .lnk：先在安装目录生成，
                            # 再交给资源管理器（Shell COM）复制过去。Shell COM 在个别
                            # 环境下会卡死，放到独立进程里跑并限时 15 秒，卡了就放弃。
                            try {
                                $Staged = Join-Path $AppDir "OpenBoss.lnk"
                                $Ws = New-Object -ComObject WScript.Shell
                                $Shortcut = $Ws.CreateShortcut($Staged)
                                $Shortcut.TargetPath = $ShellExe
                                $Shortcut.WorkingDirectory = $ShellDst
                                $Shortcut.IconLocation = "$ShellExe,0"
                                $Shortcut.Description = "OpenBoss 控制台"
                                $Shortcut.Save()
                                $Helper = Join-Path $Work "copy-lnk.ps1"
                                Set-Content -LiteralPath $Helper -Encoding ASCII -Value (
                                    '(New-Object -ComObject Shell.Application).NameSpace("' + $Desktop +
                                    '").CopyHere("' + $Staged + '", 20)')
                                $Proc = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
                                    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $Helper)
                                if (-not $Proc.WaitForExit(15000)) { try { $Proc.Kill() } catch { } }
                                Start-Sleep -Milliseconds 600
                                $Made = Test-Path $Link
                            } catch { }
                        }
                        if ($Made) { Say "desktop app: $Link" }
                        else { Say "WARN: could not create the desktop shortcut" }
                    }
                }
            }
        }
    }

    if ($env:OPENBOSS_NO_SERVICE -ne "1") {
        Say "registering autostart ..."
        $InstallCode = 0
        try {
            & $Exe service install
            $InstallCode = $LASTEXITCODE
        } catch {
            if ($LASTEXITCODE) { $InstallCode = $LASTEXITCODE } else { $InstallCode = 1 }
        }
        # 以「任务计划或启动文件夹里真实存在」为准，而不是只看返回值：360 等
        # 安全软件会拒绝指向未签名 exe 的计划任务，这时后端走启动文件夹兜底。
        $Task = Get-ScheduledTask -TaskName "OpenBoss" -ErrorAction SilentlyContinue
        $StartupVbs = Join-Path ([Environment]::GetFolderPath("Startup")) "OpenBoss.vbs"
        if (-not $Task -and -not (Test-Path $StartupVbs)) {
            # Go 侧写启动文件夹也被安全软件拦（它会拦未签名进程写启动项）时，
            # 安装器自己写：PowerShell 是受信任的脚本宿主，通常能过。
            $Line = 'CreateObject("WScript.Shell").Run """' + $Exe + '"" up --supervise", 0, False'
            $LastErr = ""
            try {
                Set-Content -LiteralPath $StartupVbs -Value $Line -Encoding Unicode -ErrorAction Stop
            } catch { $LastErr = $_.Exception.Message }
            if (-not (Test-Path $StartupVbs)) {
                try {
                    [System.IO.File]::WriteAllText($StartupVbs, $Line, [System.Text.Encoding]::Unicode)
                } catch { $LastErr = $_.Exception.Message }
            }
            if (-not (Test-Path $StartupVbs)) {
                # 直写被拦：先在安装目录生成，再交给资源管理器复制（独立进程 +
                # 15 秒限时，Shell COM 在个别环境会卡死）。
                try {
                    $StagedVbs = Join-Path $AppDir "OpenBoss.vbs"
                    [System.IO.File]::WriteAllText($StagedVbs, $Line, [System.Text.Encoding]::Unicode)
                    $Helper = Join-Path $Work "copy-vbs.ps1"
                    Set-Content -LiteralPath $Helper -Encoding ASCII -Value (
                        '(New-Object -ComObject Shell.Application).NameSpace("' +
                        [Environment]::GetFolderPath("Startup") + '").CopyHere("' + $StagedVbs + '", 20)')
                    $Proc = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
                        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $Helper)
                    if (-not $Proc.WaitForExit(15000)) { try { $Proc.Kill() } catch { } }
                    Start-Sleep -Milliseconds 600
                } catch { $LastErr = $_.Exception.Message }
            }
            if (Test-Path $StartupVbs) {
                Say "autostart: wrote the Startup folder launcher (the task scheduler was blocked)"
                & $Exe up | Out-Null
            } else {
                Say ("WARN: could not write the Startup folder launcher: " + $LastErr)
            }
        }
        if (-not $Task -and -not (Test-Path $StartupVbs)) {
            # 全部失败：安全软件（典型是 360 主动防御）拦住了自启注册。后端仍然
            # 立即可用，自启需要用户在安全软件里放行一次；报错保持响亮但给出路径。
            & $Exe up | Out-Null
            throw ("autostart was NOT registered (service install exit $InstallCode). " +
                   "安全软件（如 360 主动防御）拦截了自启注册：请把 $Exe 加入信任区/白名单后重跑安装，" +
                   "或手动在启动文件夹放一个指向它的快捷方式。后端本次已启动，控制台可直接使用。")
        }
        if ($Task -and $Task.State -eq "Running") {
            Say "autostart ready - backend starts automatically after logon"
        } elseif ($Task) {
            Say "autostart registered - task is in place, starts at next logon"
            Say "start it now with: $Exe service start"
        } else {
            Say "autostart registered - Startup folder fallback is in place, starts at next logon"
            Say "start it now with: $Exe service start"
        }
    }

    Say ("done: openboss " + (& $Exe version))
    Say "web console: http://127.0.0.1:18799"
} finally {
    Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
}
