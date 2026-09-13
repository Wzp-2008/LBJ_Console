[CmdletBinding()]
param(
    [string]$Serial = $env:ANDROID_SERIAL,
    [string]$TestPath = 'integration_test/app_flow_test.dart',
    [int]$InstallTimeout = 180
)

$ErrorActionPreference = 'Stop'

$packageName = 'org.noxylva.lbjconsole.flutter'
$proxy = 'http://127.0.0.1:7890'
$runtimePermissions = @(
    'android.permission.BLUETOOTH_SCAN',
    'android.permission.BLUETOOTH_CONNECT',
    'android.permission.BLUETOOTH_ADVERTISE',
    'android.permission.ACCESS_FINE_LOCATION',
    'android.permission.ACCESS_COARSE_LOCATION',
    'android.permission.POST_NOTIFICATIONS'
)
$appOps = @(
    'BLUETOOTH_SCAN',
    'BLUETOOTH_CONNECT',
    'BLUETOOTH_ADVERTISE',
    'FINE_LOCATION',
    'COARSE_LOCATION',
    'POST_NOTIFICATION'
)

function Invoke-Adb {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & adb @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "adb $($Arguments -join ' ') 失败：$($output -join [Environment]::NewLine)"
    }
    return $output
}

if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    throw '找不到 adb，请先把 Android SDK platform-tools 加入 PATH。'
}

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw '找不到 flutter，请先把 Flutter 加入 PATH。'
}

if ([string]::IsNullOrWhiteSpace($Serial)) {
    $connected = @(
        (& adb devices | Select-Object -Skip 1) |
            Where-Object { $_ -match '^([^\s]+)\s+device\s*$' } |
            ForEach-Object { $Matches[1] }
    )
    if ($connected.Count -ne 1) {
        throw "未能唯一确定 Android 设备，请通过 -Serial 指定。当前设备数：$($connected.Count)"
    }
    $Serial = $connected[0]
}

Invoke-Adb @('-s', $Serial, 'wait-for-device') | Out-Null
Write-Host "使用 Android 设备：$Serial"

# Keep build traffic consistent with the repository instructions.
$env:HTTP_PROXY = $proxy
$env:HTTPS_PROXY = $proxy
$env:ALL_PROXY = $proxy

# Do not leave an older permission dialog in front of the new test run.
Invoke-Adb @('-s', $Serial, 'shell', 'am', 'force-stop', $packageName) | Out-Null

$flutter = (Get-Command flutter).Source
$flutterArgs = @(
    'test',
    $TestPath,
    '-d',
    $Serial
)

Write-Host '启动 Flutter 集成测试，并等待 APK 安装后自动预授权 Android 权限...'
$testProcess = Start-Process -FilePath $flutter -ArgumentList $flutterArgs -PassThru -NoNewWindow
$deadline = (Get-Date).AddSeconds($InstallTimeout)
$granted = $false
$stableGrantChecks = 0

function Grant-AndroidPermissions {
    foreach ($permission in $runtimePermissions) {
        # Clear MIUI's remembered denial state before granting it as root.
        & adb -s $Serial shell pm clear-permission-flags --user 0 $packageName $permission user-set user-fixed 2>$null | Out-Null
        & adb -s $Serial shell cmd package grant --user 0 $packageName $permission 2>$null | Out-Null
    }

    # MIUI also gates some Android permissions through AppOps. Grant both
    # layers so a successful pm grant cannot still be blocked by AppOps.
    foreach ($operation in $appOps) {
        & adb -s $Serial shell cmd appops set --user 0 $packageName $operation allow 2>$null | Out-Null
    }
}

function Test-AndroidPermissionsGranted {
    $details = (& adb -s $Serial shell dumpsys package $packageName 2>$null | Out-String)
    foreach ($permission in $runtimePermissions) {
        if ($details -notmatch ([regex]::Escape("${permission}: granted=true"))) {
            return $false
        }
    }
    return $true
}

function Close-PermissionDialogIfPresent {
    $windows = (& adb -s $Serial shell dumpsys window windows 2>$null | Out-String)
    if ($windows -match 'com\.lbe\.security\.miui/.+GrantPermissionsActivity') {
        Write-Host '已关闭 MIUI 残留权限弹窗（权限已由 root 预授权）。'
        & adb -s $Serial shell input keyevent 4 2>$null | Out-Null
        & adb -s $Serial shell am force-stop com.lbe.security.miui 2>$null | Out-Null
    }
}

try {
    while (-not $testProcess.HasExited -and (Get-Date) -lt $deadline) {
        $packagePath = (& adb -s $Serial shell pm path $packageName 2>$null | Out-String).Trim()
        if ($packagePath -match '^package:') {
            Grant-AndroidPermissions
            if (Test-AndroidPermissionsGranted) {
                $stableGrantChecks++
                if ($stableGrantChecks -le 4) {
                    Write-Host "权限已确认（连续确认 $stableGrantChecks/4）"
                } elseif ($stableGrantChecks -eq 5) {
                    Write-Host '权限守护持续生效，直到测试结束。'
                }
            } else {
                $stableGrantChecks = 0
            }

            if ($stableGrantChecks -ge 4) {
                $granted = $true
                Close-PermissionDialogIfPresent
            }
        }

        # Keep watching until Flutter exits. The Flutter tool reinstalls the
        # APK after the first package detection, and MIUI may reset runtime
        # permission state during that reinstall.
        Start-Sleep -Milliseconds 350
    }

    if (-not $granted) {
        Write-Warning "在 $InstallTimeout 秒内没有检测到已安装的 $packageName；测试将继续，由应用自行请求权限。"
    }

    $testProcess.WaitForExit()
    exit $testProcess.ExitCode
}
finally {
    if (-not $testProcess.HasExited) {
        $testProcess.Kill()
    }
}
