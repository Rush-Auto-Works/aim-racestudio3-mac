# Plan: Restore AiM WiFi connectivity under Wine on macOS 15+/26 (A2 loopback bridge)

> Revised 2026-06-05 after a two-reviewer Opus debate (acpx-opus + claude-skeptic), both
> REVISE. Key changes: a loopback-exemption falsification gate moved to the front (Phase 1.5);
> the Phase 1 test upgraded to model the real keepalive/TCP-close behavior; Phase 2 default
> flipped to the Wine source patch; a daemon security spec, uninstall-unregister, update
> lifecycle, and graceful-degradation UX added as first-class deliverables; scope explicitly
> bounded to AP mode for v1 with SD/USB import as the supported fallback.

## Problem

RaceStudio 3 runs under Wine on Apple Silicon. It reaches an AiM dash over WiFi via UDP
`aim-ka` discovery (port 36002) then STCP over TCP (port 2000). On macOS 15 (Sequoia) / 26
(Tahoe) the **Local Network privacy gate** silently drops that traffic for the Wine guest. The
socket-owning process is the Wine unix-loader: self-daemonized to PPID=1, not a LaunchServices
app, so macOS can never attribute or prompt for the grant. **Confirmed on real hardware**
(notarized build, MXS dash, macOS 26): no prompt, no Privacy entry, dash never appears.

Ruled out (deep research + on-device): `NSLocalNetworkUsageDescription` on the loader
(necessary-but-insufficient), NEAppProxy/NEFilter (Developer-ID flow capture unreliable /
supervised-only), pf/NAT (gate evaluates dest class at flow creation), MDM/PPPC/tccutil, and
running all of Wine as root.

## Chosen architecture: A2 loopback bridge

Keep RS3 **entirely on loopback** — claimed to be outside the gate by construction (lo0 is not
broadcast-capable; Apple's "local network" = broadcast-capable interfaces + multicast +
255.255.255.255, all loopback-free) — and relay to the real dash via a **root** helper (root
code is exempt from the gate).

```
RS3 (Wine) ── 127.0.0.1:2000  (TCP) ──▶ aim-bridge (root) ──▶ DASH:2000
RS3 (Wine) ── 127.0.0.1:36002 (UDP) ──▶ aim-bridge (root) ──▶ DASH:36002
```

pcap fact (real RS3↔MXS): RS3 **unicasts** to the dash's fixed gateway IP (10.0.0.1); no
broadcast/multicast in the connect flow, so a plain unicast relay suffices.

## Scope (v1)

**AP mode only.** The dash creates its own WiFi network, is the gateway at `10.0.0.1`/28, and
RS3 auto-derives that address. Infrastructure mode (dash joined to the user's router, arbitrary
DHCP IP) is **explicitly out of scope for v1** — the `10.0.0.0/28` rewrite and the hardcoded
relay dest assume AP mode. The bridge must **detect non-AP topology and fail loud** (surface
"use AP mode or SD/USB import"), never silently misroute. When the bridge is unavailable for any
reason, the supported fallback is the existing **SD/USB offline import**.

## Phases

### Phase 1 — Relay (code DONE, committed 9be48cc; test must be upgraded before relied on)
- `installer/bridge/aim-bridge.swift`: protocol-agnostic TCP+UDP relay, pinned to one dash
  address + two ports.
- **Test upgrade (blocking before Phase 1 is "trusted"):** the current `fake_dash.py` echoes
  instantly and proves nothing about the real failure mode. Replace/augment with a fake dash that
  models real behavior: TCP:2000 **closes within ~1s of the last UDP keepalive**, and stays open
  only while keepalives arrive at ~500ms cadence (per `promiscuous-slurp` `KeepaliveMaintainer`).
  Assert the relay keeps a download alive end-to-end across the two extra hops.
- **Relay robustness fixes:** `pump()` must retry on `EINTR` (not treat it as EOF); handle
  zero-length UDP datagrams; revisit the single-`ClientBox` UDP design — only valid if
  RS3-under-Wine reuses one source port for 36002 (must be proven in Phase 1.5; otherwise use a
  per-source-port mapping table).

### Phase 1.5 — Falsify the loopback exemption (CRITICAL GATE — do before any Phase 2 code)
The entire architecture rests on the unverified inference that a **Wine guest's** loopback
traffic escapes the gate. This is the cheapest thing to test and currently the biggest risk.
No relay, daemon, or DYLD needed:
1. Native listener on `127.0.0.1:2000` (RS3 side; root not required).
2. Inside Wine, a minimal Winsock client (e.g. a ~20-line win32 program, or `ncat` under Wine)
   connects to `127.0.0.1:2000` and sends bytes.
3. Stream `log stream --predicate 'process == "nehelper" OR subsystem == "com.apple.mdns"'`.
   Confirm bytes arrive at the listener and `nehelper` does NOT gate the flow.
Run on **macOS 15 AND 26**; record exact build numbers in the commit for regression tracking.
Open sub-question to resolve here: does Wine route guest `127.0.0.1` through host `lo0`
(exempt) or through some path the gate still inspects by process identity? Also capture RS3's
real source-port behavior for UDP 36002 (settles the Phase 1 `ClientBox` question) and the TCP
connection count + whether the dash correlates connections by source port (from the pcap).
**If this fails, Phases 2-4 are dead — stop and ship SD/USB import.**

### Phase 2 — Point RS3 at loopback
RS3 has no connection-IP setting; it auto-derives the dash IP from the AP gateway (10.0.0.1),
so we must rewrite its socket destinations. **Prerequisite:** `lsof` the loader and `wineserver`
PIDs while RS3 is connected to confirm which process owns the TCP:2000 / UDP:36002 sockets, and
whether it issues `sendto` vs `sendmsg` for UDP — the rewrite must cover the actual call site.

- **Primary: patch the bundled Wine `ws2_32.dll` — PROVEN (2026-06-07).** A ~20-line patch to
  `dlls/ws2_32/socket.c` rewrites `10.0.0.0/28` → `127.0.0.1` in `connect()`/`WS2_sendto()`/
  `WS2_ConnectEx()` (covers connect/WSAConnect/sendto/WSASendTo/WSASendMsg). Build only the PE
  `ws2_32.dll` from wine-11.9 source and swap it into the prebuilt bundle — no full Wine rebuild,
  no entitlement weakening, survives notarization. Verified end-to-end: built with the patch,
  swapped into the Gcenx staging bundle (ABI-compatible), and a probe→`10.0.0.1` under the patched
  Wine landed on the `127.0.0.1` listener for BOTH TCP and UDP. Patch + reproducible builder:
  `installer/bridge/wine-patch/{ws2_32-localnet.patch,build-ws2_32.sh}`.
- **DYLD interpose dylib — RULED OUT (spike, 2026-06-07).** `DYLD_INSERT_LIBRARIES` is **not
  honored for Rosetta-translated x86_64 processes** on macOS 26.4.1. Proven with
  `installer/bridge/test/interpose_rewrite.c`: a constructor-marker dylib loads into a native
  **arm64** process (marker written, ctor logs) but NOT into the same binary run via
  `arch -x86_64` (no marker, ctor never runs) — and this is independent of code-signing (tested
  ad-hoc-signed) and of hardened runtime (tested ad-hoc-resigned wine). The Wine unix-loader runs
  x86_64 under Rosetta, so the interpose can never fire. This is the trap the review predicted; do
  not retry DYLD for socket redirect.
- **ws2_32 proxy DLL — RULED OUT (spike, 2026-06-07).** Needs to inject a hook into an unmodified
  RS3, but **Wine does not implement `AppInit_DLLs`** (its `user32.dll` has no AppInit code at all;
  injection marker never appears even with a user32-loading target + `RequireSignedAppInitDLLs=0`).
  And a same-named forwarder `ws2_32.dll` can't reach the builtin to forward its unmodified exports
  (name collision). The only remaining proxy routes are fragile per-RS3-version binary patches
  (IAT-rewrite of `AiMRS3-64.exe`, or binary-patch `ws2_32.dll.so`). Reproducer:
  `installer/bridge/test/appinit_probe.c`. Do not retry the proxy-DLL path.
- **CONCLUSION:** the redirect must be the **Wine source patch** (primary, above) — the only robust,
  reviewable in-Wine option. Both lighter alternatives (DYLD, ws2_32-proxy) are ruled out on
  hardware. Accept the build-from-source cost.
- Testable without hardware once built: launch RS3 through the patched Wine against the realistic
  fake dash (`test-bridge-keepalive.sh` model); confirm traffic lands on loopback and the dash flow
  survives.

### Phase 3 — Package as root daemon (with a written security spec)
Ship the relay as `SMAppService.daemon(plistName:)` inside the app bundle
(`Contents/Library/LaunchDaemons/`), Developer-ID signed + notarized. One-time **Login Items**
approval (`SMAppServiceStatusRequiresApproval`).

**Security spec (write before implementing):**
- **No env vars in production.** The dev relay reads `DASH_ADDR`/ports from env; the production
  daemon must NOT — env injection would turn it into an arbitrary root proxy. Hardcode the
  permitted dest (`10.0.0.0/28`, ports 36002/UDP + 2000/TCP) or read a signed, root-owned config
  with strict perms.
- **Bind safely.** Do not silently share the port via `SO_REUSEADDR` (a local process could steal
  `127.0.0.1:2000`). Bind loopback-only; on `EADDRINUSE`, log and exit rather than co-bind.
- **Peer trust — correct the language.** There is **no XPC peer** on a raw `accept()`ed socket, so
  "XPC peer code-signing validation" does not apply. Decide: (a) accept that loopback-bind +
  hardcoded dest is sufficient (confused-deputy risk is low — a dash holds no secrets and grants
  no escalation to the Mac), and document it; or (b) if peer validation is wanted, use
  `LOCAL_PEERCRED`/`LOCAL_PEERPID` on the accepted fd → resolve pid → check the code signature
  (note this validates our own bundled Wine loader and fights PPID=1 reparenting).
- **Dash-unreachable behavior:** define it (bounded retry, then idle; never busy-loop).
- **Idle watchdog:** daemon exits when unused.

**Uninstall MUST unregister the daemon.** A LaunchDaemon persists across app deletion. The
existing Uninstall app (currently `wineserver -k`) must also call `SMAppService.unregister()`,
or deleting `/Applications/AiM` leaves a registered root daemon bound to loopback across reboots
forever. Add this to the plan and to the Uninstall app.

**Update lifecycle:** define how the daemon binary + plist are rebuilt/re-signed each RS3 release
(the weekly `pins.env` bump path), how they ship in the DMG, how a new-DMG drag updates the
registered daemon, and how an old/renamed daemon is retired (no lingering duplicates).

### Phase 3.5 — Graceful degradation UX (first-class, not a footnote)
Silent failure is the worst outcome for the non-technical target audience. Required:
- **Launcher health-check before launching RS3:** is the daemon running and is `127.0.0.1:2000`
  accepting? If not, surface a clear, actionable dialog (deep-link
  `x-apple.systempreferences:com.apple.LoginItems-Settings`) and offer the SD/USB import path.
  Start/verify the daemon **before** launching RS3 to avoid RS3 caching a first-launch "device
  unreachable" failure that needs a restart to clear.
- **"Daemon not approved" detection** (`SMAppService.status`) with in-app guidance and a re-check
  button.
- A visible **"WiFi not working?"** path that explains AP-mode + the Login Items toggle and falls
  back to SD/USB import.

### Phase 4 — On-device integration test
macOS 26 + MXS: confirm `nehelper` stays silent (RS3 only touches loopback) and the dash appears
in RS3. Download a session AND push a config end-to-end through the bridge. Then correct the
README and ship.

## Key risks / open questions
1. **Loopback-exemption inference** — load-bearing and Wine-specific; **falsified in Phase 1.5
   before any further build** (was: deferred to Phase 4).
2. **DYLD interpose under Rosetta** — may never fire; demoted to experiment behind a spike.
3. **Root daemon surface** — narrowed by loopback-bind + hardcoded dest + no-env + uninstall
   unregister; "XPC peer validation" language corrected.
4. **Wine loopback quirks** (historical localhost UDP delivery bugs) — covered by the realistic
   Phase 1 test + Phase 1.5.
5. **SMAppService UX / silent failure** — addressed by Phase 3.5 (health-check + guidance +
   SD/USB fallback).
6. **Maintenance / version-coupling** — Wine-patch primary keeps the rewrite deterministic and
   inside our bundle; integration smoke test (RS3-through-rewrite opens a socket) required, not
   just isolated interception.
7. **Topology** — AP-mode-only for v1, detect-and-fail-loud otherwise.
8. **Update lifecycle / uninstall** — specified in Phase 3 so a deleted app leaves nothing behind.

## Alternative considered and rejected
**Architecture B (native sidecar):** a native app does device I/O and hands files to RS3 via its
data dir. Rejected for the full feature set: cannot carry live telemetry or firmware flashing,
and config/firmware upload still needs socket interception (collapses back into A). It remains
the basis of the **SD/USB import fallback** (download-only), which is the supported path whenever
the bridge is unavailable.

## Success criteria
- Phase 1.5 proves loopback escapes the gate under Wine on macOS 15 + 26 (recorded build numbers).
- RS3 under Wine on macOS 26 discovers + connects to an MXS over WiFi (AP mode) with no
  user-facing Local Network prompt and no manual config beyond the one-time Login Items approval.
- Session list + download + config upload work through the bridge across the real keepalive/TCP-
  close timing.
- Uninstalling the app unregisters the daemon (nothing left bound to loopback).
- When the bridge is unavailable, the user gets a clear message and a working SD/USB import path —
  never a silent failure.
- No regression to the existing install/uninstall engine; bridge is additive and idle when unused.
