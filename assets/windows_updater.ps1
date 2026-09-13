param(
    [Parameter(Mandatory = $true)]
    [string] $InstallDirectory,

    [Parameter(Mandatory = $true)]
    [string] $ZipPath,

    [Parameter(Mandatory = $true)]
    [string] $UpdateDirectory,

    [Parameter(Mandatory = $true)]
    [string] $Executable,

    [Parameter(Mandatory = $true)]
    [int] $ParentProcessId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logDirectory = Join-Path ([IO.Path]::GetTempPath()) 'LBJConsole'
$logPath = Join-Path $logDirectory 'updater.log'

function Write-UpdateLog {
    param([string] $Message)

    try {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $Message"
    }
    catch {
        # Logging must never prevent the fallback launch below.
    }
}

function Get-FullPath {
    param([string] $Path)

    return [IO.Path]::GetFullPath($Path)
}

function Fail-Update {
    param([string] $Message)

    Write-UpdateLog "ERROR: $Message"
    try {
        if (Test-Path -LiteralPath $Executable -PathType Leaf) {
            Start-Process -FilePath $Executable -WorkingDirectory $InstallDirectory | Out-Null
        }
    }
    catch {
        Write-UpdateLog "Fallback launch failed: $($_.Exception.Message)"
    }
    exit 1
}

try {
    $installFull = Get-FullPath $InstallDirectory
    $zipFull = Get-FullPath $ZipPath
    $updateFull = Get-FullPath $UpdateDirectory
    $executableFull = Get-FullPath $Executable
    $tempRoot = Get-FullPath (Join-Path ([IO.Path]::GetTempPath()) 'LBJConsole')

    if (-not (Test-Path -LiteralPath $installFull -PathType Container)) {
        throw "Install directory does not exist: $installFull"
    }

    $updateParent = Split-Path -Parent $updateFull
    if ($updateParent -ine $tempRoot) {
        throw 'Update directory is outside the protected temporary directory.'
    }

    $updateName = Split-Path -Leaf $updateFull
    if ($updateName -notmatch '^update_[^\\/:]+$') {
        throw 'Invalid update directory name.'
    }

    $zipParent = Split-Path -Parent $zipFull
    $zipName = Split-Path -Leaf $zipFull
    if (($zipParent -ine $updateFull) -or ($zipName -ine 'update.zip')) {
        throw 'Invalid update archive path.'
    }

    $markerPath = Join-Path $updateFull '.lbj-update-marker'
    $hasArchive = Test-Path -LiteralPath $zipFull -PathType Leaf
    $hasMarker = Test-Path -LiteralPath $markerPath -PathType Leaf
    if ((-not $hasArchive) -or (-not $hasMarker)) {
        throw 'Update archive or safety marker is missing.'
    }

    $executableParent = Split-Path -Parent $executableFull
    $executableName = Split-Path -Leaf $executableFull
    if (($executableParent -ine $installFull) -or ($executableName -ine 'lbjconsole.exe')) {
        throw 'Invalid application path.'
    }

    Write-UpdateLog "Update requested: $zipFull -> $installFull"

    # The Flutter process exits immediately after starting this script. Wait for
    # its files and native libraries to be released before replacing them.
    for ($attempt = 0; $attempt -lt 240; $attempt++) {
        $parent = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
        if ($null -eq $parent) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    $parentStillRunning = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
    if ($null -ne $parentStillRunning) {
        throw 'The application did not exit within the timeout.'
    }

    $stagingDirectory = Join-Path $updateFull 'staging'
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null

    Expand-Archive -LiteralPath $zipFull -DestinationPath $stagingDirectory -Force
    $stagedExecutable = Join-Path $stagingDirectory 'lbjconsole.exe'
    if (-not (Test-Path -LiteralPath $stagedExecutable -PathType Leaf)) {
        throw 'The update archive does not contain lbjconsole.exe.'
    }

    # Robocopy exit codes 0..7 indicate success or success with minor differences.
    # Do not copy the legacy native updater from old packages.
    & robocopy.exe $stagingDirectory $installFull /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /XF 'lbj_updater.exe' /NFL /NDL /NP | Out-Null
    $copyExitCode = $LASTEXITCODE
    if ($copyExitCode -ge 8) {
        throw "Copying update files failed, robocopy exit code: $copyExitCode"
    }

    $legacyUpdater = Join-Path $installFull 'lbj_updater.exe'
    if (Test-Path -LiteralPath $legacyUpdater -PathType Leaf) {
        Remove-Item -LiteralPath $legacyUpdater -Force
    }

    $cleanupArgument = '--lbj-cleanup-dir="' + $updateFull + '"'
    Start-Process -FilePath $executableFull -ArgumentList @($cleanupArgument) -WorkingDirectory $installFull | Out-Null
    Write-UpdateLog 'Update completed and the new application was started.'
    exit 0
}
catch {
    Fail-Update $_.Exception.Message
}
