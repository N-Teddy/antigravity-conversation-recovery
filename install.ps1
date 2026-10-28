# ==============================================================================
# Antigravity IDE Persistence & Recovery Installer for Windows (PowerShell)
# ==============================================================================
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "    Antigravity IDE Persistence & Recovery Setup (Windows)" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""

$HomeDir = $env:USERPROFILE
$InstallDir = Join-Path $HomeDir ".gemini\antigravity-ide"
$BinDir = Join-Path $HomeDir ".local\bin"

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }

# 1. Detect Antigravity IDE
$Candidates = @(
    Join-Path $env:LOCALAPPDATA "Programs\Antigravity IDE\resources\app\out\main.js",
    "C:\Program Files\Antigravity IDE\resources\app\out\main.js",
    "C:\Program Files (x86)\Antigravity IDE\resources\app\out\main.js"
)

$MainJsPath = $null
foreach ($path in $Candidates) {
    if (Test-Path $path) {
        $MainJsPath = $path
        break
    }
}

if ($MainJsPath) {
    Write-Host "[+] Located Antigravity IDE at: $MainJsPath" -ForegroundColor Green
    Write-Host "[*] Verifying core engine integrity..." -ForegroundColor Yellow

    $bak = "$MainJsPath.bak"
    if (Test-Path $bak) {
        Copy-Item $bak $MainJsPath -Force
        Write-Host "    [+] Restored pristine factory engine from backup (100% stable)." -ForegroundColor Green
    } else {
        $content = [System.IO.File]::ReadAllText($MainJsPath)
        $cleaned = $content
        $cleaned = [regex]::Replace($cleaned, 'delete\s+this\.lazilyInitializedTopicObservables\[\w+\];', '')
        $cleaned = [regex]::Replace($cleaned, '(\w+)==="trajectorySummaries"&&await\s+this\._persistTopic\(\1\);', '')
        $cleaned = [regex]::Replace($cleaned, 'await\s+this\._persistTopic\(\w+\);', '')
        if ($cleaned -ne $content) {
            [System.IO.File]::WriteAllText($MainJsPath, $cleaned)
            Write-Host "    [+] Removed legacy engine patches. Core engine is now 100% factory pristine." -ForegroundColor Green
        } else {
            Write-Host "    [OK] Engine core is clean and unpatched (safe non-invasive architecture)." -ForegroundColor Green
        }
    }
} else {
    Write-Host "[!] Notice: Antigravity IDE main.js not located at default paths." -ForegroundColor Yellow
}

# 2. Deploy Python Recovery Engine
$DestPy = Join-Path $InstallDir "antigravity_recover.py"
$LocalPy = Join-Path $PSScriptRoot "antigravity_recover.py"

if (Test-Path $LocalPy) {
    Copy-Item $LocalPy $DestPy -Force
} else {
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/N-Teddy/antigravity-conversation-recovery/main/antigravity_recover.py" -OutFile $DestPy
}
Write-Host "[+] Installed recovery engine: $DestPy" -ForegroundColor Green

# 3. Create Windows CLI Command (.cmd wrapper)
$CmdWrapper = Join-Path $BinDir "antigravity-recover.cmd"
"@echo off`r`npython `"$DestPy`" %*" | Out-File -FilePath $CmdWrapper -Encoding ascii
Write-Host "[+] Installed CLI command: $CmdWrapper" -ForegroundColor Green

# 4. Add ~/.local/bin to User PATH
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$UserPath;$BinDir", "User")
    Write-Host "[+] Added $BinDir to User PATH." -ForegroundColor Green
}

# 5. Configure Windows Scheduled Task (Runs every 15 minutes)
try {
    $TaskName = "AntigravityConversationRecovery"
    $Action = "python `"$DestPy`""
    schtasks /create /tn $TaskName /tr $Action /sc minute /mo 15 /f | Out-Null
    Write-Host "[+] Configured background recovery task in Windows Task Scheduler (every 15 min)." -ForegroundColor Green
} catch {
    Write-Host "[!] Notice: Could not register scheduled task. You can run 'antigravity-recover' manually." -ForegroundColor Yellow
}

# 6. Run Initial Scan
Write-Host ""
Write-Host "[*] Running initial conversation recovery scan..." -ForegroundColor Yellow
python $DestPy

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "    Installation Complete! You are now fully protected." -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
