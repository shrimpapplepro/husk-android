#!/bin/zsh
# Install the HuskDroid companion on this Mac: code under ~/.local/share/huskdroid (not on the build
# volume, which may not be mounted at login), huskctl and huskjit-net in ~/.local/bin, and a LaunchAgent
# that runs the companion with its token from the vault.
set -eu
HERE=${0:A:h}
PY=$HOME/.local/share/uv/tools/pymobiledevice3/bin/python   # pymobiledevice3's own interpreter
DEST=$HOME/.local/share/huskdroid
AGENT=$HOME/Library/LaunchAgents/com.shrimpapplepro.huskdroid.companion.plist
VAULT=$HOME/.local/bin/perlica-secret

[[ -x $PY ]] || { echo "pymobiledevice3 missing: uv tool install pymobiledevice3"; exit 1; }
$VAULT check huskdroid.token >/dev/null || { echo "no huskdroid.token in the vault: perlica-secret set huskdroid.token"; exit 1; }

mkdir -p $DEST $HOME/.local/bin $HOME/Library/Logs/HuskDroid
cp $HERE/companion.py $HERE/huskjit_core.py $DEST/
install -m 755 $HERE/huskctl $HOME/.local/bin/huskctl
cat > $HOME/.local/bin/huskjit-net <<EOF
#!$PY
# Grant JIT from the command line (no companion needed): huskjit-net [NAME] [--probe]
import asyncio, sys
sys.path.insert(0, "$DEST")
import huskjit_core
args = [a for a in sys.argv[1:] if not a.startswith("--")]
try:
    asyncio.run(huskjit_core.grant(name=args[0] if args else "HuskDroid", probe="--probe" in sys.argv,
                                   log=lambda m: print(m, flush=True)))
except huskjit_core.JitError as e:
    sys.exit(f"ERROR: {e}")
EOF
chmod 755 $HOME/.local/bin/huskjit-net

cat > $AGENT <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.shrimpapplepro.huskdroid.companion</string>
  <key>ProgramArguments</key>
  <array>
    <string>$VAULT</string><string>run</string><string>huskdroid.token</string><string>--</string>
    <string>$PY</string><string>$DEST/companion.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/HuskDroid/companion.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/HuskDroid/companion.err.log</string>
</dict>
</plist>
EOF
launchctl bootout gui/$(id -u)/com.shrimpapplepro.huskdroid.companion 2>/dev/null || true
launchctl bootstrap gui/$(id -u) $AGENT
echo "companion installed; huskctl status to check"
