#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <winsock2.h>
#include <windows.h>
#include <time.h>
#include <ws2tcpip.h>
#include <stdint.h>

#define VLC_RC_HOST "127.0.0.1"
#define VLC_RC_PORT 4212
#define MULTICAST_GROUP "239.255.0.100"
#define MULTICAST_PORT 8888
#define UPDATE_INTERVAL_MS 200  // 5Hz (every 200ms)

// VLC status structure
typedef struct {
    int is_playing;
    long long time;
    long long duration;
    char title[256];
    char filename[256];
} vlc_status_t;

// RC connection structure
typedef struct {
    SOCKET socket;
    int connected;
} vlc_rc_connection_t;

int debug_mode = 0;

// Function declarations
long long getUnixTimeMs();
int initialize_winsock();
void cleanup_winsock();
SOCKET create_multicast_socket();
int send_multicast_data(SOCKET sock, const char *data);
vlc_rc_connection_t *vlc_rc_connect(const char *host, int port);
void vlc_rc_disconnect(vlc_rc_connection_t *conn);
char *vlc_rc_command(vlc_rc_connection_t *conn, const char *command);
int query_vlc_status_rc(vlc_rc_connection_t *conn, vlc_status_t *status);
char *create_status_json_with_timestamp(const vlc_status_t *status, long long server_timestamp_ms);
void print_status(const vlc_status_t *status);
void print_usage(const char *program_name);

// Get Unix timestamp in milliseconds (UTC)
long long getUnixTimeMs() {
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    ULARGE_INTEGER ull;
    ull.LowPart = ft.dwLowDateTime;
    ull.HighPart = ft.dwHighDateTime;
    ull.QuadPart /= 10000; // Convert to milliseconds since 1601
    ull.QuadPart -= 11644473600000LL; // Subtract milliseconds from 1601 to 1970
    return ull.QuadPart;
}

// Main server loop
int main(int argc, char *argv[]) {
    // Parse command line arguments for debug flag
    if (argc > 1) {
        if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        }
        if (strcmp(argv[1], "--debug") == 0) {
            debug_mode = 1;
            printf("Debug mode enabled.\n");
        }
    }

    printf("VLC Status Server starting...\n");

    // Initialize Winsock
    if (!initialize_winsock()) {
        fprintf(stderr, "Failed to initialize Winsock\n");
        return 1;
    }

    // Create multicast socket
    SOCKET multicast_sock = create_multicast_socket();
    if (multicast_sock == INVALID_SOCKET) {
        fprintf(stderr, "Failed to create multicast socket\n");
        cleanup_winsock();
        return 1;
    }

    printf("Server started successfully\n");

    // Display connection info
    SYSTEMTIME st;
    GetSystemTime(&st);
    char time_str[64];
    snprintf(time_str, sizeof(time_str), "%04d-%02d-%02d %02d:%02d:%02d.%03d",
           st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    printf("[%s] Connecting to VLC RC at %s:%d\n", time_str, VLC_RC_HOST, VLC_RC_PORT);
    printf("[%s] Broadcasting to %s:%d\n", time_str, MULTICAST_GROUP, MULTICAST_PORT);

    vlc_status_t current_status = {0};
    vlc_status_t last_status = {0};
    vlc_rc_connection_t *vlc_conn = NULL;

    // Main loop
    while (1) {
        DWORD frame_start = GetTickCount();

        if (debug_mode) {
            static DWORD last_query_time = 0;
            DWORD current_time = GetTickCount();
            if (last_query_time > 0) {
                printf("[DEBUG] Query interval: %lu ms\n", current_time - last_query_time);
            }
            last_query_time = current_time;
        }

        // Get server timestamp at poll time (UTC milliseconds)
        long long server_timestamp_ms = getUnixTimeMs();

        // Connect to VLC RC if not connected
        if (!vlc_conn || !vlc_conn->connected) {
            if (vlc_conn) {
                vlc_rc_disconnect(vlc_conn);
            }
            vlc_conn = vlc_rc_connect(VLC_RC_HOST, VLC_RC_PORT);
        }

        // Query VLC status via RC interface
        int status_ok = 0;
        if (vlc_conn && vlc_conn->connected) {
            status_ok = query_vlc_status_rc(vlc_conn, &current_status);
        }

        if (status_ok) {
            // Check if status has changed (excluding timestamp field)
            int status_changed = 0;
            if (current_status.is_playing != last_status.is_playing ||
                current_status.time != last_status.time ||
                current_status.duration != last_status.duration ||
                strcmp(current_status.title, last_status.title) != 0 ||
                strcmp(current_status.filename, last_status.filename) != 0) {
                status_changed = 1;
            }

            if (debug_mode) {
                printf("[DEBUG] Query result - Playing: %s, Time: %lld ms, Status changed: %s\n",
                       current_status.is_playing ? "Yes" : "No",
                       current_status.time,
                       status_changed ? "Yes" : "No");
            }

            if (status_changed) {
                // Update last status
                memcpy(&last_status, &current_status, sizeof(vlc_status_t));
            }

            // Always send the current status
            char *json_message = create_status_json_with_timestamp(&current_status, server_timestamp_ms);
            if (json_message) {
                if (debug_mode) {
                    printf("[DEBUG] Multicast JSON: %s\n", json_message);
                }
                // Send via multicast
                if (send_multicast_data(multicast_sock, json_message)) {
                    // Get current timestamp with subsecond precision (UTC)
                    SYSTEMTIME st;
                    GetSystemTime(&st);
                    char time_str[32];
                    snprintf(time_str, sizeof(time_str), "%02d:%02d:%02d.%03d",
                           st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);

                    printf("[%s] Status broadcast: %s - %s\n",
                           time_str,
                           current_status.is_playing ? "Playing" : "Stopped",
                           current_status.title[0] ? current_status.title : "Unknown");
                    if (debug_mode) {
                        print_status(&current_status);
                    }
                }
                free(json_message);
            }
        } else {
            // VLC not responding - always send stopped status
            current_status.is_playing = 0;
            current_status.time = 0;
            current_status.duration = 0;
            strcpy(current_status.title, "No media");
            strcpy(current_status.filename, "");

            char *json_message = create_status_json_with_timestamp(&current_status, server_timestamp_ms);
            if (json_message) {
                send_multicast_data(multicast_sock, json_message);
                free(json_message);
            }

            memcpy(&last_status, &current_status, sizeof(vlc_status_t));
            // Get current timestamp with subsecond precision (UTC)
            SYSTEMTIME st;
            GetSystemTime(&st);
            char time_str[32];
            snprintf(time_str, sizeof(time_str), "%02d:%02d:%02d.%03d",
                   st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);

            printf("[%s] VLC not responding - sent stopped status\n", time_str);
            if (debug_mode) {
                printf("[DEBUG] VLC not responding, sent stopped status\n");
            }
        }

        // Calculate sleep time to maintain fixed frame rate
        DWORD frame_end = GetTickCount();
        DWORD frame_duration = frame_end - frame_start;
        DWORD sleep_time = 0;

        if (frame_duration < UPDATE_INTERVAL_MS) {
            sleep_time = UPDATE_INTERVAL_MS - frame_duration;
        }
        // If frame took longer than UPDATE_INTERVAL_MS, sleep_time remains 0

        if (sleep_time > 0) {
            Sleep(sleep_time);
        }
        // Note: If sleep_time is 0, we skip sleep to maintain responsiveness
    }

    // Cleanup (this code is never reached in normal operation)
    if (vlc_conn) {
        vlc_rc_disconnect(vlc_conn);
    }
    closesocket(multicast_sock);
    cleanup_winsock();
    return 0;
}

// Initialize Winsock
int initialize_winsock() {
    WSADATA wsaData;
    return WSAStartup(MAKEWORD(2, 2), &wsaData) == 0;
}

// Cleanup Winsock
void cleanup_winsock() {
    WSACleanup();
}

// Create multicast socket
SOCKET create_multicast_socket() {
    SOCKET sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock == INVALID_SOCKET) {
        return INVALID_SOCKET;
    }

    // Set socket options for multicast
    int reuse = 1;
    if (setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (char*)&reuse, sizeof(reuse)) < 0) {
        closesocket(sock);
        return INVALID_SOCKET;
    }

    // Bind to any address
    struct sockaddr_in local_addr = {0};
    local_addr.sin_family = AF_INET;
    local_addr.sin_addr.s_addr = INADDR_ANY;
    local_addr.sin_port = 0;  // Let system choose port

    if (bind(sock, (struct sockaddr*)&local_addr, sizeof(local_addr)) < 0) {
        closesocket(sock);
        return INVALID_SOCKET;
    }

    return sock;
}

// Send data via multicast
int send_multicast_data(SOCKET sock, const char *data) {
    struct sockaddr_in multicast_addr = {0};
    multicast_addr.sin_family = AF_INET;
    multicast_addr.sin_addr.s_addr = inet_addr(MULTICAST_GROUP);
    multicast_addr.sin_port = htons(MULTICAST_PORT);

    int len = sendto(sock, data, strlen(data), 0,
                     (struct sockaddr*)&multicast_addr, sizeof(multicast_addr));

    return len > 0;
}

// Connect to VLC RC interface
vlc_rc_connection_t *vlc_rc_connect(const char *host, int port) {
    vlc_rc_connection_t *conn = malloc(sizeof(vlc_rc_connection_t));
    if (!conn) {
        return NULL;
    }

    conn->socket = INVALID_SOCKET;
    conn->connected = 0;

    // Create TCP socket
    conn->socket = socket(AF_INET, SOCK_STREAM, 0);
    if (conn->socket == INVALID_SOCKET) {
        free(conn);
        return NULL;
    }

    // Set socket timeout
    struct timeval timeout;
    timeout.tv_sec = 1;
    timeout.tv_usec = 0;
    setsockopt(conn->socket, SOL_SOCKET, SO_RCVTIMEO, (char*)&timeout, sizeof(timeout));
    setsockopt(conn->socket, SOL_SOCKET, SO_SNDTIMEO, (char*)&timeout, sizeof(timeout));

    // Connect to VLC RC interface
    struct sockaddr_in server_addr = {0};
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(port);

    if (inet_pton(AF_INET, host, &server_addr.sin_addr) <= 0) {
        closesocket(conn->socket);
        free(conn);
        return NULL;
    }

    if (connect(conn->socket, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        if (debug_mode) {
            printf("[DEBUG] Failed to connect to VLC RC interface at %s:%d\n", host, port);
        }
        closesocket(conn->socket);
        free(conn);
        return NULL;
    }

    // Read welcome message and discard it
    char buffer[4096];
    int received = recv(conn->socket, buffer, sizeof(buffer) - 1, 0);
    if (received > 0) {
        buffer[received] = '\0';
        if (debug_mode) {
            printf("[DEBUG] VLC RC welcome: %s\n", buffer);
        }
    } else {
        if (debug_mode) {
            printf("[DEBUG] No welcome message received\n");
        }
    }

    conn->connected = 1;
    if (debug_mode) {
        printf("[DEBUG] Connected to VLC RC interface\n");
    }
    return conn;
}

// Disconnect from VLC RC interface
void vlc_rc_disconnect(vlc_rc_connection_t *conn) {
    if (!conn) return;

    if (conn->socket != INVALID_SOCKET) {
        closesocket(conn->socket);
    }
    conn->connected = 0;
    free(conn);
}

// Send command to VLC RC and get response
char *vlc_rc_command(vlc_rc_connection_t *conn, const char *command) {
    if (!conn || !conn->connected || conn->socket == INVALID_SOCKET) {
        return NULL;
    }

    // Send command with newline
    char cmd_with_newline[512];
    snprintf(cmd_with_newline, sizeof(cmd_with_newline), "%s\n", command);

    if (send(conn->socket, cmd_with_newline, strlen(cmd_with_newline), 0) < 0) {
        conn->connected = 0;
        return NULL;
    }

    // Read response
    char *response = malloc(4096);
    if (!response) {
        return NULL;
    }

    int received = recv(conn->socket, response, 4095, 0);
    if (received <= 0) {
        free(response);
        if (received < 0) {
            conn->connected = 0;
        }
        return NULL;
    }

    response[received] = '\0';

    // Clean up response - remove trailing whitespace and prompt
    char *end = response + received - 1;
    while (end >= response && (*end == '\n' || *end == '\r' || *end == ' ' || *end == '>')) {
        *end = '\0';
        end--;
    }

    // Remove leading whitespace
    char *start = response;
    while (*start == ' ' || *start == '\n' || *start == '\r') {
        start++;
    }

    // Create cleaned response
    char *cleaned = malloc(strlen(start) + 1);
    if (cleaned) {
        strcpy(cleaned, start);
    }
    free(response);

    if (debug_mode && cleaned) {
        printf("[DEBUG] VLC RC command '%s' response: '%s'\n", command, cleaned);
    }

    return cleaned;
}

// Query VLC status using RC interface
int query_vlc_status_rc(vlc_rc_connection_t *conn, vlc_status_t *status) {
    if (!conn || !status) {
        return 0;
    }

    // Initialize status
    memset(status, 0, sizeof(vlc_status_t));

    // Get playing status
    char *is_playing_resp = vlc_rc_command(conn, "is_playing");
    if (is_playing_resp) {
        status->is_playing = (strstr(is_playing_resp, "1") != NULL);
        free(is_playing_resp);
    }

    // Get current time (in seconds, convert to milliseconds)
    char *time_resp = vlc_rc_command(conn, "get_time");
    if (time_resp) {
        double time_sec = atof(time_resp);
        status->time = (long long)(time_sec * 1000);
        free(time_resp);
    }

    // Get duration (in seconds, convert to milliseconds)
    char *length_resp = vlc_rc_command(conn, "get_length");
    if (length_resp) {
        double length_sec = atof(length_resp);
        status->duration = (long long)(length_sec * 1000);
        free(length_resp);
    }

    // Get title/filename
    char *title_resp = vlc_rc_command(conn, "get_title");
    if (title_resp && strlen(title_resp) > 0) {
        strncpy(status->title, title_resp, sizeof(status->title) - 1);
        strncpy(status->filename, title_resp, sizeof(status->filename) - 1);
        free(title_resp);
    } else {
        strcpy(status->title, "Unknown");
        strcpy(status->filename, "");
    }

    return 1;
}

// Create JSON message for broadcasting
char *create_status_json_with_timestamp(const vlc_status_t *status, long long server_timestamp_ms) {
    if (!status) {
        return NULL;
    }

    char *json = malloc(2048);
    if (!json) {
        return NULL;
    }

    // Create JSON message
    snprintf(json, 2048,
             "{"
             "\"server_timestamp\": %lld,"
             "\"server_id\": \"vlc-status-server\","
             "\"vlc_data\": {"
             "\"is_playing\": %s,"
             "\"time\": %lld,"
             "\"duration\": %lld,"
             "\"title\": \"%s\","
             "\"filename\": \"%s\""
             "}"
             "}",
             server_timestamp_ms,
             status->is_playing ? "true" : "false",
             status->time,
             status->duration,
             status->title,
             status->filename);

    return json;
}

// Print status for debugging
void print_status(const vlc_status_t *status) {
    printf("  Playing: %s\n", status->is_playing ? "Yes" : "No");
    printf("  Time: %lld ms (%.2f sec)\n", status->time, status->time / 1000.0);
    printf("  Duration: %lld ms (%.2f sec)\n", status->duration, status->duration / 1000.0);
    printf("  Title: %s\n", status->title);
    printf("  Filename: %s\n", status->filename);
}

// Print usage information
void print_usage(const char *program_name) {
    printf("VLC Status Server - Broadcasts VLC playback status via UDP multicast\n\n");
    printf("Usage: %s [--debug]\n\n", program_name);
    printf("Arguments:\n");
    printf("  --debug     Enable verbose debug output\n");
    printf("  --help, -h  Show this help message\n\n");
    printf("Examples:\n");
    printf("  %s                    # Connect to VLC RC interface\n", program_name);
    printf("  %s --debug            # Enable debug output\n", program_name);
    printf("  %s --help             # Show this help message\n\n", program_name);
    printf("VLC must be started with RC interface enabled:\n");
    printf("  vlc --rc-host=127.0.0.1 --rc-port=4212\n\n");
    printf("The server will connect to VLC RC at 127.0.0.1:4212\n");
    printf("and broadcast status updates to UDP multicast group 239.255.0.100:8888\n");
}
