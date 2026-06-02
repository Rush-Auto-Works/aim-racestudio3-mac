// RS3Helper — a tiny menu-bar (status bar) agent that runs alongside RaceStudio 3, so the
// Import / Uninstall / Open controls are always reachable even though Wine owns the main menu bar.
// It lives inside RaceStudio 3.app/Contents/Helpers/ and self-locates the parent app.
//
// Build: swiftc -O -framework Cocoa -o RS3Helper RS3Helper.swift
import Cocoa

// ---- locate the parent RaceStudio 3.app (…/RaceStudio 3.app/Contents/Helpers/<this>.app) ----
let helperBundle = Bundle.main.bundlePath as NSString
let APP_PATH = ((helperBundle.deletingLastPathComponent as NSString)   // …/Contents/Helpers
    .deletingLastPathComponent as NSString)                            // …/Contents
    .deletingLastPathComponent                                         // …/RaceStudio 3.app
let RES = APP_PATH + "/Contents/Resources"
let WINE = RES + "/wine/bin/wine"
let CORE = RES + "/installer-core.sh"
let HOME = NSHomeDirectory()
let ROOT = HOME + "/Library/Application Support/RaceStudio3"
let WINEXE = #"C:\AIM_SPORT\RaceStudio3\64\AiMRS3-64-ReleaseU.exe"#

// single-quote-escape a path for embedding in a bash command
func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// debug log (remove once the status item is confirmed)
func hlog(_ s: String) {
    let line = "[\(ProcessInfo.processInfo.processIdentifier)] " + s + "\n"
    let path = "/tmp/rs3helper.log"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}

@discardableResult
func bash(_ script: String, wait: Bool = false) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", script]
    do { try p.run() } catch { return 127 }
    if wait { p.waitUntilExit(); return p.terminationStatus }
    return 0
}

func rs3Running() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", "AiMRS3-64"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func launchRS3() {
    let env = "export WINEPREFIX=\(q(ROOT + "/prefix")) WINEARCH=win64 WINEDEBUG=-all; "
        + "export WINEDLLOVERRIDES='mscoree=d;mshtml=d'; "
        + "export XDG_CACHE_HOME=\(q(ROOT + "/cache")) XDG_CONFIG_HOME=\(q(ROOT + "/xdg-config")) XDG_DATA_HOME=\(q(ROOT + "/xdg-data")); "
        + "mkdir -p \(q(ROOT + "/logs")); "
    bash(env + "nohup arch -x86_64 \(q(WINE)) '\(WINEXE)' >> \(q(ROOT + "/logs/run.log")) 2>&1 &")
}

class Delegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var sawRS3 = false

    func applicationDidFinishLaunching(_ note: Notification) {
        hlog("didFinishLaunching; bundleId=\(Bundle.main.bundleIdentifier ?? "nil") APP_PATH=\(APP_PATH)")
        // single-instance: if another helper is already up, bow out
        let me = Bundle.main.bundleIdentifier ?? "com.rushautoworks.racestudio3.helper"
        let count = NSRunningApplication.runningApplications(withBundleIdentifier: me).count
        hlog("instances=\(count)")
        if count > 1 {
            hlog("another instance running -> terminating"); NSApp.terminate(nil); return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = []                       // not removable, don't auto-hide
        if let b = statusItem.button {
            // Plain bold text — image-less, so SF-Symbol availability and template-tinting can't hide it.
            b.title = "🏁 RS3"
            b.toolTip = "RaceStudio 3 — click for Import / Quit / Uninstall"
            b.font = NSFont.menuBarFont(ofSize: 0)
        }
        statusItem.isVisible = true
        hlog("statusItem created; button=\(statusItem.button != nil) title=\(statusItem.button?.title ?? "nil") len=\(statusItem.length) screens=\(NSScreen.screens.count) mainScreen=\(NSScreen.main?.localizedName ?? "nil") active=\(NSApp.isActive)")
        // Visible confirmation that the helper actually launched, in case the status item ends up hidden
        // (e.g. by Bartender, an overlay app, or a Tahoe redraw quirk).
        let n = NSUserNotification()
        n.title = "RaceStudio 3 Helper running"
        n.informativeText = "Look for “🏁 RS3” in your menu bar. Click it for Import, Quit, Uninstall."
        NSUserNotificationCenter.default.deliver(n)
        let menu = NSMenu()
        let items = [
            ("Open RaceStudio 3", #selector(openRS3)),
            ("Quit RaceStudio 3", #selector(quitRS3)),
            ("Import Data…", #selector(importData)),
            ("Uninstall…", #selector(uninstall)),
        ]
        for (title, sel) in items {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self; menu.addItem(it)
        }
        menu.addItem(.separator())
        let qz = NSMenuItem(title: "Quit Helper", action: #selector(quitHelper), keyEquivalent: "q")
        qz.target = self; menu.addItem(qz)
        statusItem.menu = menu

        // quit the helper once RaceStudio 3 has run and then exited
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            if rs3Running() { self.sawRS3 = true }
            else if self.sawRS3 { NSApp.terminate(nil) }
        }
    }

    @objc func openRS3() { launchRS3() }

    // Reliable quit — Wine's flaky "Wine" menu / Cmd-Q often won't close RS3, so kill wineserver
    // for our prefix (closes all RS3 windows cleanly).
    @objc func quitRS3() {
        let ws = RES + "/wine/bin/wineserver"
        bash("WINEPREFIX=\(q(ROOT + "/prefix")) \(q(ws)) -k 2>/dev/null; pkill -f AiMRS3-64 2>/dev/null; true")
    }

    @objc func importData() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose an AIM_SPORT folder, a RaceStudio3 “user” folder, or a folder of .xrk files to import. Nothing you already have is overwritten."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = url.path
        DispatchQueue.global().async {
            let rc = bash("RS3_SINGLE_APP=1 UI_MODE=cli /bin/bash \(q(CORE)) --import \(q(folder)) >/dev/null 2>&1", wait: true)
            DispatchQueue.main.async {
                let a = NSAlert()
                if rc == 0 {
                    a.messageText = "Import complete"
                    a.informativeText = "Merged into your RaceStudio 3 data folder. Nothing existing was overwritten."
                } else {
                    a.alertStyle = .warning
                    a.messageText = "Import didn’t finish"
                    a.informativeText = "Couldn’t import that folder. Make sure it contains a RaceStudio3 “user” folder, AIM_SPORT, or .xrk files."
                }
                a.runModal()
            }
        }
    }

    @objc func uninstall() {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "Uninstall RaceStudio 3"
        a.informativeText = "Drag “RaceStudio 3” from your Applications folder to the Trash.\n\nYour telemetry in ~/Documents/AIM_SPORT is kept. To also remove the Windows environment, delete:\n~/Library/Application Support/RaceStudio3"
        a.addButton(withTitle: "Reveal App in Finder")
        a.addButton(withTitle: "OK")
        if a.runModal() == .alertFirstButtonReturn {
            bash("open -R \(q(APP_PATH))")
        }
    }

    @objc func quitHelper() { NSApp.terminate(nil) }
}

hlog("main start; argv=\(CommandLine.arguments)")
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar agent, no Dock icon
hlog("calling app.run()")
app.run()
