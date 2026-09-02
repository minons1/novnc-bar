#!/bin/bash
# Installs the noVNC LaunchAgent (com.novnc.proxy):
#   websockify + noVNC web root on 127.0.0.1:6080  ->  VNC server on 127.0.0.1:5900
# Starts at login, restarts on crash. Loopback-only listener.
#
# Env override: NOVNC_DIR defaults to ~/novnc (see README “How the pieces fit”).
set -euo pipefail

NOVNC_DIR="${NOVNC_DIR:-$HOME/novnc}"
PROXY="$NOVNC_DIR/utils/novnc_proxy"
UID_="$(id -u)"
PLIST="$HOME/Library/LaunchAgents/com.novnc.proxy.plist"

[[ -x "$PROXY" ]] || {
    echo "noVNC not found at $NOVNC_DIR — clone it first (README §1)" >&2
    exit 1
}

# websockify is fetched into utils/websockify on the proxy's first run;
# do the equivalent fetch up-front so the agent starts cleanly.
[[ -d "$NOVNC_DIR/utils/websockify" ]] || \
    git clone --depth 1 https://github.com/novnc/websockify.git \
        "$NOVNC_DIR/utils/websockify"

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.novnc.proxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PROXY</string>
        <string>--vnc</string><string>localhost:5900</string>
        <string>--listen</string><string>localhost:6080</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$NOVNC_DIR/novnc_proxy.log</string>
    <key>StandardErrorPath</key><string>$NOVNC_DIR/novnc_proxy.log</string>
</dict>
</plist>
EOF

# (Re)load
launchctl bootout "gui/$UID_" com.novnc.proxy 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$PLIST"

sleep 1
echo "• $(launchctl print "gui/$UID_/com.novnc.proxy" | grep -m1 'state =')"
echo "• Installed $PLIST"
