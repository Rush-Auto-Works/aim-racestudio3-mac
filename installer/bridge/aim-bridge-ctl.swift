// aim-bridge-ctl — register / query / remove the aim-bridge root daemon via SMAppService.
//
// The AppleScript launcher shells out to this before starting RS3 (on macOS 15+ only, where the
// Local Network gate needs the bridge). SMAppService resolves the daemon plist from THIS tool's
// main bundle (RaceStudio 3.app/Contents/Library/LaunchDaemons/<PLIST>), so the tool must live
// inside the app bundle (Contents/MacOS/aim-bridge-ctl).
//
//   aim-bridge-ctl status       -> prints state; exit 0=enabled 3=requiresApproval 1=other
//   aim-bridge-ctl register     -> registers (first time -> requiresApproval: Login Items toggle)
//   aim-bridge-ctl unregister   -> removes the daemon (Uninstall app calls this)
//
// SMAppService is macOS 13+. The bridge is only needed on macOS 15+ (the gate), where it's always
// available; on older macOS the launcher never calls this.

import Foundation
import ServiceManagement

let PLIST = "com.rushautoworks.racestudio3.bridge.plist"

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

guard #available(macOS 13.0, *) else {
    err("aim-bridge-ctl: requires macOS 13+ (SMAppService); WiFi bridge not needed on older macOS")
    exit(1)
}

func statusString(_ s: SMAppService.Status) -> String {
    switch s {
    case .notRegistered:    return "notRegistered"
    case .enabled:          return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound:         return "notFound"
    @unknown default:       return "unknown"
    }
}

let svc = SMAppService.daemon(plistName: PLIST)
let cmd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "status"

switch cmd {
case "register", "ensure":
    do { try svc.register() }
    catch { err("register: \(error.localizedDescription)") }   // already-registered / pending approval show via status
case "unregister", "remove":
    do { try svc.unregister() }
    catch { err("unregister: \(error.localizedDescription)") }
case "status":
    break
default:
    err("usage: aim-bridge-ctl [status|register|unregister]")
    exit(2)
}

print(statusString(svc.status))
switch svc.status {
case .enabled:          exit(0)   // running
case .requiresApproval: exit(3)   // user must enable in System Settings > Login Items
default:                exit(1)
}
