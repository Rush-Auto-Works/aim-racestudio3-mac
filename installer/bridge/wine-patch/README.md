# Wine `ws2_32` Local-Network redirect patch (Phase 2)

Redirects RaceStudio 3's WiFi sockets so RS3-under-Wine only ever talks to `127.0.0.1`
(outside the macOS Local Network gate — proven by Phase 1.5), and the root `aim-bridge`
daemon relays loopback ↔ the real dash. This is the **only** viable in-Wine redirect:
DYLD interpose (Rosetta) and a ws2_32 proxy/hook DLL (no Wine `AppInit_DLLs`) are both
ruled out — see project CLAUDE.md "Don't retry" and the spike reproducers under `../test/`.

## Why the PE `ws2_32.dll` (not a `.so` swap)

In Wine 11.9 the host `connect()`/`sendto()` syscalls live in `ntdll.so` (sockets go through
the afd device), not in `ws2_32.so`. But the **authoritative, clean** rewrite point is the
public `ws2_32.dll` PE entry points, where the destination is still a plain `struct sockaddr`
before it's marshaled to afd. So we patch and rebuild only `ws2_32.dll` (PE) and swap it into
the prebuilt bundle.

## The patch (≈20 lines in `dlls/ws2_32/socket.c`)

A helper, applied at the top of each address-taking entry point:

```c
/* AiM WiFi loopback redirect: AP-mode dash is 10.0.0.0/28; the macOS Local Network gate
 * drops it for the Wine guest, so send it to 127.0.0.1 where the root aim-bridge relays.
 * Dest port 36002 (aim-ka discovery) additionally remaps to 36003: RS3 itself binds
 * 0.0.0.0:36002 (it sends discovery FROM 36002), so the relay must listen on 36003 —
 * if it held 127.0.0.1:36002, RS3's bind fails WSAEADDRINUSE and discovery never starts
 * (found on-device 2026-06-11: zero loopback packets from RS3). */
static const struct sockaddr *aim_loopback_redirect(const struct sockaddr *addr, int len,
                                                    struct sockaddr_in *tmp)
{
    if (addr && len >= (int)sizeof(struct sockaddr_in) && addr->sa_family == AF_INET)
    {
        const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
        if ((ntohl(in->sin_addr.s_addr) & 0xfffffff0) == 0x0a000000) /* 10.0.0.0/28 */
        {
            *tmp = *in;
            tmp->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            if (tmp->sin_port == htons(36002)) tmp->sin_port = htons(36003);
            return (const struct sockaddr *)tmp;
        }
    }
    return addr;
}
```

Call sites (each: `struct sockaddr_in _aim_tmp; addr = aim_loopback_redirect(addr, len, &_aim_tmp);`):
- `connect()`        (~L1370, param `addr`)
- `WSAConnect()`     (~L1412, param `name`)
- `sendto()`         (~L3285, param `to`)
- `WSASendTo()`      (~L3269, the destination param)
- `WSASendMsg()`     (~L1205, `msg->name`)

Scope guard: only `10.0.0.0/24` and `0.0.0.0:36002` are rewritten, so RS3's other traffic
(license/update to public IPs) is untouched.

## On-device reality (2026-06-11) — why the scope is 0.0.0.0:36002 and /24

Logging every send destination under Wine showed RS3 addresses aim-ka discovery to
**`0.0.0.0:36002`** (its per-interface broadcast resolves to 0.0.0.0 under Wine), NOT
`10.0.0.255` or the gateway. So the redirect covers both `0.0.0.0:36002` and the dash subnet
`10.0.0.0/24` (the `.1` keepalive RS3 unicasts *after* discovery). The relay replies from
`127.0.0.1:36003`; RS3 ignores replies whose source isn't the dash, so the patch ALSO rewrites
the inbound recv source (`127.0.0.1:36003` → `10.0.0.1:36002`) in `WS2_recv_base`. With these,
RS3 connected to a real MXS dash and the device appeared. This `ws2_32` patch is necessary but
not sufficient on its own — RS3 won't start discovery until `wlanapi` reports a Wi-Fi interface
(see `wlanapi-synth-iface.patch`).

## Build (both DLLs)

```bash
brew install mingw-w64 bison flex
bash build-wine-dlls.sh            # version from pins.env (or pass an explicit wine version)
# -> build/wine-dlls/{x86_64,i386}-windows/{ws2_32,wlanapi}.dll
# build-apps.sh step 1e swaps both into the bundle: lib/wine/{x86_64,i386}-windows/
```

`build-wine-dlls.sh` fetches the pinned Wine source, applies BOTH patches, configures once, and
builds `ws2_32.dll` + `wlanapi.dll` for both arches (verifying each carries its `AiM` marker).

## CI integration — built from source in the runner

`release-dmg.yml` builds both patched DLLs from Wine source on the macOS runner
(`brew install mingw-w64 bison flex` → `build-wine-dlls.sh "$WINE_VER"`) and `build-apps.sh`
step 1e swaps them into the bundle before signing. **No patched binary is committed** — they
always track `WINE_PINNED_VER` (resolved once in the workflow and used for the bundle fetch,
the cache key, and this build, so they can't drift to different Wine versions).

ABI note: vanilla-built PE DLLs swapped into the Gcenx **staging** bundle of the same version are
compatible (the PE ABI is stable within a Wine version) — verified for 11.9. Note Wine loads PE
builtins from the bundle `lib/wine/`, NOT the prefix's `system32` (the prefix copy is only seeded
at prefix-creation), so the launcher refreshes the prefix copies of both DLLs on upgrade.
