# novnc-bar

A tiny native macOS menu bar app that starts/stops your **noVNC** server
and shows its live status — designed to pair with **tailscale serve**, so
your Mac's desktop is reachable from any browser on your tailnet over a
proper HTTPS URL.

```
┌──────────────────────────────────┐
│ ●  noVNC                          │   ← menu bar: colored status dot
└──────────────────────────────────┘
    noVNC: Running
    Stop noVNC Server            ⌘T
    Restart noVNC Server         ⌘R
    ─────────────────────────
    Open in Browser              ⌘U
    Copy URL                   ⇧⌘C
    View Log File                ⌘L
    ─────────────────────────
    Start noVNC Bar at Login
    ─────────────────────────
    Quit                         ⌘Q
```

## How the pieces fit together

```
iPad / any tailnet device
      │  https://<host>.<tailnet>.ts.net/vnc.html
      ▼
tailscale serve            (HTTPS, valid TLS cert, tailnet-only)
      │  http://127.0.0.1:6080
      ▼
websockify + noVNC         (LaunchAgent “com.novnc.proxy”)
      │  WebSocket → VNC, proxied to 127.0.0.1:5900
      ▼
macOS Screen Sharing
```

| Path | What it is |
|---|---|
| `~/novnc` | upstream [noVNC](https://github.com/novnc/novnc) clone — the served web root |
| `~/novnc-bar` | this repo — menu bar app sources |
| `/Applications/NoVNCBar.app` | installed build product |

## Prerequisites

- macOS 13+
- Xcode Command Line Tools: `xcode-select --install`
- [Tailscale](https://tailscale.com/download) installed and logged in

Handy alias for the tailscale CLI on macOS (add to `~/.zshrc`):

```bash
alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
```

## Setup

### 1. noVNC (upstream quick start)

```bash
git clone https://github.com/novnc/novnc.git ~/novnc
cd ~/novnc
./utils/novnc_proxy --vnc localhost:5900 --listen localhost:6080
# wait for “Navigate to this URL: http://localhost:6080/vnc.html”, then Ctrl-C
```

The first run downloads `websockify` into `~/novnc/utils/websockify`.

### 2. Run it as a background service

```bash
./scripts/install-launchagent.sh
```

Installs `~/Library/LaunchAgents/com.novnc.proxy.plist`: starts at login
(`RunAtLoad`), restarts on crash (`KeepAlive`), listens on loopback only.

Verify: `curl -o /dev/null -w "%{http_code}\n" http://localhost:6080/vnc.html` → `200`

### 3. Enable macOS Screen Sharing (VNC server on :5900)

```bash
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist
```

(GUI alternative: System Settings → General → Sharing → Screen Sharing → On)

noVNC supports Apple's Diffie-Hellman auth, so click **Connect** in the
browser and sign in with your normal Mac username & password — no legacy
VNC password required.

### 4. Expose it over HTTPS with tailscale serve

```bash
tailscale serve --bg http://localhost:6080
```

You now have `https://<your-host>.<tailnet>.ts.net/vnc.html` from any device
on your tailnet (`vnc.html` is noVNC's client entrypoint inside the web root;
browsing `/` serves the same directory). Check with `tailscale serve status`;
if Tailscale prints an admin approval link, open it once as the network owner.

### 5. Build & run the menu bar app

```bash
cd ~/novnc-bar
./build.sh --launch     # compile → /Applications/NoVNCBar.app → relaunch
```

### 6. (Optional) Start at Login

In the menu, click **Start noVNC Bar at Login** — a persistent login item
via `SMAppService`. The checkmark shows the current state.

## The URL (environment variable)

Menu actions **Open in Browser** and **Copy URL** use `NOVNC_URL`,
resolved at launch in this order:

1. **`NOVNC_URL` environment variable**
   ```bash
   # session-wide for GUI apps:
   launchctl setenv NOVNC_URL "https://host.tailnet.ts.net/vnc.html"

   # or run the binary directly so the shell passes the export through:
   NOVNC_URL="https://host.tailnet.ts.net/vnc.html" \
     /Applications/NoVNCBar.app/Contents/MacOS/NoVNCBar
   ```
   Note: GUI apps do **not** see `.zshrc` exports — use one of the two forms above.
2. **User default** (persists across reboots — easiest)
   ```bash
   defaults write io.github.minons1.novncbar NOVNC_URL \
     "https://host.tailnet.ts.net/vnc.html"
   ```
3. **Auto-detect** — with nothing configured, the app asks the tailscale CLI
   for this machine's MagicDNS name and uses `https://<name>/vnc.html`.
   Works out of the box on a standard setup.
4. **Fallback**: `http://localhost:6080/vnc.html`

## Status colors

| Menu bar dot | Meaning |
|---|---|
| 🟢 green | server running |
| 🔴 red | process keeps exiting — check the log (**View Log File ⌘L**) |
| ⚪ gray | stopped (toggled off for this session) |
| 🟠 orange | LaunchAgent plist missing — rerun the install script |

## Troubleshooting

- **Menu bar item not visible** — it's on the primary display's menu bar;
  macOS hides overflow items when the bar is crowded.
- **Changed noVNC JS in `~/novnc` but nothing happened** — hard-reload the
  page (`Cmd+Shift+R`); there's no cache-busting header.
- **Rebuilt the app, login item stopped** — the ad-hoc code signature
  changed; just re-toggle **Start noVNC Bar at Login**.
- **What does “Stop” mean?** — uses `launchctl bootout` (this session only).
  At next login, `RunAtLoad` starts the server again.

## Uninstall

```bash
launchctl bootout gui/$(id -u) com.novnc.proxy
rm ~/Library/LaunchAgents/com.novnc.proxy.plist
tailscale serve reset                      # optional: stop serving on the tailnet
rm -rf /Applications/NoVNCBar.app
```

## License

[MIT](LICENSE)
