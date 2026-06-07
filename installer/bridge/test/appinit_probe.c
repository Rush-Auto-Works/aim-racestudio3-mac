/* appinit_probe.c — Phase 2 ws2_32-proxy spike, step 1. RESULT: proxy path RULED OUT (2026-06-07).
 *
 * The proxy-DLL approach needs a hook DLL loaded into an UNMODIFIED RS3. The Windows
 * mechanism is AppInit_DLLs. This minimal DLL drops a marker on PROCESS_ATTACH to prove
 * injection.
 *
 * CONCLUSION: Wine does NOT implement AppInit_DLLs — its user32.dll contains no AppInit
 * code at all (verified: `strings .../user32.dll | grep -i appinit` is empty), and the
 * marker never appears (tested with a user32-loading target and RequireSignedAppInitDLLs=0).
 * With no clean auto-injection — and a same-named forwarder ws2_32.dll unable to reach the
 * builtin to forward its unmodified exports (name collision) — the only remaining proxy
 * routes are fragile per-RS3-version binary patches. Phase 2 uses the Wine SOURCE PATCH.
 * Kept as a reproducer; do not retry the ws2_32-proxy path.
 *
 * Build: zig cc -target x86_64-windows-gnu -shared -o appinit_probe.dll appinit_probe.c
 */
#include <windows.h>
#include <stdio.h>

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)inst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        const char *m = getenv("APPINIT_MARKER");
        if (!m) m = "C:\\appinit_marker.txt";
        FILE *f = fopen(m, "w");
        if (f) { fputs("appinit dll loaded\n", f); fclose(f); }
    }
    return TRUE;
}
