/* loopback_probe.c — win32 Winsock client for the macOS Local Network gate test (Phase 1.5).
 *
 * Runs UNDER the bundled Wine (the exact unix-loader macOS gates). Connects to a loopback
 * address and sends a token over TCP and UDP. If the bytes reach the native listener, the
 * Wine guest's loopback traffic is NOT dropped by the Local Network gate — which is the
 * load-bearing premise of the whole A2 bridge architecture.
 *
 * Build (no mingw needed):
 *   zig cc -target x86_64-windows-gnu -O2 loopback_probe.c -o loopback_probe.exe -lws2_32
 *
 * Usage (under Wine): loopback_probe.exe <ip> <tcp_port> <udp_port> <token>
 * Exit 0 only if BOTH TCP connect+send and UDP sendto succeed.
 */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *ip    = argc > 1 ? argv[1] : "127.0.0.1";
    int   tcp_port    = argc > 2 ? atoi(argv[2]) : 2000;
    int   udp_port    = argc > 3 ? atoi(argv[3]) : 36002;
    const char *token = argc > 4 ? argv[4] : "WINEPROBE";

    WSADATA w;
    if (WSAStartup(MAKEWORD(2, 2), &w) != 0) { printf("FAIL WSAStartup\n"); return 2; }

    /* TCP: connect + send */
    int tcp_ok = 0;
    SOCKET ts = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (ts != INVALID_SOCKET) {
        struct sockaddr_in ta; memset(&ta, 0, sizeof ta);
        ta.sin_family = AF_INET; ta.sin_port = htons((u_short)tcp_port);
        ta.sin_addr.s_addr = inet_addr(ip);
        if (connect(ts, (struct sockaddr *)&ta, sizeof ta) == 0) {
            char buf[64]; int n = snprintf(buf, sizeof buf, "TCP:%s", token);
            if (send(ts, buf, n, 0) == n) tcp_ok = 1;
        } else {
            printf("  (TCP connect errno=%d)\n", WSAGetLastError());
        }
        closesocket(ts);
    }
    printf("%s TCP connect+send to %s:%d\n", tcp_ok ? "PASS" : "FAIL", ip, tcp_port);

    /* UDP: sendto */
    int udp_ok = 0;
    SOCKET us = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (us != INVALID_SOCKET) {
        struct sockaddr_in ua; memset(&ua, 0, sizeof ua);
        ua.sin_family = AF_INET; ua.sin_port = htons((u_short)udp_port);
        ua.sin_addr.s_addr = inet_addr(ip);
        char buf[64]; int n = snprintf(buf, sizeof buf, "UDP:%s", token);
        if (sendto(us, buf, n, 0, (struct sockaddr *)&ua, sizeof ua) == n) udp_ok = 1;
        else printf("  (UDP sendto errno=%d)\n", WSAGetLastError());
        closesocket(us);
    }
    printf("%s UDP sendto %s:%d\n", udp_ok ? "PASS" : "FAIL", ip, udp_port);

    WSACleanup();
    return (tcp_ok && udp_ok) ? 0 : 1;
}
