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
    Write-Host "[*] Checking core engine patch..." -ForegroundColor Yellow

    $content = [System.IO.File]::ReadAllText($MainJsPath)
    $modified = $false

    if ($content.Contains("await this._persistTopic(")) {
        Write-Host "    [OK] pushUpdate immediate persistence already active." -ForegroundColor Green
    } else {
        $pattern1 = [regex]'(this\._updateEmitters\[(\w+)\]\.emit\((\w+)\);)(return\s*\}\s*finally)'
        if ($pattern1.IsMatch($content)) {
            $content = $pattern1.Replace($content, '$1await this._persistTopic($2);$4', 1)
            $modified = $true
            Write-Host "    [+] Patched pushUpdate for immediate disk flush." -ForegroundColor Green
        }
    }

    if ($content.Contains("delete this.lazilyInitializedTopicObservables[")) {
        Write-Host "    [OK] initIPCSubscription dynamic reload already active." -ForegroundColor Green
    } else {
        $pattern2 = [regex]'(async\s+initIPCSubscription\((\w+)\)\s*\{[^{]*?try\s*\{)(const\s+\w+\s*=\s*await\s+this\._getOrCreateTopic\(\2\);)'
        if ($pattern2.IsMatch($content)) {
            $content = $pattern2.Replace($content, '$1delete this.lazilyInitializedTopicObservables[$2];$3', 1)
            $modified = $true
            Write-Host "    [+] Patched initIPCSubscription for window reload." -ForegroundColor Green
        }
    }

    if ($modified) {
        $bak = "$MainJsPath.bak"
        if (-not (Test-Path $bak)) {
            Copy-Item $MainJsPath $bak
            Write-Host "    [+] Backup created: $bak" -ForegroundColor Cyan
        }
        [System.IO.File]::WriteAllText($MainJsPath, $content)
        Write-Host "    [+] Core engine successfully updated." -ForegroundColor Green
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
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/sevencommonfactor/antigravity-conversation-recovery/main/antigravity_recover.py" -OutFile $DestPy
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
