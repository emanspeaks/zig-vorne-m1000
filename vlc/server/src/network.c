#include "network.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ws2tcpip.h>

#define MULTICAST_PORT 12345
#define MULTICAST_IP "239.255.255.250"

// Get current Unix timestamp in milliseconds
long long getUnixTimeMs() {
    FILETIME ft;
    ULARGE_INTEGER uli;
    GetSystemTimeAsFileTime(&ft);
    uli.LowPart = ft.dwLowDateTime;
    uli.HighPart = ft.dwHighDateTime;
    
    // Convert from Windows FILETIME (100ns intervals since Jan 1, 1601)
    // to Unix timestamp (ms since Jan 1, 1970)
    return (uli.QuadPart / 10000) - 11644473600000LL;
}

// Initialize Winsock
int initialize_winsock() {
    WSADATA wsaData;
    int result = WSAStartup(MAKEWORD(2, 2), &wsaData);
    if (result != 0) {
        printf("WSAStartup failed: %d\n", result);
        return 0;
    }
    return 1;
}

// Cleanup Winsock
void cleanup_winsock() {
    WSACleanup();
}

// Create multicast socket
SOCKET create_multicast_socket() {
    SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == INVALID_SOCKET) {
        printf("Socket creation failed: %d\n", WSAGetLastError());
        return INVALID_SOCKET;
    }
    
    // Enable SO_REUSEADDR
    int reuse = 1;
    if (setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (char*)&reuse, sizeof(reuse)) < 0) {
        printf("setsockopt SO_REUSEADDR failed: %d\n", WSAGetLastError());
        closesocket(sock);
        return INVALID_SOCKET;
    }
    
    // Set TTL for multicast
    int ttl = 1;
    if (setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, (char*)&ttl, sizeof(ttl)) < 0) {
        printf("setsockopt IP_MULTICAST_TTL failed: %d\n", WSAGetLastError());
        closesocket(sock);
        return INVALID_SOCKET;
    }
    
    return sock;
}

// Send data via multicast
int send_multicast_data(SOCKET sock, const char *data) {
    struct sockaddr_in multicast_addr;
    memset(&multicast_addr, 0, sizeof(multicast_addr));
    multicast_addr.sin_family = AF_INET;
    multicast_addr.sin_port = htons(MULTICAST_PORT);
    inet_pton(AF_INET, MULTICAST_IP, &multicast_addr.sin_addr);
    
    int result = sendto(sock, data, (int)strlen(data), 0,
                       (struct sockaddr*)&multicast_addr, sizeof(multicast_addr));
    
    if (result == SOCKET_ERROR) {
        printf("Multicast send failed: %d\n", WSAGetLastError());
        return 0;
    }
    
    return 1;
}

// Create JSON status message with timestamp
char *create_status_json_with_timestamp(const vlc_status_t *status, long long server_timestamp_ms) {
    if (!status) {
        return NULL;
    }

    // Allocate buffer for JSON - make it large enough for all content
    char *json = malloc(2048);
    if (!json) {
        return NULL;
    }

    // Determine status text
    const char *state_str;
    if (status->is_playing) {
        state_str = "Playing";
    } else if (status->is_paused) {
        state_str = "Paused";
    } else if (status->is_stopped) {
        state_str = "Stopped";
    } else {
        state_str = "Unknown";
    }

    // Check if we have meaningful media info
    int has_media = (status->duration > 0 || strlen(status->filename) > 0) && strcmp(status->filename, "No media") != 0;
    const char *media_status = has_media ? "Loaded" : "None";

    // Create JSON message
    int is_loading = status->is_loading;
    snprintf(json, 2048,
             "{"
             "\"server_timestamp\": %lld,"
             "\"state\": \"%s\","
             "\"is_playing\": %s,"
             "\"is_paused\": %s,"
             "\"is_stopped\": %s,"
             "\"is_loading\": %s,"
             "\"media_status\": \"%s\","
             "\"time_ms\": %lld,"
             "\"duration_ms\": %lld,"
             "\"title\": \"%s\","
             "\"filename\": \"%s\""
             "}",
             server_timestamp_ms,
             state_str,
             status->is_playing ? "true" : "false",
             status->is_paused ? "true" : "false",
             status->is_stopped ? "true" : "false",
             is_loading ? "true" : "false",
             media_status,
             status->time,
             status->duration,
             status->title,
             status->filename
    );

    return json;
}