// noVNC Bar — a tiny macOS menu bar app to control the noVNC LaunchAgent.
// Built with the system Swift toolchain (no Xcode project needed).
//
// Status logic:
//   poll `launchctl print gui/$UID/com.novnc.proxy` every 2s
//   "state = running"  -> Running
//   job not in domain  -> Stopped (toggled off or not bootstrapped)
//   plist missing      -> LaunchAgent missing
// Toggle: bootout (stop completely for this session) / bootstrap (start).

import AppKit
import Foundation
import ServiceManagement

// MARK: - Configuration

enum Config {
    static let agentLabel = "com.novnc.proxy"
    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/" + agentLabel + ".plist"
    }
    /// websockify + noVNC web root served by the LaunchAgent
    static let listenHost = "127.0.0.1"
    static let listenPort = 6080
    static var logPath: String { NSHomeDirectory() + "/novnc/novnc_proxy.log" }
    static var launchdDomain: String { "gui/\(getuid())" }

    /// Optional `.env` file — simple `KEY=VALUE` lines (see README):
    static var envFilePath: String {
        NSHomeDirectory() + "/.config/novnc-bar/.env"
    }
    static let envFile: [String: String] = parseEnvFile(envFilePath)

    /// URL for “Open in Browser” / “Copy URL”, resolved at launch:
    ///   1. `NOVNC_URL` environment variable
    ///        launchctl setenv NOVNC_URL "https://host.ts.net/vnc.html"
    ///   2. `NOVNC_URL`, else `NOVNC_HOST` (MagicDNS name), from the `.env`
    ///      file — host becomes https://<host>/vnc.html
    ///   3. `NOVNC_URL` user default — e.g.
    ///        defaults write io.github.minons1.novncbar NOVNC_URL "https://…"
    ///   4. auto-detect: MagicDNS name of this machine via the tailscale CLI
    ///   5. fallback: just use localhost:6080
    static let serveURL: String = {
        if let env = ProcessInfo.processInfo.environment["NOVNC_URL"],
           !env.isEmpty {
            return env
        }
        if let url = envFile["NOVNC_URL"], !url.isEmpty {
            return url
        }
        if let host = envFile["NOVNC_HOST"], !host.isEmpty {
            return "https://\(host)/vnc.html"
        }
        if let stored = UserDefaults.standard.string(forKey: "NOVNC_URL"),
           !stored.isEmpty {
            return stored
        }
        if let dns = tailscaleDNSName() {
            return "https://\(dns)/vnc.html"
        }
        return "http://localhost:\(listenPort)/vnc.html"
    }()
}

/// Minimal `.env` parser: `KEY=VALUE` lines, `#` comments, optional
/// surrounding quotes. Unparseable lines are ignored.
private func parseEnvFile(_ path: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8)
    else { return [:] }
    var dict: [String: String] = [:]
    for rawLine in text.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#"),
              let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var value = String(line[line.index(after: eq)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) ||
           (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
            value = String(value.dropFirst().dropLast())
        }
        if !key.isEmpty {
            dict[key] = value
        }
    }
    return dict
}

/// Best-effort detection of this machine's tailscale MagicDNS name.
private func tailscaleDNSName() -> String? {
    let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/usr/bin/tailscale",
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["status", "--json", "--self"]
        let stdout = Pipe()
        p.standardOutput = stdout
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            continue
        }
        // drain before waiting (see launchctl() for why)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { continue }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let myself = (obj as? [String: Any])?["Self"] as? [String: Any],
              let dns = myself["DNSName"] as? String, !dns.isEmpty else { continue }
        return dns.hasSuffix(".") ? String(dns.dropLast()) : dns
    }
    return nil
}

// MARK: - Planted troubleshooting log
// Simple appended-file logging → ~/.config/novnc-bar/app.log (self-trimmed).

enum Log {
    static let path = NSHomeDirectory() + "/.config/novnc-bar/app.log"

    static func app(_ msg: String) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int,
           size > 128_000 {
            try? fm.removeItem(atPath: path)
        }
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        let line = "\(df.string(from: Date()))  \(msg)\n"
        let data = Data(line.utf8)
        if fm.fileExists(atPath: path),
           let fh = FileHandle(forWritingAtPath: path) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(data)
        } else {
            fm.createFile(atPath: path, contents: data)
        }
    }
}

// MARK: - State

enum ServiceState: String {
    case running  = "Running"
    case failed   = "Failing (check log)"
    case stopped  = "Stopped"
    case missing  = "LaunchAgent missing"

    var dotColor: NSColor {
        switch self {
        case .running: return .systemGreen
        case .failed:  return .systemRed
        case .stopped: return .systemGray
        case .missing: return .systemOrange
        }
    }
}

// MARK: - launchctl helpers

@discardableResult
func launchctl(_ args: [String], capture: Bool = false) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    var outPipe: Pipe?
    if capture {
        outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()      // own pipe, discarded
    }
    do {
        try p.run()
    } catch {
        return (-1, "")
    }
    // IMPORTANT: drain the pipe *before* waiting for exit — waitUntilExit()
    // first would deadlock the child once it fills the pipe buffer (the
    // empty invisible menu bar item bug this app once had).
    let out = outPipe.map { String(data: $0.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? "" } ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, out)
}

// MARK: - Controller

final class Controller: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var statusItemTitle: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var restartItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    private var state: ServiceState = .stopped
    private var lastLoggedState: ServiceState?

    func start() {
        menu.autoenablesItems = false
        menu.delegate = self
        buildMenu()
        statusItem.menu = menu
        Log.app("status item created; button \(statusItem.button == nil ? "NIL" : "ok")")
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            Log.app("t+3s frame=\(String(describing: self.statusItem.button?.frame)) length=\(self.statusItem.length) isVisible=\(self.statusItem.isVisible)")
        }
    }

    // MARK: polling / applying state

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let st = self?.pollState() ?? .stopped
            DispatchQueue.main.async { self?.apply(st) }
        }
    }

    private func pollState() -> ServiceState {
        guard FileManager.default.fileExists(atPath: Config.plistPath) else {
            return .missing
        }
        let (rc, out) = launchctl(["print",
                                  "\(Config.launchdDomain)/\(Config.agentLabel)"],
                                  capture: true)
        guard rc == 0 else { return .stopped }   // not loaded in the domain
        if out.contains("state = running") { return .running }
        return .failed
    }

    private func apply(_ st: ServiceState) {
        state = st

        let installed = st != .missing
        let running = st == .running

        // Text + colored dot instead of an SF Symbol image: system symbols
        // can silently render nothing (or hide), a title is always drawn.
        // Plainest possible rendering: an ordinary text title plus a tiny
        // hand-drawn dot image. No SF Symbols and no attributed strings —
        // both proved unreliable on macOS 26/27 (Tahoe-and-newer).
        statusItem.button?.title = "noVNC"
        statusItem.button?.image = Self.dotImage(st.dotColor)
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.toolTip = "noVNC — " + st.rawValue
        statusItem.isVisible = true

        if st != lastLoggedState {
            lastLoggedState = st
            Log.app("state → \(st.rawValue)  frame: \(String(describing: statusItem.button?.frame))  isVisible: \(statusItem.isVisible)")
        }

        let sub = switch st {
        case .running: "websockify open on \(Config.listenHost):\(Config.listenPort)"
        case .failed:  "launchd keeps restarting it — check the log"
        case .stopped: "toggle it back on here"
        case .missing: "expected at ~/Library/LaunchAgents/\(Config.agentLabel).plist"
        }
        statusItemTitle.title = "noVNC: \(st.rawValue)"
        statusItemTitle.attributedTitle = NSAttributedString(
            string: statusItemTitle.title + "\n" + sub,
            attributes: [.font: NSFont.menuFont(ofSize: 0)])
        statusItemTitle.isEnabled = installed

        toggleItem.title = running ? "Stop noVNC Server" : "Start noVNC Server"
        toggleItem.keyEquivalent = "t"
        toggleItem.isEnabled = installed

        restartItem.title = "Restart noVNC Server"
        restartItem.isEnabled = running
    }

    // MARK: menu construction

    private func buildMenu() {
        statusItemTitle = NSMenuItem(title: "noVNC", action: nil, keyEquivalent: "")
        toggleItem = NSMenuItem(title: "Toggle", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        restartItem = NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "r")
        restartItem.target = self

        let openItem = NSMenuItem(title: "Open in Browser",
                                  action: #selector(openInBrowser), keyEquivalent: "u")
        openItem.target = self
        let copyItem = NSMenuItem(title: "Copy URL",
                                  action: #selector(copyURL), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command, .shift]
        copyItem.target = self
        let logItem = NSMenuItem(title: "View Log File",
                                 action: #selector(openLog), keyEquivalent: "l")
        logItem.target = self
        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")

        menu.addItem(statusItemTitle)
        menu.addItem(toggleItem)
        menu.addItem(restartItem)
        menu.addItem(.separator())
        menu.addItem(openItem)
        menu.addItem(copyItem)
        loginItem = NSMenuItem(title: "Start noVNC Bar at Login",
                               action: #selector(toggleStartAtLogin),
                               keyEquivalent: "")
        loginItem.target = self

        menu.addItem(logItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
    }

    // MARK: actions

    @objc private func toggle() {
        switch state {
        case .running, .failed:
            launchctl(["bootout", "\(Config.launchdDomain)/\(Config.agentLabel)"])
        case .stopped:
            launchctl(["bootstrap", Config.launchdDomain, Config.plistPath])
        case .missing:
            break
        }
        refresh()
    }

    @objc private func restart() {
        launchctl(["kickstart", "-k",
                   "\(Config.launchdDomain)/\(Config.agentLabel)"])
        refresh()
    }

    @objc private func openInBrowser() {
        if let url = URL(string: Config.serveURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func copyURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Config.serveURL, forType: .string)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.logPath))
    }

    private static func dotImage(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            let d = min(rect.width, rect.height) * 0.75
            NSBezierPath(ovalIn: NSRect(x: (rect.width - d) / 2,
                                        y: (rect.height - d) / 2,
                                        width: d, height: d)).fill()
            return true
        }
        img.isTemplate = false   // keep our own color, don't mono-strip
        return img
    }

    // MARK: start at login (SMAppService, macOS 13+)

    private func updateLoginItem() {
        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.title = "Start noVNC Bar at Login"
            loginItem.state = .on
        case .requiresApproval:
            loginItem.title = "Approve “noVNC Bar” in Login Items…"
            loginItem.state = .off
        default:
            loginItem.title = "Start noVNC Bar at Login"
            loginItem.state = .off
        }
    }

    // Cheap: refresh the checkmark every time the menu is opened.
    func menuWillOpen(_ menu: NSMenu) {
        updateLoginItem()
    }

    @objc private func toggleStartAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t change “Start at Login”"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
        updateLoginItem()
    }
}

// MARK: - App bootstrap

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: Controller?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app("launch — serveURL=\(Config.serveURL)  .env keys: \(Config.envFile.keys.sorted())")
        let c = Controller()
        c.start()
        controller = c   // keep alive
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
