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
        const unsigned char *b = (const unsigned char *)&((const struct sockaddr_in *)addr)->sin_addr;
        if (b[0] == 10 && b[1] == 0 && b[2] == 0 && b[3] <= 15) /* 10.0.0.0/28 */
        {
            unsigned char *d = (unsigned char *)&tmp->sin_addr;
            *tmp = *(const struct sockaddr_in *)addr;
            d[0] = 127; d[1] = 0; d[2] = 0; d[3] = 1; /* 127.0.0.1 */
            return (const struct sockaddr *)tmp;
        }
    }
    return addr;
}
/* ---- end verbatim ---- */

static int fails = 0;

static struct sockaddr_in mkaddr(const char *ip, int family) {
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = (sa_family_t)family;
    a.sin_port = htons(2000);
    if (ip) inet_pton(AF_INET, ip, &a.sin_addr);
    return a;
}

/* expect_rewrite: the redirect must return tmp with 127.0.0.1 and preserve the port. */
static void expect_rewrite(const char *ip) {
    struct sockaddr_in in = mkaddr(ip, AF_INET), tmp;
    const struct sockaddr *r = aim_loopback_redirect((struct sockaddr *)&in, sizeof in, &tmp);
    char got[64]; inet_ntop(AF_INET, &((struct sockaddr_in *)r)->sin_addr, got, sizeof got);
    int port_ok = (((struct sockaddr_in *)r)->sin_port == htons(2000));
    if (r != (struct sockaddr *)&tmp || strcmp(got, "127.0.0.1") != 0 || !port_ok) {
        printf("  FAIL rewrite %s -> got %s (port_ok=%d, used_tmp=%d)\n", ip, got, port_ok, r == (struct sockaddr*)&tmp);
        fails++;
    } else printf("  ok   %s -> 127.0.0.1 (port preserved)\n", ip);
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
    expect_rewrite("10.0.0.15");   /* top of /28 */
    /* outside /28 -> passthrough */
    expect_passthrough("10.0.0.16");
    expect_passthrough("10.0.0.255");
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
