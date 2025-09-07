#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <winsock2.h>
#include <windows.h>
#include <time.h>
#include <ws2tcpip.h>
#include <stdint.h>

#define VLC_HTTP_HOST "127.0.0.1"
#define VLC_HTTP_PORT 8080
#define MULTICAST_GROUP "239.255.0.100"
#define MULTICAST_PORT 8888
#define UPDATE_INTERVAL_MS 200  // 5Hz (every 200ms)
#define BUFFER_SIZE 4096
#define MAX_PASSWORD_LEN 256

// VLC status structure
typedef struct {
    time_t timestamp;
    int is_playing;
    double position;
    long long time;
    long long duration;
    double rate;
    char title[256];
    char artist[256];
    char album[256];
    char filename[256];
    char uri[1024];
} vlc_status_t;

// HTTP response structure
typedef struct {
    char *data;
    size_t size;
} http_response_t;

// Global password variable
char vlc_password[MAX_PASSWORD_LEN] = "";
int debug_mode = 0; // Global debug flag

// Function declarations
int initialize_winsock();
void cleanup_winsock();
SOCKET create_multicast_socket();
int send_multicast_data(SOCKET sock, const char *data);
http_response_t *http_get(const char *host, int port, const char *path, const char *password);
void free_http_response(http_response_t *response);
int parse_vlc_status(const char *json, vlc_status_t *status);
char *create_status_json(const vlc_status_t *status);
void print_status(const vlc_status_t *status);
void print_usage(const char *program_name);
char *base64_encode(const char *input);

// Main server loop
int main(int argc, char *argv[]) {
    // Parse command line arguments
    int arg_idx = 1;
    if (argc > 1) {
        if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        }
        // Check for debug flag in first or second argument
        if (strcmp(argv[1], "--debug") == 0) {
            debug_mode = 1;
            arg_idx = 2;
        } else if (argc > 2 && strcmp(argv[2], "--debug") == 0) {
            debug_mode = 1;
        }
        // Assume first argument is the password (unless it's --debug)
        if (arg_idx < argc && strcmp(argv[arg_idx], "--debug") != 0) {
            strncpy(vlc_password, argv[arg_idx], MAX_PASSWORD_LEN - 1);
            vlc_password[MAX_PASSWORD_LEN - 1] = '\0';
        }
        printf("Using VLC HTTP password: %s\n", strlen(vlc_password) > 0 ? "***" : "(none)");
        if (debug_mode) {
            printf("Debug mode enabled.\n");
        }
    } else {
        printf("No password specified - VLC HTTP interface must be accessible without authentication\n");
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
    // Get current timestamp
    time_t now = time(NULL);
    struct tm *tm_info = localtime(&now);
    char time_str[32];
    strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", tm_info);
    printf("[%s] Querying VLC at http://%s:%d\n", time_str, VLC_HTTP_HOST, VLC_HTTP_PORT);
    printf("[%s] Broadcasting to %s:%d\n", time_str, MULTICAST_GROUP, MULTICAST_PORT);

    vlc_status_t current_status = {0};
    vlc_status_t last_status = {0};

    // Main loop
    while (1) {
        // Query VLC status via HTTP
        http_response_t *response = http_get(VLC_HTTP_HOST, VLC_HTTP_PORT, "/requests/status.json", vlc_password);

        if (response && response->data) {
            // Parse the JSON response
            if (parse_vlc_status(response->data, &current_status)) {
                // Check if status has changed
                int status_changed = memcmp(&current_status, &last_status, sizeof(vlc_status_t)) != 0;

                if (status_changed || current_status.is_playing) {
                    // Create JSON message
                    char *json_message = create_status_json(&current_status);
                    if (json_message) {
                        if (debug_mode) {
                            printf("[DEBUG] Multicast JSON: %s\n", json_message);
                        }
                        // Send via multicast
                        if (send_multicast_data(multicast_sock, json_message)) {
                            // Get current timestamp for broadcast message
                            time_t now = time(NULL);
                            struct tm *tm_info = localtime(&now);
                            char time_str[32];
                            strftime(time_str, sizeof(time_str), "%H:%M:%S", tm_info);

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

                    // Update last status
                    memcpy(&last_status, &current_status, sizeof(vlc_status_t));
                }
            }
        } else {
            // VLC not responding
            if (current_status.is_playing != 0) {
                // Send stopped status
                current_status.is_playing = 0;
                current_status.timestamp = time(NULL);

                char *json_message = create_status_json(&current_status);
                if (json_message) {
                    send_multicast_data(multicast_sock, json_message);
                    free(json_message);
                }

                memcpy(&last_status, &current_status, sizeof(vlc_status_t));
                // Get current timestamp for broadcast message
                time_t now = time(NULL);
                struct tm *tm_info = localtime(&now);
                char time_str[32];
                strftime(time_str, sizeof(time_str), "%H:%M:%S", tm_info);

                printf("[%s] VLC not responding - sent stopped status\n", time_str);
                if (debug_mode) {
                    printf("[DEBUG] VLC not responding, sent stopped status\n");
                }
            }
        }

        // Clean up HTTP response
        if (response) {
            free_http_response(response);
        }

        // Wait before next update
        Sleep(UPDATE_INTERVAL_MS);
    }

    // Cleanup (this code is never reached in normal operation)
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

// HTTP GET request with optional authentication
http_response_t *http_get(const char *host, int port, const char *path, const char *password) {
    extern int debug_mode;
    SOCKET sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock == INVALID_SOCKET) {
        return NULL;
    }

    // Resolve host
    struct sockaddr_in server_addr = {0};
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(port);

    if (inet_pton(AF_INET, host, &server_addr.sin_addr) <= 0) {
        closesocket(sock);
        return NULL;
    }

    // Connect
    if (connect(sock, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        closesocket(sock);
        return NULL;
    }

    // Create HTTP request
    char auth_header[512] = "";
    if (password && strlen(password) > 0) {
        // Create basic authentication header
        char credentials[256];
        snprintf(credentials, sizeof(credentials), ":%s", password);

        // Base64 encode the credentials
        char *auth_encoded = base64_encode(credentials);
        if (auth_encoded) {
            snprintf(auth_header, sizeof(auth_header), "Authorization: Basic %s\r\n", auth_encoded);
            free(auth_encoded);
        } else {
            fprintf(stderr, "Failed to encode authentication credentials\n");
        }
    }

    // Send HTTP request
    char request[2048];
    snprintf(request, sizeof(request),
             "GET %s HTTP/1.1\r\n"
             "Host: %s:%d\r\n"
             "User-Agent: VLC-Status-Server/1.0\r\n"
             "Accept: application/json\r\n"
             "%s"
             "Connection: close\r\n"
             "\r\n",
             path, host, port, auth_header);

    if (send(sock, request, strlen(request), 0) < 0) {
        closesocket(sock);
        return NULL;
    }

    // Read response
    char buffer[BUFFER_SIZE];
    int total_received = 0;
    int content_length = -1;
    int headers_done = 0;

    http_response_t *response = calloc(1, sizeof(http_response_t));
    if (!response) {
        closesocket(sock);
        return NULL;
    }

    while (1) {
        int received = recv(sock, buffer, sizeof(buffer) - 1, 0);
        if (received <= 0) {
            break;
        }
        buffer[received] = '\0';

        // Print all received data if debug mode is enabled
        if (debug_mode) {
            printf("[DEBUG] HTTP received chunk (%d bytes):\n%s\n", received, buffer);
        }

        // Parse headers if not done yet
        if (!headers_done) {
            char *body_start = strstr(buffer, "\r\n\r\n");
            if (body_start) {
                *body_start = '\0';
                headers_done = 1;

                // Look for Content-Length header
                char *cl_header = strstr(buffer, "Content-Length:");
                if (cl_header) {
                    sscanf(cl_header + 15, "%d", &content_length);
                }

                // Skip to body
                body_start += 4;
                received -= (body_start - buffer);
                memmove(buffer, body_start, received + 1);
            } else {
                continue;  // Still reading headers
            }
        }

        // Append to response data
        response->data = realloc(response->data, total_received + received + 1);
        if (!response->data) {
            free_http_response(response);
            closesocket(sock);
            return NULL;
        }

        memcpy(response->data + total_received, buffer, received);
        total_received += received;
        response->data[total_received] = '\0';

        // Check if we have all the content
        if (content_length >= 0 && total_received >= content_length) {
            break;
        }
    }

    closesocket(sock);

    if (total_received == 0) {
        free_http_response(response);
        return NULL;
    }

    response->size = total_received;

    if (debug_mode && response && response->data) {
        printf("[DEBUG] Full HTTP response (%zu bytes):\n%s\n", response->size, response->data);
    }

    return response;
}

// Free HTTP response
void free_http_response(http_response_t *response) {
    if (response) {
        free(response->data);
        free(response);
    }
}

// Parse VLC status JSON
int parse_vlc_status(const char *json, vlc_status_t *status) {
    if (!json || !status) {
        return 0;
    }

    // Initialize status
    memset(status, 0, sizeof(vlc_status_t));
    status->timestamp = time(NULL);

    // Simple JSON parsing (basic implementation)
    char *json_copy = strdup(json);
    if (!json_copy) {
        return 0;
    }

    // Extract basic fields
    char *state = strstr(json_copy, "\"state\":\"");
    if (state) {
        state += 9;
        char *end = strchr(state, '"');
        if (end) {
            *end = '\0';
            status->is_playing = strcmp(state, "playing") == 0;
        }
    }

    // Extract position (0-1 scalar)
    char *position = strstr(json_copy, "\"position\":");
    if (position) {
        position += 11;
        // Skip whitespace after colon
        while (*position == ' ' || *position == '\t') position++;
        sscanf(position, "%lf", &status->position);
    }

    // Extract time (current time in seconds)
    char *time_field = strstr(json_copy, "\"time\":");
    if (time_field) {
        double time_seconds;
        if (sscanf(time_field + 7, "%lf", &time_seconds) == 1) {
            status->time = (long long)(time_seconds * 1000); // Convert to milliseconds
        }
    }

    // Extract duration (length in seconds)
    char *duration = strstr(json_copy, "\"length\":");
    if (duration) {
        double duration_seconds;
        if (sscanf(duration + 9, "%lf", &duration_seconds) == 1) {
            status->duration = (long long)(duration_seconds * 1000); // Convert to milliseconds
        }
    }

    // Calculate more precise duration if possible
    // If we have both time and position, we can get a more precise duration
    if (status->time > 0 && status->position > 0.0) {
        long long calculated_duration = (long long)(status->time / status->position);
        // Use the calculated duration if it's significantly different (more precise)
        if (llabs(calculated_duration - status->duration) > 100) { // More than 100ms difference
            status->duration = calculated_duration;
        }
    }

    // Extract state (playing, paused, stopped)
    char *state_str = strstr(json_copy, "\"state\":\"");
    if (state_str) {
        state_str += 9;
        char *end = strchr(state_str, '"');
        if (end) {
            *end = '\0';
            status->is_playing = strcmp(state_str, "playing") == 0;
        }
    }

    // Extract rate
    char *rate = strstr(json_copy, "\"rate\":");
    if (rate) {
        sscanf(rate + 7, "%lf", &status->rate);
    }

    // Extract filename from metadata
    char *filename_meta = strstr(json_copy, "\"filename\":\"");
    if (filename_meta) {
        filename_meta += 12;
        char *end = strchr(filename_meta, '"');
        if (end) {
            *end = '\0';
            strncpy(status->filename, filename_meta, sizeof(status->filename) - 1);
        }
    }

    // Extract title from information section (more reliable than top-level title)
    char *info_title = strstr(json_copy, "\"information\":{");
    if (info_title) {
        char *title_in_info = strstr(info_title, "\"title\":");
        if (title_in_info && title_in_info < strstr(info_title, "},\"")) {
            int title_num;
            if (sscanf(title_in_info + 8, "%d", &title_num) == 1) {
                // Title is a number, not a string - skip for now
            }
        }
    }

    // If we don't have a good title, try to extract from filename
    if (strlen(status->title) == 0 && strlen(status->filename) > 0) {
        // Simple filename to title conversion (remove extension)
        char *dot = strrchr(status->filename, '.');
        if (dot) {
            size_t title_len = dot - status->filename;
            if (title_len < sizeof(status->title)) {
                strncpy(status->title, status->filename, title_len);
                status->title[title_len] = '\0';
            }
        } else {
            strncpy(status->title, status->filename, sizeof(status->title) - 1);
            status->title[sizeof(status->title) - 1] = '\0';
        }
    }

    free(json_copy);
    return 1;
}

// Create JSON message for broadcasting
char *create_status_json(const vlc_status_t *status) {
    if (!status) {
        return NULL;
    }

    char *json = malloc(2048);
    if (!json) {
        return NULL;
    }

    // Create server timestamp
    time_t now = time(NULL);
    struct tm *tm_info = localtime(&now);
    char timestamp_str[32];
    strftime(timestamp_str, sizeof(timestamp_str), "%Y-%m-%d %H:%M:%S", tm_info);

    // Create JSON message
    snprintf(json, 2048,
             "{"
             "\"server_timestamp\": \"%s\","
             "\"server_id\": \"vlc-status-server\","
             "\"vlc_data\": {"
             "\"timestamp\": %lld,"
             "\"is_playing\": %s,"
             "\"position\": %.3f,"
             "\"time\": %lld,"
             "\"duration\": %lld,"
             "\"rate\": %.2f,"
             "\"title\": \"%s\","
             "\"artist\": \"%s\","
             "\"album\": \"%s\","
             "\"filename\": \"%s\","
             "\"uri\": \"%s\""
             "}"
             "}",
             timestamp_str,
             (long long)status->timestamp,
             status->is_playing ? "true" : "false",
             status->position,
             status->time,
             status->duration,
             status->rate,
             status->title,
             status->artist,
             status->album,
             status->filename,
             status->uri);

    return json;
}

// Print status for debugging
void print_status(const vlc_status_t *status) {
    printf("VLC Status:\n");
    printf("  Playing: %s\n", status->is_playing ? "Yes" : "No");
    printf("  Position: %.6f (%.2f%%)\n", status->position, status->position * 100.0);
    printf("  Time: %lld ms (%.2f sec)\n", status->time, status->time / 1000.0);
    printf("  Duration: %lld ms (%.2f sec)\n", status->duration, status->duration / 1000.0);
    printf("  Rate: %.2f\n", status->rate);
    printf("  Title: %s\n", status->title);
    printf("  Filename: %s\n", status->filename);
}

// Print usage information
void print_usage(const char *program_name) {
    printf("VLC Status Server - Broadcasts VLC playback status via UDP multicast\n\n");
    printf("Usage: %s [password] [--debug]\n\n", program_name);
    printf("Arguments:\n");
    printf("  password    VLC HTTP interface password (optional)\n");
    printf("  --debug     Enable verbose debug output\n");
    printf("  --help, -h  Show this help message\n\n");
    printf("Examples:\n");
    printf("  %s                    # No password (VLC HTTP interface must be accessible without auth)\n", program_name);
    printf("  %s mypassword         # Use password for VLC HTTP authentication\n", program_name);
    printf("  %s mypassword --debug # Use password and enable debug output\n", program_name);
    printf("  %s --help             # Show this help message\n\n", program_name);
    printf("VLC must be started with HTTP interface enabled:\n");
    printf("  vlc --http-host=127.0.0.1 --http-port=8080 --http-password=mypassword\n\n");
    printf("The server will query VLC at http://127.0.0.1:8080/requests/status.json\n");
    printf("and broadcast status updates to UDP multicast group 239.255.0.100:8888\n");
}

// Base64 encoding function
char *base64_encode(const char *input) {
    static const char base64_chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t input_len = strlen(input);
    size_t output_len = 4 * ((input_len + 2) / 3);
    char *output = malloc(output_len + 1);
    if (!output) return NULL;

    size_t i, j;
    for (i = 0, j = 0; i < input_len; ) {
        uint32_t octet_a = i < input_len ? (unsigned char)input[i++] : 0;
        uint32_t octet_b = i < input_len ? (unsigned char)input[i++] : 0;
        uint32_t octet_c = i < input_len ? (unsigned char)input[i++] : 0;

        uint32_t triple = (octet_a << 0x10) + (octet_b << 0x08) + octet_c;

        output[j++] = base64_chars[(triple >> 3 * 6) & 0x3F];
        output[j++] = base64_chars[(triple >> 2 * 6) & 0x3F];
        output[j++] = base64_chars[(triple >> 1 * 6) & 0x3F];
        output[j++] = base64_chars[(triple >> 0 * 6) & 0x3F];
    }

    // Add padding
    size_t padding = input_len % 3;
    if (padding > 0) {
        output[output_len - 1] = '=';
        if (padding == 1) {
            output[output_len - 2] = '=';
        }
    }

    output[output_len] = '\0';
    return output;
}
