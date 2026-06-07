/* interpose_rewrite.c — Phase 2 DYLD-interpose spike. RESULT: RULED OUT (2026-06-07).
 *
 * Tested whether a DYLD_INSERT_LIBRARIES shim can rewrite a Wine guest's socket
 * destinations (10.0.0.0/28 -> 127.0.0.1) at the libc connect()/sendto() layer,
 * under a Rosetta-translated Wine unix-loader.
 *
 * CONCLUSION: DYLD_INSERT_LIBRARIES is NOT honored for Rosetta-translated x86_64
 * processes on macOS 26.4.1. This dylib's constructor runs when inserted into a
 * native arm64 process (marker file written) but never runs under `arch -x86_64`
 * (no marker) — independent of code-signing and hardened runtime. The Wine
 * unix-loader is x86_64-under-Rosetta, so the interpose can never fire. Phase 2
 * uses the Wine source patch instead. Kept as a reproducer; do not retry DYLD.
 *
 * Build (x86_64, to load into the translated loader):
 *   clang -arch x86_64 -dynamiclib -o interpose_rewrite.dylib interpose_rewrite.c
 *
 * A constructor drops $LNP_MARKER (default /tmp/lnp_interpose_loaded) on load, so the
 * harness can distinguish "dylib didn't load" (hardened runtime blocked DYLD) from
 * "loaded but interpose never fired" (Wine uses a path libc interpose can't catch).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/* 10.0.0.0/28 — the AP-mode dash subnet. */
static int in_dash_subnet(const struct sockaddr *sa) {
    if (!sa || sa->sa_family != AF_INET) return 0;
    const struct sockaddr_in *s = (const struct sockaddr_in *)sa;
    uint32_t ip = ntohl(s->sin_addr.s_addr);
    return (ip & 0xFFFFFFF0u) == (0x0A000000u);  /* 10.0.0.0/28 */
}

static void rewrite_to_loopback(struct sockaddr_in *dst) {
    dst->sin_addr.s_addr = htonl(INADDR_LOOPBACK);  /* 127.0.0.1 */
}

extern int connect(int, const struct sockaddr *, socklen_t);
extern ssize_t sendto(int, const void *, size_t, int, const struct sockaddr *, socklen_t);

static int my_connect(int fd, const struct sockaddr *addr, socklen_t len) {
    if (in_dash_subnet(addr)) {
        struct sockaddr_in r;
        memcpy(&r, addr, sizeof r < (size_t)len ? sizeof r : (size_t)len);
        rewrite_to_loopback(&r);
        fprintf(stderr, "[interpose] connect 10.0.0.0/28 -> 127.0.0.1\n");
        return connect(fd, (struct sockaddr *)&r, sizeof r);
    }
    return connect(fd, addr, len);
}

static ssize_t my_sendto(int fd, const void *buf, size_t n, int flags,
                         const struct sockaddr *addr, socklen_t len) {
    if (in_dash_subnet(addr)) {
        struct sockaddr_in r;
        memcpy(&r, addr, sizeof r < (size_t)len ? sizeof r : (size_t)len);
        rewrite_to_loopback(&r);
        fprintf(stderr, "[interpose] sendto 10.0.0.0/28 -> 127.0.0.1\n");
        return sendto(fd, buf, n, flags, (struct sockaddr *)&r, sizeof r);
    }
    return sendto(fd, buf, n, flags, addr, len);
}

__attribute__((used)) static struct { const void *repl, *orig; }
interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)my_connect, (const void *)connect },
    { (const void *)my_sendto,  (const void *)sendto  },
};

__attribute__((constructor))
static void on_load(void) {
    const char *marker = getenv("LNP_MARKER");
    if (!marker) marker = "/tmp/lnp_interpose_loaded";
    FILE *f = fopen(marker, "w");
    if (f) { fputs("loaded\n", f); fclose(f); }
    fprintf(stderr, "[interpose] dylib loaded\n");
}
