#include "WorkTimerWindows.h"
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>
#include <wincrypt.h>
#include <iphlpapi.h>
#include <ipifcons.h>
#include <windns.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static INIT_ONCE initialized = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK initialize(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    WSADATA data;
    return WSAStartup(MAKEWORD(2,2), &data) == 0;
}

/* Fail closed: direct on-link IPv4 over a physical Wi-Fi/Ethernet interface only.
   A private VPN destination must not pass simply because it is RFC1918. */
static int on_lan(const char *address) {
    if (!InitOnceExecuteOnce(&initialized, initialize, NULL, NULL)) return 0;
    SOCKADDR_INET destination = {0};
    destination.Ipv4.sin_family = AF_INET;
    if (InetPtonA(AF_INET, address, &destination.Ipv4.sin_addr) != 1) return 0;
    uint32_t ip = ntohl(destination.Ipv4.sin_addr.s_addr);
    if (!((ip >> 24) == 10 || (ip >> 20) == 0xac1 || (ip >> 16) == 0xc0a8)) return 0;
    MIB_IPFORWARD_ROW2 route;
    SOCKADDR_INET source;
    if (GetBestRoute2(NULL, 0, NULL, &destination, 0, &route, &source) != NO_ERROR) return 0;
    if (route.NextHop.Ipv4.sin_addr.s_addr != 0) return 0;
    MIB_IF_ROW2 interface_row = {0};
    interface_row.InterfaceLuid = route.InterfaceLuid;
    if (GetIfEntry2(&interface_row) != NO_ERROR) return 0;
    return interface_row.OperStatus == IfOperStatusUp
        && interface_row.InterfaceAndOperStatusFlags.HardwareInterface
        && !interface_row.InterfaceAndOperStatusFlags.FilterInterface
        && (interface_row.Type == IF_TYPE_ETHERNET_CSMACD || interface_row.Type == IF_TYPE_IEEE80211);
}

int wt_resolve_lan(const char *hostname, char *ipv4, size_t capacity) {
    if (!InitOnceExecuteOnce(&initialized, initialize, NULL, NULL)) return 0;
    ADDRINFOA hints = {0}, *addresses = NULL;
    hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(hostname, NULL, &hints, &addresses) != 0) return 0;
    int found = 0;
    for (ADDRINFOA *item = addresses; item; item = item->ai_next) {
        char buffer[INET_ADDRSTRLEN];
        struct sockaddr_in *socket_address = (struct sockaddr_in *)item->ai_addr;
        if (InetNtopA(AF_INET, &socket_address->sin_addr, buffer, sizeof(buffer)) && on_lan(buffer)) {
            if (strlen(buffer) + 1 <= capacity) { strcpy_s(ipv4, capacity, buffer); found = 1; }
            break;
        }
    }
    freeaddrinfo(addresses);
    return found;
}

int wt_post(const char *ipv4, uint16_t port, const char *pin,
            const uint8_t *body, uint32_t length, uint8_t *response, uint32_t capacity,
            uint32_t *response_length) {
    int result = 0;
    HINTERNET session = NULL, connection = NULL, request = NULL;
    PCCERT_CONTEXT certificate = NULL;
    if (!on_lan(ipv4) || strlen(pin) != 64 || length > (8u << 20)) return 0;
    wchar_t host[64];
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, ipv4, -1, host, 64)) return 0;
    session = WinHttpOpen(L"WorkTimer/1", WINHTTP_ACCESS_TYPE_NO_PROXY, NULL, NULL, 0);
    if (!session) goto finish;
    WinHttpSetTimeouts(session, 3000, 3000, 5000, 5000);
    DWORD protocols = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2;
    WinHttpSetOption(session, WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols, sizeof(protocols));
    connection = WinHttpConnect(session, host, port, 0);
    if (!connection) goto finish;
    request = WinHttpOpenRequest(connection, L"POST", L"/v1/sync", NULL, NULL, NULL, WINHTTP_FLAG_SECURE);
    if (!request) goto finish;
    DWORD redirects = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    if (!WinHttpSetOption(request, WINHTTP_OPTION_REDIRECT_POLICY, &redirects, sizeof(redirects))) goto finish;
    /* Pairing pins the complete DER certificate instead of trusting a public CA.
       Headers contain no credentials; authenticate the TLS peer BEFORE writing
       the body containing timing data and the pairing token. */
    DWORD flags = SECURITY_FLAG_IGNORE_UNKNOWN_CA | SECURITY_FLAG_IGNORE_CERT_CN_INVALID
        | SECURITY_FLAG_IGNORE_CERT_DATE_INVALID | SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
    if (!WinHttpSetOption(request, WINHTTP_OPTION_SECURITY_FLAGS, &flags, sizeof(flags))) goto finish;
    if (!WinHttpSendRequest(request, L"Content-Type: application/json\r\n", (DWORD)-1,
                            NULL, 0, length, 0)) goto finish;
    DWORD certificate_size = sizeof(certificate);
    if (!WinHttpQueryOption(request, WINHTTP_OPTION_SERVER_CERT_CONTEXT, &certificate, &certificate_size)) goto finish;
    BYTE digest[32]; DWORD digest_size = sizeof(digest);
    if (!CryptHashCertificate2(L"SHA256", 0, NULL, certificate->pbCertEncoded, certificate->cbCertEncoded,
                              digest, &digest_size) || digest_size != 32) goto finish;
    unsigned mismatch = 0;
    for (unsigned i = 0; i < 32; i++) {
        unsigned byte_value;
        if (sscanf_s(pin + 2*i, "%2x", &byte_value) != 1) goto finish;
        mismatch |= digest[i] ^ byte_value;
    }
    if (mismatch || !on_lan(ipv4)) goto finish;
    DWORD written = 0;
    if (!WinHttpWriteData(request, body, length, &written) || written != length) goto finish;
    if (!WinHttpReceiveResponse(request, NULL)) goto finish;
    DWORD status = 0, status_size = sizeof(status);
    if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             NULL, &status, &status_size, NULL) || status != 200) goto finish;
    DWORD total = 0;
    while (total < capacity) {
        DWORD count = 0;
        if (!WinHttpReadData(request, response + total, capacity - total, &count)) goto finish;
        if (!count) { *response_length = total; result = 1; goto finish; }
        total += count;
    }
finish:
    if (certificate) CertFreeCertificateContext(certificate);
    if (request) WinHttpCloseHandle(request);
    if (connection) WinHttpCloseHandle(connection);
    if (session) WinHttpCloseHandle(session);
    return result;
}

static SRWLOCK discovery_lock = SRWLOCK_INIT;
static wchar_t service_name[128];
static char discovered_host[256];
static uint16_t discovered_port;
static DNS_SERVICE_BROWSE_REQUEST browse_requests[16];
static DNS_SERVICE_CANCEL browse_cancels[16];
static void WINAPI browse_callback(DWORD status, void *context, DNS_RECORD *records) {
    if (status == ERROR_SUCCESS) {
        for (DNS_RECORD *r = records; r; r = r->pNext) {
            if (r->wType != DNS_TYPE_SRV || !r->pName || _wcsicmp(r->pName, service_name)) continue;
            char hostname[256];
            if (WideCharToMultiByte(CP_UTF8, 0, r->Data.SRV.pNameTarget, -1, hostname, sizeof(hostname), NULL, NULL)) {
                AcquireSRWLockExclusive(&discovery_lock);
                strcpy_s(discovered_host, sizeof(discovered_host), hostname);
                discovered_port = r->Data.SRV.wPort;
                ReleaseSRWLockExclusive(&discovery_lock);
            }
        }
    }
    if (records) DnsRecordListFree(records, DnsFreeRecordList);
}

void wt_discovery_start(const char *receiver_id) {
    wchar_t id[64];
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, receiver_id, -1, id, 64)) return;
    swprintf_s(service_name, 128, L"%ls._worktimer._tcp.local", id);
    ULONG size = 0;
    GetAdaptersAddresses(AF_INET, 0, NULL, NULL, &size);
    IP_ADAPTER_ADDRESSES *adapters = malloc(size);
    if (!adapters) return;
    if (GetAdaptersAddresses(AF_INET, 0, NULL, adapters, &size) == NO_ERROR) {
        unsigned index = 0;
        for (IP_ADAPTER_ADDRESSES *a = adapters; a && index < 16; a = a->Next) {
            MIB_IF_ROW2 row = {0}; row.InterfaceLuid = a->Luid;
            if (GetIfEntry2(&row) != NO_ERROR || row.OperStatus != IfOperStatusUp
                || !row.InterfaceAndOperStatusFlags.HardwareInterface
                || (row.Type != IF_TYPE_IEEE80211 && row.Type != IF_TYPE_ETHERNET_CSMACD)) continue;
            DNS_SERVICE_BROWSE_REQUEST *request = &browse_requests[index];
            request->Version = DNS_QUERY_REQUEST_VERSION1;
            request->InterfaceIndex = a->IfIndex;
            request->QueryName = L"_worktimer._tcp.local";
            request->pBrowseCallback = browse_callback;
            DnsServiceBrowse(request, &browse_cancels[index]);
            index++;
        }
    }
    free(adapters);
}

int wt_discovery_endpoint(char *hostname, size_t capacity, uint16_t *port) {
    AcquireSRWLockShared(&discovery_lock);
    int found = discovered_port && strlen(discovered_host) + 1 <= capacity;
    if (found) { strcpy_s(hostname, capacity, discovered_host); *port = discovered_port; }
    ReleaseSRWLockShared(&discovery_lock);
    return found;
}

static volatile LONG changed;
static DWORD WINAPI watch_directory(void *directory) {
    HANDLE handle = directory;
    BYTE buffer[32768]; DWORD count;
    while (ReadDirectoryChangesW(handle, buffer, sizeof(buffer), TRUE,
            FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE,
            &count, NULL, NULL)) InterlockedExchange(&changed, 1);
    InterlockedExchange(&changed, 1);
    CloseHandle(handle);
    return 0;
}
int wt_watch(const char *directory) {
    wchar_t path[32768];
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, directory, -1, path, 32768)) return 0;
    HANDLE handle = CreateFileW(path, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (handle == INVALID_HANDLE_VALUE) return 0;
    HANDLE thread = CreateThread(NULL, 0, watch_directory, handle, 0, NULL);
    if (!thread) { CloseHandle(handle); return 0; }
    CloseHandle(thread);
    return 1;
}
int wt_take_changes(void) { return InterlockedExchange(&changed, 0) != 0; }
int wt_lock(const char *path) {
    wchar_t wide[32768];
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, 32768)) return 0;
    HANDLE handle = CreateFileW(wide, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    /* The OS releases this process-lifetime lock on exit, including crashes. */
    return handle != INVALID_HANDLE_VALUE;
}
#else
int wt_resolve_lan(const char *h, char *a, size_t n) { return 0; }
int wt_post(const char *a, uint16_t p, const char *s, const uint8_t *b, uint32_t n, uint8_t *r, uint32_t c, uint32_t *l) { return 0; }
void wt_discovery_start(const char *id) {}
int wt_discovery_endpoint(char *h, size_t n, uint16_t *p) { return 0; }
int wt_watch(const char *p) { return 0; }
int wt_take_changes(void) { return 0; }
int wt_lock(const char *path) { return 1; }
#endif
