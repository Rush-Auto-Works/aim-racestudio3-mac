/* ws2_redirect_unit.c — unit test for the ws2_32 patch's address-rewrite logic.
 *
 * aim_loopback_redirect() below is copied VERBATIM from installer/bridge/wine-patch/
 * ws2_32-localnet.patch (minus Wine's FIXME/debugstr_sockaddr trace, which is a no-op here).
 * test-ws2-redirect.sh asserts the patch still contains this exact logic, so this test and the
 * shipped code can't silently drift. Compiles natively (the types are standard BSD sockets).
 *
 * Exhaustively checks the 10.0.0.0/28 boundary and the guards (family, length, NULL).
 */
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/* ---- verbatim from the patch ---- */
static const struct sockaddr *aim_loopback_redirect( const struct sockaddr *addr, int len,
                                                     struct sockaddr_in *tmp )
{
    if (addr && len >= (int)sizeof(*tmp) && addr->sa_family == AF_INET)
    {
        const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
        const unsigned char *b = (const unsigned char *)&in->sin_addr;
        int is_dash = (b[0] == 10 && b[1] == 0 && b[2] == 0); /* 10.0.0.0/24 dash subnet */
        int is_disco0 = (in->sin_addr.s_addr == 0 && in->sin_port == htons( 36002 )); /* 0.0.0.0:36002 */
        if (is_dash || is_disco0)
        {
            unsigned char *d = (unsigned char *)&tmp->sin_addr;
            *tmp = *in;
            d[0] = 127; d[1] = 0; d[2] = 0; d[3] = 1; /* 127.0.0.1 */
            if (tmp->sin_port == htons( 36002 )) tmp->sin_port = htons( 36003 );
            return (const struct sockaddr *)tmp;
        }
    }
    return addr;
}
/* ---- end verbatim ---- */

static int fails = 0;

static struct sockaddr_in mkaddr_port(const char *ip, int family, unsigned short port) {
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = (sa_family_t)family;
    a.sin_port = htons(port);
    if (ip) inet_pton(AF_INET, ip, &a.sin_addr);
    return a;
}
static struct sockaddr_in mkaddr(const char *ip, int family) { return mkaddr_port(ip, family, 2000); }

/* expect_rewrite_port: redirect must return tmp with 127.0.0.1 and the EXPECTED port —
 * 36002 (aim-ka discovery) remaps to 36003 (the relay's loopback listen port, freeing
 * 36002 for RS3's own wildcard bind); every other port is preserved. */
static void expect_rewrite_port(const char *ip, unsigned short in_port, unsigned short want_port) {
    struct sockaddr_in in = mkaddr_port(ip, AF_INET, in_port), tmp;
    const struct sockaddr *r = aim_loopback_redirect((struct sockaddr *)&in, sizeof in, &tmp);
    char got[64]; inet_ntop(AF_INET, &((struct sockaddr_in *)r)->sin_addr, got, sizeof got);
    int port_ok = (((struct sockaddr_in *)r)->sin_port == htons(want_port));
    if (r != (struct sockaddr *)&tmp || strcmp(got, "127.0.0.1") != 0 || !port_ok) {
        printf("  FAIL rewrite %s:%u -> got %s:%u want 127.0.0.1:%u (used_tmp=%d)\n", ip, in_port,
               got, ntohs(((struct sockaddr_in *)r)->sin_port), want_port, r == (struct sockaddr*)&tmp);
        fails++;
    } else printf("  ok   %s:%u -> 127.0.0.1:%u\n", ip, in_port, want_port);
}
static void expect_rewrite(const char *ip) { expect_rewrite_port(ip, 2000, 2000); }

/* expect_passthrough_port: the redirect must return the ORIGINAL addr untouched (specific port). */
static void expect_passthrough_port(const char *ip, unsigned short port) {
    struct sockaddr_in in = mkaddr_port(ip, AF_INET, port), tmp;
    const struct sockaddr *r = aim_loopback_redirect((struct sockaddr *)&in, sizeof in, &tmp);
    if (r != (struct sockaddr *)&in) { printf("  FAIL %s:%u should pass through unchanged\n", ip, port); fails++; }
    else printf("  ok   %s:%u passes through\n", ip, port);
}
/* expect_passthrough: the redirect must return the ORIGINAL addr untouched. */
static void expect_passthrough(const char *ip) {
    struct sockaddr_in in = mkaddr(ip, AF_INET), tmp;
    const struct sockaddr *r = aim_loopback_redirect((struct sockaddr *)&in, sizeof in, &tmp);
    if (r != (struct sockaddr *)&in) { printf("  FAIL %s should pass through unchanged\n", ip); fails++; }
    else printf("  ok   %s passes through\n", ip);
}

int main(void) {
    printf("ws2_redirect_unit:\n");
    /* in 10.0.0.0/28 -> rewritten */
    expect_rewrite("10.0.0.0");
    expect_rewrite("10.0.0.1");    /* the real dash */
    expect_rewrite("10.0.0.2");    /* the host's DHCP addr */
    expect_rewrite("10.0.0.15");
    expect_rewrite("10.0.0.16");   /* inside /24 (was outside the old /28) */
    expect_rewrite("10.0.0.254");
    expect_rewrite("10.0.0.255");  /* the subnet BROADCAST RS3 sends discovery to */
    /* port remap: discovery 36002 -> 36003; everything else preserved */
    expect_rewrite_port("10.0.0.255", 36002, 36003); /* broadcast discovery -> relay's 36003 */
    expect_rewrite_port("10.0.0.1", 36002, 36003);   /* aim-ka unicast -> relay's 36003 */
    expect_rewrite_port("10.0.0.1", 2000, 2000);     /* STCP data port untouched */
    expect_rewrite_port("10.0.0.1", 36003, 36003);   /* already-36003 not double-mapped */
    /* 0.0.0.0:36002 — RS3's actual discovery target under Wine — rewrites to 127.0.0.1:36003 */
    expect_rewrite_port("0.0.0.0", 36002, 36003);
    /* 0.0.0.0 on any OTHER port is NOT touched (only the discovery port) */
    expect_passthrough_port("0.0.0.0", 2000);
    expect_passthrough_port("0.0.0.0", 80);
    /* outside 10.0.0.0/24 -> passthrough */
    expect_passthrough("10.0.1.1");
    expect_passthrough("10.1.0.1");
    expect_passthrough("11.0.0.1");
    expect_passthrough("192.168.0.1");
    expect_passthrough("127.0.0.1");
    expect_passthrough("8.8.8.8");  /* public IP (license/update traffic) must NOT be touched */

    /* guards */
    struct sockaddr_in in = mkaddr("10.0.0.1", AF_INET), tmp;
    /* short length -> passthrough */
    if (aim_loopback_redirect((struct sockaddr *)&in, (int)sizeof(in) - 1, &tmp) != (struct sockaddr *)&in) {
        printf("  FAIL short-length should pass through\n"); fails++;
    } else printf("  ok   short length passes through\n");
    /* non-AF_INET -> passthrough */
    struct sockaddr_in in6fake = mkaddr("10.0.0.1", AF_INET6);
    if (aim_loopback_redirect((struct sockaddr *)&in6fake, sizeof in6fake, &tmp) != (struct sockaddr *)&in6fake) {
        printf("  FAIL non-AF_INET should pass through\n"); fails++;
    } else printf("  ok   non-AF_INET passes through\n");
    /* NULL -> returns NULL, no crash */
    if (aim_loopback_redirect(NULL, 16, &tmp) != NULL) { printf("  FAIL NULL should return NULL\n"); fails++; }
    else printf("  ok   NULL returns NULL\n");

    printf("%s\n", fails ? "FAILED" : "PASSED");
    return fails ? 1 : 0;
}
