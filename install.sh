#!/usr/bin/env bash
# ==============================================================================
# Antigravity IDE Persistence & Conversation Recovery Installer
# Universal installer for Linux & macOS.
# ==============================================================================
set -e

echo ""
echo "=================================================================="
echo "    Antigravity IDE Persistence & Conversation Recovery Setup"
echo "=================================================================="
echo ""

UNAME_OS="$(uname -s)"
HOME_DIR="$HOME"
INSTALL_DIR="$HOME_DIR/.gemini/antigravity-ide"
BIN_DIR="$HOME_DIR/.local/bin"

mkdir -p "$BIN_DIR"
mkdir -p "$INSTALL_DIR"

# 1. Detect Antigravity IDE main.js
APP_MAIN_JS=""
CANDIDATES=(
  "/opt/antigravity-ide/resources/app/out/main.js"
  "/usr/lib/antigravity-ide/resources/app/out/main.js"
  "/usr/share/antigravity-ide/resources/app/out/main.js"
  "/Applications/Antigravity IDE.app/Contents/Resources/app/out/main.js"
  "$HOME_DIR/Applications/Antigravity IDE.app/Contents/Resources/app/out/main.js"
)

for p in "${CANDIDATES[@]}"; do
  if [ -f "$p" ]; then
    APP_MAIN_JS="$p"
    break
  fi
done

if [ -z "$APP_MAIN_JS" ]; then
  echo "[!] Notice: Antigravity IDE main.js not located at default paths."
  echo "    Proceeding with recovery engine installation..."
else
  echo "[+] Found Antigravity IDE at: $APP_MAIN_JS"
  echo "[*] Verifying/applying core engine patch..."

  python3 - << 'PYEOF'
import re, shutil, os

main_js_path = os.environ.get("APP_MAIN_JS", "")
if not main_js_path:
    for candidate in [
        "/opt/antigravity-ide/resources/app/out/main.js",
        "/usr/lib/antigravity-ide/resources/app/out/main.js",
        "/usr/share/antigravity-ide/resources/app/out/main.js",
        "/Applications/Antigravity IDE.app/Contents/Resources/app/out/main.js",
        os.path.expanduser("~/Applications/Antigravity IDE.app/Contents/Resources/app/out/main.js")
    ]:
        if os.path.exists(candidate):
            main_js_path = candidate
            break

if main_js_path and os.path.exists(main_js_path):
    with open(main_js_path, "r", encoding="utf-8") as f:
        text = f.read()

    modified = False

    # 1. Patch pushUpdate immediate persistence
    if "await this._persistTopic(" in text:
        print("    [OK] pushUpdate immediate persistence is already active.")
    else:
        pattern1 = re.compile(r'(this\._updateEmitters\[(\w+)\]\.emit\((\w+)\);)(return\s*\}\s*finally)')
        m1 = pattern1.search(text)
        if m1:
            topic_var = m1.group(2)
            text = pattern1.sub(r'\1await this._persistTopic(' + topic_var + r');\4', text, count=1)
            modified = True
            print(f"    [+] Patched pushUpdate for immediate disk flush.")
        else:
            print("    [!] Warning: pushUpdate pattern not found (different IDE version).")

    # 2. Patch initIPCSubscription dynamic reload
    if "delete this.lazilyInitializedTopicObservables[" in text:
        print("    [OK] initIPCSubscription dynamic reload is already active.")
    else:
        pattern2 = re.compile(r'(async\s+initIPCSubscription\((\w+)\)\s*\{[^{]*?try\s*\{)(const\s+\w+\s*=\s*await\s+this\._getOrCreateTopic\(\2\);)')
        m2 = pattern2.search(text)
        if m2:
            topic_var = m2.group(2)
            text = pattern2.sub(r'\1delete this.lazilyInitializedTopicObservables[' + topic_var + r'];\3', text, count=1)
            modified = True
            print(f"    [+] Patched initIPCSubscription for window reload.")
        else:
            print("    [!] Warning: initIPCSubscription pattern not found.")

    if modified:
        bak = main_js_path + ".bak"
        if not os.path.exists(bak):
            try:
                shutil.copy2(main_js_path, bak)
                print(f"    [+] Created backup: {bak}")
            except Exception as e:
                print(f"    [!] Could not create backup: {e}")
        try:
            with open(main_js_path, "w", encoding="utf-8") as f:
                f.write(text)
            print("    [+] Core engine successfully updated.")
        except PermissionError:
            print("    [!] Permission denied writing to main.js. Please run with appropriate permissions.")
PYEOF
fi

# 2. Install Python Recovery Engine
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
if [ -f "$SCRIPT_DIR/antigravity_recover.py" ]; then
  cp -f "$SCRIPT_DIR/antigravity_recover.py" "$INSTALL_DIR/antigravity_recover.py"
else
  # If piped from curl, download or fetch
  curl -fsSL "https://raw.githubusercontent.com/sevencommonfactor/antigravity-conversation-recovery/main/antigravity_recover.py" -o "$INSTALL_DIR/antigravity_recover.py" 2>/dev/null || true
fi
chmod +x "$INSTALL_DIR/antigravity_recover.py"
echo "[+] Installed recovery engine: $INSTALL_DIR/antigravity_recover.py"

# 3. Create CLI executable wrapper
cat << 'EOF_WRAPPER' > "$BIN_DIR/antigravity-recover"
#!/usr/bin/env bash
python3 "$HOME/.gemini/antigravity-ide/antigravity_recover.py" "$@"
EOF_WRAPPER
chmod +x "$BIN_DIR/antigravity-recover"
echo "[+] Installed CLI utility: $BIN_DIR/antigravity-recover"

# 4. Ensure ~/.local/bin is in PATH
for rc in "$HOME_DIR/.bashrc" "$HOME_DIR/.zshrc" "$HOME_DIR/.bash_profile"; do
  if [ -f "$rc" ]; then
    if ! grep -q "\\.local/bin" "$rc"; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
      echo "[+] Added ~/.local/bin to $rc"
    fi
  fi
done

# 5. Background Scheduled Recovery
if [ "$UNAME_OS" = "Linux" ] && command -v systemctl >/dev/null 2>&1; then
  SYSTEMD_DIR="$HOME_DIR/.config/systemd/user"
  mkdir -p "$SYSTEMD_DIR"

  cat << EOF_SVC > "$SYSTEMD_DIR/antigravity-recover.service"
[Unit]
Description=Antigravity IDE Conversation History Auto-Recovery
After=graphical-session.target

[Service]
Type=oneshot
ExecStart=$BIN_DIR/antigravity-recover
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF_SVC

  cat << EOF_TMR > "$SYSTEMD_DIR/antigravity-recover.timer"
[Unit]
Description=Periodic Check for Lost Antigravity IDE Conversations

[Timer]
OnBootSec=1min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF_TMR

  systemctl --user daemon-reload || true
  systemctl --user enable --now antigravity-recover.timer || true
  echo "[+] Configured automated background recovery via systemd timer."

elif [ "$UNAME_OS" = "Darwin" ]; then
  LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"
  mkdir -p "$LAUNCH_AGENTS_DIR"
  PLIST_PATH="$LAUNCH_AGENTS_DIR/com.antigravity.recover.plist"

  cat << EOF_PLIST > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.antigravity.recover</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/env</string>
        <string>python3</string>
        <string>$INSTALL_DIR/antigravity_recover.py</string>
    </array>
    <key>StartInterval</key>
    <integer>900</integer>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF_PLIST

  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load "$PLIST_PATH" 2>/dev/null || true
  echo "[+] Configured automated background recovery via launchd (macOS)."
fi

# 6. Verify and run scan
echo ""
"$BIN_DIR/antigravity-recover" --status
echo ""
echo "[*] Running initial recovery scan..."
"$BIN_DIR/antigravity-recover"

echo ""
echo "=================================================================="
echo "    Installation Complete! You are now fully protected."
echo "=================================================================="
