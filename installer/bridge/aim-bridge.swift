// aim-bridge — AiM loopback relay (Phase 1 of the macOS 15+/26 Local Network fix).
//
// RaceStudio 3 runs under Wine and talks to an AiM dash over WiFi. On macOS 15+/26 the
// Local Network privacy gate silently drops that traffic for a Wine guest (self-daemonized,
// non-LaunchServices, never grantable). The fix is to keep RS3 entirely on loopback — which
// is OUTSIDE the gate by construction (lo0 is not broadcast-capable) — and run THIS relay to
// carry the bytes to the real dash. In production the relay runs as root (an SMAppService
// daemon); root code is exempt from the gate, so it reaches the dash with no prompt.
//
// The relay is protocol-AGNOSTIC: it forwards bytes, it does not parse STCP/STNC. It only ever
// bridges two fixed ports to one pinned dash address, and refuses everything else.
//
//   RS3 (Wine) --127.0.0.1:2000  (TCP, control + data) -->  relay --> DASH:2000
//   RS3 (Wine) --127.0.0.1:36003 (UDP, aim-ka discover) -->  relay --> DASH:36002
//
// The pcap (promiscuous-slurp/sam cap.pcapng) shows RS3 UNICASTS to the dash's fixed gateway
// IP — there is no broadcast/multicast in the connect flow — so a plain unicast relay suffices.
//
// Why the relay listens on 36003, not 36002 (on-device finding, 2026-06-11): RS3 itself binds
// 0.0.0.0:36002 for discovery (it sends FROM 36002). If the relay held 127.0.0.1:36002, RS3's
// wildcard bind fails with WSAEADDRINUSE and discovery never starts — zero packets. The
// patched ws2_32 therefore remaps dest port 36002->36003 along with the 10.0.0.x->127.0.0.1
// rewrite, and the relay forwards 36003 -> DASH:36002. The upstream socket is UNCONNECTED and
// uses an EPHEMERAL source port: the dash answers ephemeral sources but IGNORES keepalives
// sourced from 36002 by a second host (P2a/P2b on-device test), and per-sendto routing means
// joining the dash Wi-Fi after the daemon started needs no restart.
//
// Config (env, all optional; defaults are the real-hardware values):
//   DASH_ADDR (10.0.0.1) · BRIDGE_LISTEN_ADDR (127.0.0.1)
//   TCP_LISTEN_PORT (2000)  TCP_DASH_PORT (2000)
//   UDP_LISTEN_PORT (36003) UDP_DASH_PORT (36002)
// Overridable only so the hermetic test can point at a fake dash on loopback.

import Darwin
import Foundation

func env(_ k: String, _ d: String) -> String { ProcessInfo.processInfo.environment[k] ?? d }
func envPort(_ k: String, _ d: UInt16) -> UInt16 { UInt16(env(k, String(d))) ?? d }

// Production hardening: the daemon runs as ROOT (root is exempt from the Local Network gate).
// When root, IGNORE the environment and hard-pin the destination + ports — otherwise env
// injection (a tampered launchd plist, a hostile parent) could turn a root process into an
// arbitrary outbound proxy. Env overrides are honored ONLY when non-root, which is exactly the
// hermetic test harness (a normal user). Same split governs SO_REUSEADDR (see serve*()).
let IS_ROOT     = (getuid() == 0)
let LISTEN_ADDR = IS_ROOT ? "127.0.0.1" : env("BRIDGE_LISTEN_ADDR", "127.0.0.1")
let DASH_ADDR   = IS_ROOT ? "10.0.0.1"  : env("DASH_ADDR", "10.0.0.1")
let TCP_LISTEN  = IS_ROOT ? UInt16(2000)  : envPort("TCP_LISTEN_PORT", 2000)
let TCP_DASH    = IS_ROOT ? UInt16(2000)  : envPort("TCP_DASH_PORT", 2000)
let UDP_LISTEN  = IS_ROOT ? UInt16(36003) : envPort("UDP_LISTEN_PORT", 36003)
let UDP_DASH    = IS_ROOT ? UInt16(36002) : envPort("UDP_DASH_PORT", 36002)

func logmsg(_ s: String) {
    FileHandle.standardError.write(Data(("[aim-bridge] " + s + "\n").utf8))
}

func makeAddr(_ ip: String, _ port: UInt16) -> sockaddr_in {
    var a = sockaddr_in()
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    _ = inet_pton(AF_INET, ip, &a.sin_addr)
    return a
}

// bind()/connect()/sendto() want a sockaddr*; this rebinds a sockaddr_in for the call.
func withSockaddr<R>(_ a: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

// ---- TCP: accept on loopback, dial the dash, pump both directions until EOF ----

func pump(_ from: Int32, _ to: Int32) {
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(from, &buf, buf.count)
        if n < 0 { if errno == EINTR { continue }; break }  // retry on signal, else error
        if n == 0 { break }                                 // EOF
        var off = 0
        while off < n {
            let w = buf.withUnsafeBytes { write(to, $0.baseAddress!.advanced(by: off), n - off) }
            if w < 0 { if errno == EINTR { continue }; break }
            if w == 0 { break }
            off += w
        }
    }
    shutdown(to, SHUT_WR)
}

func serveTCP() {
    let ls = socket(AF_INET, SOCK_STREAM, 0)
    // SO_REUSEADDR only for the (non-root) test harness, which rebinds fixed ports across
    // scenarios. The root daemon does NOT set it: on loopback it would let any local process
    // pre-bind and steal 127.0.0.1:<port>. Without it, a conflicting bind fails -> we exit.
    if !IS_ROOT { var yes: Int32 = 1; setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) }
    var la = makeAddr(LISTEN_ADDR, TCP_LISTEN)
    guard withSockaddr(&la, { bind(ls, $0, $1) }) == 0 else {
        logmsg("TCP bind \(LISTEN_ADDR):\(TCP_LISTEN) failed: \(String(cString: strerror(errno)))"); exit(1)
    }
    listen(ls, 8)
    logmsg("TCP \(LISTEN_ADDR):\(TCP_LISTEN) -> \(DASH_ADDR):\(TCP_DASH)")
    while true {
        let cs = accept(ls, nil, nil)
        if cs < 0 { continue }
        let an = counts.bump("tcp-accept")
        if milestone(an) { logmsg("tcp: RS3 opened the control channel (#\(an)) — it found a device, dialing dash") }
        DispatchQueue.global().async {
            let ds = socket(AF_INET, SOCK_STREAM, 0)
            var da = makeAddr(DASH_ADDR, TCP_DASH)
            guard withSockaddr(&da, { connect(ds, $0, $1) }) == 0 else {
                logmsg("tcp: dial \(DASH_ADDR):\(TCP_DASH) FAILED: \(String(cString: strerror(errno))) — dash unreachable (wrong Wi-Fi / dash off?)")
                close(cs); close(ds); return
            }
            let dn = counts.bump("tcp-dial")
            if milestone(dn) { logmsg("tcp: connected to dash \(DASH_ADDR):\(TCP_DASH) (#\(dn)) — TCP path OK") }
            let g = DispatchGroup()
            g.enter(); DispatchQueue.global().async { pump(cs, ds); g.leave() }
            g.enter(); DispatchQueue.global().async { pump(ds, cs); g.leave() }
            g.wait(); close(cs); close(ds)
        }
    }
}

// Milestone counters: count each event and log only at 1,10,100,… so a single collected
// aim-bridge.log answers "where did the discovery chain break?" without per-packet flooding.
// n==1 is the all-important FIRST occurrence. The events we track:
//   c2d        a datagram arrived FROM RS3 (loopback) headed to the dash   (ws2_32/wlanapi OK)
//   c2d-fail   sendto() to the dash failed locally — no route              (Mac not on dash Wi-Fi)
//   d2c        a reply arrived FROM the pinned dash                        (full UDP path OK)
//   d2c-drop   a reply arrived from some OTHER address (dropped)           (dash at a different IP)
//   tcp-accept RS3 opened the TCP control/data channel                    (it found a device)
//   tcp-dial   the relay connected to the dash over TCP                   (TCP path OK)
final class Counters: @unchecked Sendable {
    private let lock = NSLock()
    private var m = [String: Int]()
    func bump(_ k: String) -> Int { lock.lock(); defer { lock.unlock() }; let n = (m[k] ?? 0) + 1; m[k] = n; return n }
}
let counts = Counters()
func milestone(_ n: Int) -> Bool { n == 1 || n == 10 || n == 100 || n == 1000 || n == 10000 || n % 100000 == 0 }

// IPv4 dotted-quad from an in_addr (network byte order), endian-safe via byte extraction.
func ipv4(_ a: in_addr) -> String {
    let v = a.s_addr
    return "\(v & 0xff).\((v >> 8) & 0xff).\((v >> 16) & 0xff).\((v >> 24) & 0xff)"
}
func port16(_ p: in_port_t) -> UInt16 { UInt16(bigEndian: p) }

// Dump the Mac's IPv4 interfaces and whether any sits on the dash's /24. This is the single most
// useful line for the "no devices" report: it says whether the Mac is even joined to the dash's
// Wi-Fi (DASH_ADDR is only reachable when the Mac is on the dash AP, getting a 10.0.0.x lease).
func logNetContext() {
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0 else { logmsg("net: getifaddrs failed: \(String(cString: strerror(errno)))"); return }
    defer { freeifaddrs(ifap) }
    let dash = makeAddr(DASH_ADDR, 0).sin_addr.s_addr
    let want = (dash & 0xff, (dash >> 8) & 0xff, (dash >> 16) & 0xff)   // first 3 octets = /24 network
    var onDashSubnet = false
    var p = ifap
    while let cur = p {
        let next = cur.pointee.ifa_next
        defer { p = next }
        guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        let name = String(cString: cur.pointee.ifa_name)
        if name == "lo0" { continue }
        var a = sockaddr_in()
        memcpy(&a, sa, Int(MemoryLayout<sockaddr_in>.size))
        let s = a.sin_addr.s_addr
        let same = (s & 0xff, (s >> 8) & 0xff, (s >> 16) & 0xff) == want
        if same { onDashSubnet = true }
        logmsg("net: \(name) \(ipv4(a.sin_addr))\(same ? "  <- dash subnet" : "")")
    }
    logmsg(onDashSubnet
        ? "net: an interface is on the dash subnet \(DASH_ADDR)/24 — Wi-Fi link looks OK"
        : "net: NO interface on the dash subnet \(DASH_ADDR)/24 — the Mac is probably NOT joined to the dash Wi-Fi (USB/SD import still works)")
}

// Last loopback client we heard from. A lock-guarded reference type so both UDP pump
// threads share one instance (no "mutated after capture" data race).
final class ClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var addr = sockaddr_in()
    private var present = false
    func set(_ a: sockaddr_in) { lock.lock(); addr = a; present = true; lock.unlock() }
    func get() -> sockaddr_in? { lock.lock(); defer { lock.unlock() }; return present ? addr : nil }
}

// ---- UDP: forward loopback client -> dash, return dash replies to the last client ----
// Single logical client (RS3) at a time, which matches how RS3 drives discovery.

func serveUDP() {
    let ls = socket(AF_INET, SOCK_DGRAM, 0)
    // SO_REUSEADDR only for the (non-root) test harness, which rebinds fixed ports across
    // scenarios. The root daemon does NOT set it: on loopback it would let any local process
    // pre-bind and steal 127.0.0.1:<port>. Without it, a conflicting bind fails -> we exit.
    if !IS_ROOT { var yes: Int32 = 1; setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) }
    var la = makeAddr(LISTEN_ADDR, UDP_LISTEN)
    guard withSockaddr(&la, { bind(ls, $0, $1) }) == 0 else {
        logmsg("UDP bind \(LISTEN_ADDR):\(UDP_LISTEN) failed: \(String(cString: strerror(errno)))"); exit(1)
    }
    // UNCONNECTED upstream socket toward the dash: sendto() per datagram so the kernel
    // re-resolves the route (and source address) every time — the daemon starts at login on
    // whatever network the Mac is on, and must keep working after the user joins the dash's
    // Wi-Fi WITHOUT a restart. A connect()ed socket would pin the stale route/source forever.
    // Replies are filtered to the pinned dash address (the unconnected socket accepts any
    // sender; we do the check connect() would have done).
    let us = socket(AF_INET, SOCK_DGRAM, 0)
    let dashPinned = makeAddr(DASH_ADDR, UDP_DASH)
    logmsg("UDP \(LISTEN_ADDR):\(UDP_LISTEN) -> \(DASH_ADDR):\(UDP_DASH)")

    let client = ClientBox()

    // dash -> last client. n >= 0 is a real datagram (0 = valid zero-length); only n < 0 is error.
    DispatchQueue.global().async {
        var rbuf = [UInt8](repeating: 0, count: 65536)
        while true {
            var sa = sockaddr_in()
            var saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(us, &rbuf, rbuf.count, 0, $0, &saLen)
                }
            }
            if n < 0 { if errno == EINTR { continue }; continue }
            // accept only the pinned dash (addr + port) — drop anything else
            guard sa.sin_addr.s_addr == dashPinned.sin_addr.s_addr,
                  sa.sin_port == dashPinned.sin_port else {
                let fn = counts.bump("d2c-drop")
                if milestone(fn) { logmsg("udp: ignored reply from \(ipv4(sa.sin_addr)):\(port16(sa.sin_port)) (#\(fn)) — expected dash \(DASH_ADDR):\(UDP_DASH); dash may be at a different IP") }
                continue
            }
            let rn = counts.bump("d2c")
            if milestone(rn) { logmsg("udp: reply from dash \(DASH_ADDR):\(UDP_DASH) (#\(rn), \(n)B) — discovery reply path OK") }
            guard var ca = client.get() else {
                let nn = counts.bump("d2c-noclient")
                if milestone(nn) { logmsg("udp: dash reply with no loopback client yet (#\(nn)) — dropping") }
                continue
            }
            let w = withSockaddr(&ca) { sap, slen in
                rbuf.withUnsafeBytes { sendto(ls, $0.baseAddress, n, 0, sap, slen) }
            }
            if w < 0 {
                let en = counts.bump("d2c-deliver-fail")
                if milestone(en) { logmsg("udp: failed delivering dash reply to RS3 (#\(en)): \(String(cString: strerror(errno)))") }
            }
        }
    }
    // client -> dash (per-datagram sendto: route + source resolved fresh each time)
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        var ca = sockaddr_in()
        var caLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &ca) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(ls, &buf, buf.count, 0, $0, &caLen)
            }
        }
        if n < 0 { if errno == EINTR { continue }; continue }
        client.set(ca)
        let cn = counts.bump("c2d")
        if milestone(cn) { logmsg("udp: datagram from RS3 \(ipv4(ca.sin_addr)):\(port16(ca.sin_port)) -> dash \(DASH_ADDR):\(UDP_DASH) (#\(cn), \(n)B)") }
        var da = dashPinned
        let w = withSockaddr(&da) { sap, slen in
            buf.withUnsafeBytes { sendto(us, $0.baseAddress, n, 0, sap, slen) }
        }
        if w < 0 {
            let fn = counts.bump("c2d-fail")
            if milestone(fn) { logmsg("udp: sendto dash \(DASH_ADDR):\(UDP_DASH) FAILED (#\(fn)): \(String(cString: strerror(errno))) — no route; is the Mac on the dash Wi-Fi (10.0.0.x)?") }
        }
    }
}

logmsg("starting (pid \(getpid()), uid \(getuid()))")
logNetContext()
DispatchQueue.global().async { serveTCP() }
serveUDP()
