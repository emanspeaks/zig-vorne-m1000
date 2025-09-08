// Include VLC headers for static linking
#include <vlc/vlc.h>
#include <vlc/libvlc.h>
#include <vlc/libvlc_media.h>
#include <vlc/libvlc_media_player.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <winsock2.h>
#include <windows.h>
#include <commdlg.h>
#include <time.h>
#include <ws2tcpip.h>
#include <stdint.h>
#include <shellapi.h>
#include <commctrl.h>

#define MULTICAST_GROUP "239.255.0.100"
#define MULTICAST_PORT 8888
#define HTTP_PORT 8080
#define UPDATE_INTERVAL_MS 200  // 5Hz (every 200ms)

// VLC status structure
typedef struct {
    int is_playing;      // 1=playing, 0=paused/stopped
    int is_paused;       // 1=paused, 0=playing/stopped
    int is_stopped;      // 1=stopped, 0=playing/paused
    long long time;
    long long duration;
    char title[256];
    char filename[256];
} vlc_status_t;

// VLC instance structure
typedef struct {
    libvlc_instance_t *vlc_instance;
    libvlc_media_player_t *media_player;
    libvlc_media_t *current_media;
    int initialized;
} vlc_player_t;

// Global variables
int debug_mode = 0;
vlc_player_t *g_vlc_player = NULL;  // Global player instance for window callbacks
HWND g_status_bar = NULL;          // Global status bar handle

// Function declarations
long long getUnixTimeMs();
int initialize_winsock();
void cleanup_winsock();
SOCKET create_multicast_socket();
int send_multicast_data(SOCKET sock, const char *data);
vlc_player_t *vlc_player_create();
void vlc_player_destroy(vlc_player_t *player);
int vlc_player_open_file(vlc_player_t *player, const char *filepath);
int vlc_player_play(vlc_player_t *player);
int vlc_player_pause(vlc_player_t *player);
int vlc_player_stop(vlc_player_t *player);
int vlc_player_toggle_play_pause(vlc_player_t *player);
int query_vlc_status(vlc_player_t *player, vlc_status_t *status);
char *create_status_json_with_timestamp(const vlc_status_t *status, long long server_timestamp_ms);
void print_status(const vlc_status_t *status);
void print_usage(const char *program_name);
HWND create_player_window();
LRESULT CALLBACK WindowProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam);
void open_file_dialog(HWND parent_window);
void update_status_bar(const vlc_status_t *status);
void format_time_with_ms(long long time_ms, char *buffer, size_t buffer_size);
SOCKET create_http_server_socket();
int handle_http_request(SOCKET client_sock, vlc_player_t *player);

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

// Open file dialog
void open_file_dialog(HWND parent_window) {
    OPENFILENAME ofn;
    char szFile[MAX_PATH] = "";

    ZeroMemory(&ofn, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = parent_window;
    ofn.lpstrFile = szFile;
    ofn.nMaxFile = sizeof(szFile);
    ofn.lpstrFilter = "All Files\0*.*\0Video Files\0*.mp4;*.avi;*.mkv;*.mov;*.wmv;*.flv;*.webm;*.m4v\0Audio Files\0*.mp3;*.wav;*.flac;*.aac;*.ogg;*.m4a\0";
    ofn.nFilterIndex = 2;  // Default to video files
    ofn.lpstrFileTitle = NULL;
    ofn.nMaxFileTitle = 0;
    ofn.lpstrInitialDir = NULL;
    ofn.Flags = OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST;

    if (GetOpenFileName(&ofn) == TRUE) {
        if (g_vlc_player) {
            if (vlc_player_open_file(g_vlc_player, szFile)) {
                printf("Opened file: %s\n", szFile);
                vlc_player_play(g_vlc_player);
            } else {
                printf("Failed to open file: %s\n", szFile);
            }
        }
    }
}

// Create player window
HWND create_player_window() {
    WNDCLASS wc = {0};
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = GetModuleHandle(NULL);
    wc.lpszClassName = "VLCPlayerWindow";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    wc.style = CS_HREDRAW | CS_VREDRAW;

    if (!RegisterClass(&wc)) {
        printf("Error: Failed to register window class\n");
        return NULL;
    }

    // Create window
    HWND hwnd = CreateWindowEx(
        0,
        "VLCPlayerWindow",
        "VLC Status Server Player",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT, CW_USEDEFAULT,
        800, 600,
        NULL, NULL, GetModuleHandle(NULL), NULL
    );

    if (!hwnd) {
        printf("Error: Failed to create window\n");
        return NULL;
    }

    // Enable drag and drop
    DragAcceptFiles(hwnd, TRUE);

    return hwnd;
}

// Window procedure for VLC player window
LRESULT CALLBACK WindowProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
        case WM_CREATE:
            // Initialize common controls
            InitCommonControls();

            // Create status bar
            g_status_bar = CreateWindowEx(
                0,
                STATUSCLASSNAME,
                NULL,
                WS_CHILD | WS_VISIBLE | SBARS_SIZEGRIP,
                0, 0, 0, 0,
                hwnd,
                (HMENU)1001,
                GetModuleHandle(NULL),
                NULL
            );

            if (g_status_bar) {
                // Set initial status bar text
                SendMessage(g_status_bar, SB_SETTEXT, 0, (LPARAM)"Ready - Right-click to open file, Space to play/pause");
            }
            return 0;

        case WM_CLOSE:
            // Stop VLC playback and clear the window handle before destroying
            if (g_vlc_player && g_vlc_player->media_player) {
                // Stop playback first
                libvlc_media_player_stop(g_vlc_player->media_player);

                // Clear the window handle to prevent VLC from trying to render
                libvlc_media_player_set_hwnd(g_vlc_player->media_player, NULL);

                // Give VLC a moment to cleanup
                Sleep(100);
            }

            // Now destroy the window
            DestroyWindow(hwnd);
            return 0;

        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;

        case WM_KEYDOWN:
            switch (wParam) {
                case VK_SPACE:
                    // Space bar to play/pause
                    if (g_vlc_player) {
                        vlc_player_toggle_play_pause(g_vlc_player);
                    }
                    return 0;

                case VK_ESCAPE:
                    // Escape to stop
                    if (g_vlc_player && g_vlc_player->media_player) {
                        vlc_player_stop(g_vlc_player);
                    }
                    return 0;

                case VK_LEFT:
                    // Left arrow to seek backward (10 seconds)
                    if (g_vlc_player && g_vlc_player->media_player) {
                        int64_t current_time = libvlc_media_player_get_time(g_vlc_player->media_player);
                        int64_t new_time = (current_time > 10000) ? current_time - 10000 : 0;
                        libvlc_media_player_set_time(g_vlc_player->media_player, new_time);
                        // Give VLC a moment to process the seek
                        Sleep(50);
                    }
                    return 0;

                case VK_RIGHT:
                    // Right arrow to seek forward (10 seconds)
                    if (g_vlc_player && g_vlc_player->media_player) {
                        int64_t current_time = libvlc_media_player_get_time(g_vlc_player->media_player);
                        libvlc_media_player_set_time(g_vlc_player->media_player, current_time + 10000);
                        // Give VLC a moment to process the seek
                        Sleep(50);
                    }
                    return 0;
            }
            break;

        case WM_RBUTTONDOWN:
            // Right-click to open file dialog
            open_file_dialog(hwnd);
            return 0;

        case WM_DROPFILES: {
            // Handle drag and drop of files
            HDROP hDrop = (HDROP)wParam;
            UINT fileCount = DragQueryFile(hDrop, 0xFFFFFFFF, NULL, 0);
            if (fileCount > 0) {
                char filePath[MAX_PATH];
                if (DragQueryFile(hDrop, 0, filePath, MAX_PATH)) {
                    if (g_vlc_player) {
                        if (vlc_player_open_file(g_vlc_player, filePath)) {
                            printf("Opened dropped file: %s\n", filePath);
                            vlc_player_play(g_vlc_player);
                        } else {
                            printf("Failed to open dropped file: %s\n", filePath);
                        }
                    }
                }
            }
            DragFinish(hDrop);
            return 0;
        }

        case WM_SIZE:
            // Resize status bar
            if (g_status_bar) {
                SendMessage(g_status_bar, WM_SIZE, 0, 0);
            }
            // Handle window resize - VLC will automatically adjust video size
            return 0;
    }

    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

// Format time in HH:MM:SS.mmm format
void format_time_with_ms(long long time_ms, char *buffer, size_t buffer_size) {
    if (time_ms < 0) {
        snprintf(buffer, buffer_size, "--:--:--.---");
        return;
    }

    long long total_ms = time_ms;
    int ms = total_ms % 1000;
    total_ms /= 1000;

    int seconds = total_ms % 60;
    total_ms /= 60;

    int minutes = total_ms % 60;
    int hours = total_ms / 60;

    if (hours > 0) {
        snprintf(buffer, buffer_size, "%d:%02d:%02d.%03d", hours, minutes, seconds, ms);
    } else {
        snprintf(buffer, buffer_size, "%d:%02d.%03d", minutes, seconds, ms);
    }
}

// Update status bar with current playback information
void update_status_bar(const vlc_status_t *status) {
    if (!g_status_bar) return;

    char current_time_str[32];
    char duration_str[32];
    char status_text[512];  // Increased buffer size to avoid truncation warnings

    // Format current time and duration
    format_time_with_ms(status->time, current_time_str, sizeof(current_time_str));
    format_time_with_ms(status->duration, duration_str, sizeof(duration_str));

    // Determine status text based on detailed state
    const char *state_text;
    if (status->is_playing) {
        state_text = "Playing";
    } else if (status->is_paused) {
        state_text = "Paused";
    } else if (status->is_stopped) {
        state_text = "Stopped";
    } else {
        state_text = "Unknown";
    }

    // Create status bar text
    if (status->duration > 0) {
        // Calculate percentage
        double percentage = (double)status->time / status->duration * 100.0;
        snprintf(status_text, sizeof(status_text),
                "%s | %s / %s (%.1f%%) | %.100s",  // Limit title to 100 chars
                state_text,
                current_time_str,
                duration_str,
                percentage,
                status->title[0] ? status->title : "No media");
    } else {
        snprintf(status_text, sizeof(status_text),
                "%s | %s | %.100s",  // Limit title to 100 chars
                state_text,
                current_time_str,
                status->title[0] ? status->title : "No media");
    }

    // Update status bar
    SendMessage(g_status_bar, SB_SETTEXT, 0, (LPARAM)status_text);
}

// Main server loop
int main(int argc, char *argv[]) {
    char *initial_file = NULL;

    // Check for VLC_NO_STATUS_LOG environment variable
    int suppress_status_log = 0;
    char *no_status_log_env = getenv("VLC_NO_STATUS_LOG");
    if (no_status_log_env && strcmp(no_status_log_env, "1") == 0) {
        suppress_status_log = 1;
    }

    // Parse command line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        }
        if (strcmp(argv[i], "--debug") == 0) {
            debug_mode = 1;
            printf("Debug mode enabled.\n");
        } else if (strcmp(argv[i], "--file") == 0 || strcmp(argv[i], "-f") == 0) {
            if (i + 1 < argc) {
                initial_file = argv[i + 1];
                i++; // Skip next argument
            }
        } else {
            // Assume it's a file path
            initial_file = argv[i];
        }
    }

    printf("VLC Status Server with custom window starting...\n");

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

    // Create HTTP server socket
    SOCKET http_server_sock = create_http_server_socket();
    if (http_server_sock == INVALID_SOCKET) {
        fprintf(stderr, "Failed to create HTTP server socket\n");
        closesocket(multicast_sock);
        cleanup_winsock();
        return 1;
    }

    // Create VLC player instance
    g_vlc_player = vlc_player_create();
    if (!g_vlc_player) {
        fprintf(stderr, "Failed to create VLC player instance\n");
        closesocket(multicast_sock);
        cleanup_winsock();
        return 1;
    }

    // Create player window
    HWND player_window = create_player_window();
    if (!player_window) {
        fprintf(stderr, "Failed to create player window\n");
        vlc_player_destroy(g_vlc_player);
        closesocket(multicast_sock);
        cleanup_winsock();
        return 1;
    }

    // Set window handle for VLC video output
    if (g_vlc_player->media_player) {
        libvlc_media_player_set_hwnd(g_vlc_player->media_player, player_window);
        printf("Set custom window for VLC video output\n");
    }

    // Load initial file if provided
    if (initial_file) {
        if (vlc_player_open_file(g_vlc_player, initial_file)) {
            printf("Loaded initial file: %s\n", initial_file);
            // Don't auto-play, let user control playback
        } else {
            printf("Failed to load initial file: %s\n", initial_file);
        }
    }

    printf("Server started successfully\n");

    // Display connection info
    SYSTEMTIME st;
    GetSystemTime(&st);
    char time_str[64];
    snprintf(time_str, sizeof(time_str), "%04d-%02d-%02d %02d:%02d:%02d.%03d",
           st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    printf("VLC player created with custom window\n");
    printf("[%s] Broadcasting status to %s:%d\n", time_str, MULTICAST_GROUP, MULTICAST_PORT);
    printf("[%s] HTTP server listening on port %d\n", time_str, HTTP_PORT);
    printf("[%s] Controls: Space=Play/Pause, Left/Right=Seek, Right-click=Open File, Drag&Drop=Load File\n", time_str);

    vlc_status_t current_status = {0};
    vlc_status_t last_status = {0};

    // Main message loop with multicast broadcasting and HTTP server
    MSG msg;
    DWORD last_update = GetTickCount();
    fd_set read_fds;
    struct timeval timeout;

    while (1) {
        // Process Windows messages (non-blocking)
        while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) {
                goto cleanup;
            }
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }

        // Check for HTTP connections
        FD_ZERO(&read_fds);
        FD_SET(http_server_sock, &read_fds);
        timeout.tv_sec = 0;
        timeout.tv_usec = 10000; // 10ms timeout

        if (select(0, &read_fds, NULL, NULL, &timeout) > 0) {
            if (FD_ISSET(http_server_sock, &read_fds)) {
                // Accept HTTP connection
                struct sockaddr_in client_addr;
                int client_addr_len = sizeof(client_addr);
                SOCKET client_sock = accept(http_server_sock, (struct sockaddr*)&client_addr, &client_addr_len);

                if (client_sock != INVALID_SOCKET) {
                    // Handle the HTTP request
                    handle_http_request(client_sock, g_vlc_player);
                    closesocket(client_sock);
                }
            }
        }

        DWORD current_time = GetTickCount();
        if (current_time - last_update >= UPDATE_INTERVAL_MS) {

            if (debug_mode) {
                static DWORD last_query_time = 0;
                if (last_query_time > 0) {
                    printf("[DEBUG] Query interval: %lu ms\n", current_time - last_query_time);
                }
                last_query_time = current_time;
            }

            // Get server timestamp at poll time (UTC milliseconds)
            long long server_timestamp_ms = getUnixTimeMs();

            // Query VLC status directly from libvlc
            if (debug_mode) {
                printf("[DEBUG] About to query VLC status...\n");
            }

            int status_ok = query_vlc_status(g_vlc_player, &current_status);

            if (debug_mode) {
                printf("[DEBUG] Query VLC status completed, status_ok: %d\n", status_ok);
            }

            if (status_ok) {
                // Update status bar with current playback info
                update_status_bar(&current_status);

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

                        if (!suppress_status_log) {
                            // Determine status text for broadcast
                            const char *status_text;
                            if (current_status.is_playing) {
                                status_text = "Playing";
                            } else if (current_status.is_paused) {
                                status_text = "Paused";
                            } else if (current_status.is_stopped) {
                                status_text = "Stopped";
                            } else {
                                status_text = "Unknown";
                            }

                            printf("[%s] Status broadcast: %s - %s\n",
                                   time_str,
                                   status_text,
                                   current_status.title[0] ? current_status.title : "No media");
                            if (debug_mode) {
                                print_status(&current_status);
                            }
                        }
                    }
                    free(json_message);
                }
            } else {
                // VLC error - send stopped status
                current_status.is_playing = 0;
                current_status.is_paused = 0;
                current_status.is_stopped = 1;
                current_status.time = 0;
                current_status.duration = 0;
                strcpy(current_status.title, "No media");
                strcpy(current_status.filename, "");

                // Update status bar to show error state
                update_status_bar(&current_status);

                char *json_message = create_status_json_with_timestamp(&current_status, server_timestamp_ms);
                if (json_message) {
                    send_multicast_data(multicast_sock, json_message);
                    free(json_message);
                }

                memcpy(&last_status, &current_status, sizeof(vlc_status_t));
            }

            last_update = current_time;
        }

        // Small sleep to prevent busy waiting
        Sleep(10);
    }

cleanup:
    // Cleanup
    vlc_player_destroy(g_vlc_player);
    g_vlc_player = NULL;
    closesocket(multicast_sock);
    closesocket(http_server_sock);
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

// Create HTTP server socket
SOCKET create_http_server_socket() {
    SOCKET server_sock = socket(AF_INET, SOCK_STREAM, 0);
    if (server_sock == INVALID_SOCKET) {
        fprintf(stderr, "Failed to create HTTP server socket\n");
        return INVALID_SOCKET;
    }

    // Set socket options
    int reuse = 1;
    if (setsockopt(server_sock, SOL_SOCKET, SO_REUSEADDR, (char*)&reuse, sizeof(reuse)) < 0) {
        fprintf(stderr, "Failed to set socket options\n");
        closesocket(server_sock);
        return INVALID_SOCKET;
    }

    // Bind to port 8080
    struct sockaddr_in server_addr = {0};
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(HTTP_PORT);

    if (bind(server_sock, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        fprintf(stderr, "Failed to bind HTTP server socket to port %d\n", HTTP_PORT);
        closesocket(server_sock);
        return INVALID_SOCKET;
    }

    // Listen for connections
    if (listen(server_sock, 5) < 0) {
        fprintf(stderr, "Failed to listen on HTTP server socket\n");
        closesocket(server_sock);
        return INVALID_SOCKET;
    }

    printf("HTTP server listening on port %d\n", HTTP_PORT);
    return server_sock;
}

// Handle HTTP request
int handle_http_request(SOCKET client_sock, vlc_player_t *player) {
    char buffer[4096];
    int bytes_received = recv(client_sock, buffer, sizeof(buffer) - 1, 0);

    if (bytes_received <= 0) {
        return 0;
    }

    buffer[bytes_received] = '\0';

    // Parse the request - look for GET /open?file=filepath
    if (strstr(buffer, "GET /open?file=") == buffer) {
        // Extract the file path from the query string
        char *file_param = strstr(buffer, "file=");
        if (file_param) {
            file_param += 5; // Skip "file="

            // Find the end of the file parameter (space or &)
            char *end = strstr(file_param, " ");
            if (!end) end = strstr(file_param, "&");
            if (!end) end = file_param + strlen(file_param);

            // Copy the file path
            char filepath[1024];
            size_t len = (size_t)(end - file_param);
            if (len >= sizeof(filepath)) len = sizeof(filepath) - 1;
            memcpy(filepath, file_param, len);
            filepath[len] = '\0';

            // URL decode the filepath (basic implementation)
            char *decoded = filepath;
            char *src = filepath;
            while (*src) {
                if (*src == '%') {
                    if (src[1] && src[2]) {
                        char hex[3] = {src[1], src[2], '\0'};
                        *decoded++ = (char)strtol(hex, NULL, 16);
                        src += 3;
                    } else {
                        *decoded++ = *src++;
                    }
                } else if (*src == '+') {
                    *decoded++ = ' ';
                    src++;
                } else {
                    *decoded++ = *src++;
                }
            }
            *decoded = '\0';

            printf("HTTP request to open file: %s\n", filepath);

            // Try to open the file
            if (vlc_player_open_file(player, filepath)) {
                // Send success response
                const char *response =
                    "HTTP/1.1 200 OK\r\n"
                    "Content-Type: text/plain\r\n"
                    "Content-Length: 13\r\n"
                    "\r\n"
                    "File opened\r\n";
                send(client_sock, response, strlen(response), 0);
                printf("Successfully opened file via HTTP: %s\n", filepath);
                return 1;
            } else {
                // Send error response
                const char *response =
                    "HTTP/1.1 400 Bad Request\r\n"
                    "Content-Type: text/plain\r\n"
                    "Content-Length: 19\r\n"
                    "\r\n"
                    "Failed to open file\r\n";
                send(client_sock, response, strlen(response), 0);
                printf("Failed to open file via HTTP: %s\n", filepath);
                return 0;
            }
        }
    }

    // Send 404 for unrecognized requests
    const char *response =
        "HTTP/1.1 404 Not Found\r\n"
        "Content-Type: text/plain\r\n"
        "Content-Length: 13\r\n"
        "\r\n"
        "Not Found\r\n";
    send(client_sock, response, strlen(response), 0);
    return 0;
}

// Create VLC player with dummy interface (no UI, embedded in our window)
vlc_player_t *vlc_player_create() {
    vlc_player_t *player = malloc(sizeof(vlc_player_t));
    if (!player) {
        return NULL;
    }

    memset(player, 0, sizeof(vlc_player_t));

    // Initialize VLC instance with minimal arguments
    const char *vlc_args[] = {
        "--no-video-title-show",    // Don't show video title overlay
        // "--no-stats",               // Disable statistics
        // "--no-snapshot-preview",    // Disable snapshot preview
        "--no-video-on-top",        // Don't keep video on top
        // "--no-disable-screensaver", // Don't disable screensaver
        "--avcodec-threads=1",      // Use single thread for decoding to reduce cleanup issues
        // "--quiet",                  // Reduce VLC log verbosity
    };

    player->vlc_instance = libvlc_new(sizeof(vlc_args) / sizeof(vlc_args[0]), vlc_args);
    if (!player->vlc_instance) {
        printf("Error: Failed to create VLC instance: %s\n", libvlc_errmsg());
        free(player);
        return NULL;
    }

    // Create media player
    player->media_player = libvlc_media_player_new(player->vlc_instance);
    if (!player->media_player) {
        printf("Error: Failed to create media player: %s\n", libvlc_errmsg());
        libvlc_release(player->vlc_instance);
        free(player);
        return NULL;
    }

    player->initialized = 1;

    if (debug_mode) {
        printf("[DEBUG] VLC player created successfully with static linking\n");
    }

    return player;
}

// Destroy VLC player
void vlc_player_destroy(vlc_player_t *player) {
    if (!player) return;

    // Stop playback first
    if (player->media_player) {
        libvlc_media_player_stop(player->media_player);

        // Clear window handle to prevent rendering errors
        libvlc_media_player_set_hwnd(player->media_player, NULL);

        // Give VLC time to stop rendering threads
        Sleep(150);
    }

    // Release media
    if (player->current_media) {
        libvlc_media_release(player->current_media);
        player->current_media = NULL;
    }

    // Release media player
    if (player->media_player) {
        libvlc_media_player_release(player->media_player);
        player->media_player = NULL;
    }

    // Release VLC instance
    if (player->vlc_instance) {
        libvlc_release(player->vlc_instance);
        player->vlc_instance = NULL;
    }

    free(player);
}

// Open file in VLC player
int vlc_player_open_file(vlc_player_t *player, const char *filepath) {
    if (!player || !filepath) {
        return 0;
    }

    // Release previous media
    if (player->current_media) {
        libvlc_media_release(player->current_media);
        player->current_media = NULL;
    }

    // Create new media from file path
    player->current_media = libvlc_media_new_path(player->vlc_instance, filepath);
    if (!player->current_media) {
        printf("Error: Failed to create media from path: %s\n", libvlc_errmsg());
        return 0;
    }

    // Set media to player
    libvlc_media_player_set_media(player->media_player, player->current_media);

    if (debug_mode) {
        printf("[DEBUG] Opened file: %s\n", filepath);
    }

    return 1;
}

// Play media
int vlc_player_play(vlc_player_t *player) {
    if (!player || !player->media_player) {
        if (debug_mode) {
            printf("[DEBUG] Play failed: invalid player or media_player\n");
        }
        return 0;
    }

    // Check if we have media loaded
    if (!player->current_media) {
        if (debug_mode) {
            printf("[DEBUG] Play failed: no media loaded\n");
        }
        return 0;
    }

    if (debug_mode) {
        printf("[DEBUG] About to call libvlc_media_player_play...\n");
    }

    int result = libvlc_media_player_play(player->media_player);

    if (debug_mode) {
        printf("[DEBUG] Play command sent, result: %d\n", result);
        if (result != 0) {
            const char *error = libvlc_errmsg();
            if (error) {
                printf("[DEBUG] VLC error: %s\n", error);
            }
        }
        printf("[DEBUG] Play function completed successfully\n");
    }

    // Give VLC a moment to start playing
    Sleep(30);

    return result == 0; // libvlc_media_player_play returns 0 on success
}

// Pause media
int vlc_player_pause(vlc_player_t *player) {
    if (!player || !player->media_player) {
        return 0;
    }

    libvlc_media_player_pause(player->media_player);

    if (debug_mode) {
        printf("[DEBUG] Pause command sent\n");
    }

    return 1;
}

// Stop media
int vlc_player_stop(vlc_player_t *player) {
    if (!player || !player->media_player) {
        return 0;
    }

    // Stop the media player and wait a bit for cleanup
    libvlc_media_player_stop(player->media_player);

    // Give VLC time to stop decoding threads properly
    Sleep(50);

    if (debug_mode) {
        printf("[DEBUG] Stop command sent and cleanup delay completed\n");
    }

    return 1;
}

// Toggle play/pause
int vlc_player_toggle_play_pause(vlc_player_t *player) {
    if (!player || !player->media_player) {
        return 0;
    }

    // Check if we have media loaded
    if (!player->current_media) {
        if (debug_mode) {
            printf("[DEBUG] No media loaded, cannot play/pause\n");
        }
        return 0;
    }

    int is_playing = libvlc_media_player_is_playing(player->media_player);

    if (debug_mode) {
        printf("[DEBUG] Toggle: current playing state = %d\n", is_playing);
    }

    if (is_playing) {
        // Currently playing, so pause
        libvlc_media_player_pause(player->media_player);
        if (debug_mode) {
            printf("[DEBUG] Sent pause command\n");
        }
    } else {
        // Currently paused/stopped, so play
        int result = libvlc_media_player_play(player->media_player);
        if (debug_mode) {
            printf("[DEBUG] Sent play command, result = %d\n", result);
        }
        if (result != 0) {
            const char *error = libvlc_errmsg();
            if (error && debug_mode) {
                printf("[DEBUG] VLC play error: %s\n", error);
            }
            return 0;
        }
    }

    // Give VLC a moment to process the command
    Sleep(20);

    return 1;
}

// Query VLC status using libvlc API
int query_vlc_status(vlc_player_t *player, vlc_status_t *status) {
    if (!player || !status) {
        return 0;
    }

    // Initialize status
    memset(status, 0, sizeof(vlc_status_t));

    // Get basic playing status from VLC
    int vlc_is_playing = libvlc_media_player_is_playing(player->media_player);
    status->is_playing = vlc_is_playing;

    // Get current time and duration
    status->time = libvlc_media_player_get_time(player->media_player);
    status->duration = libvlc_media_player_get_length(player->media_player);

    // Determine detailed playback state
    if (vlc_is_playing) {
        // VLC says it's playing
        status->is_paused = 0;
        status->is_stopped = 0;
    } else {
        // VLC says it's not playing - could be paused or stopped
        if (player->current_media && status->time > 0) {
            // We have media loaded and a valid time position - this is PAUSED
            status->is_paused = 1;
            status->is_stopped = 0;
        } else {
            // No media or time is 0 - this is STOPPED
            status->is_paused = 0;
            status->is_stopped = 1;
        }
    }

    if (debug_mode) {
        printf("[DEBUG] VLC raw state: playing=%d, time=%lld, duration=%lld, media=%p\n",
               vlc_is_playing, status->time, status->duration, (void *)player->current_media);
        printf("[DEBUG] Interpreted state: playing=%d, paused=%d, stopped=%d\n",
               status->is_playing, status->is_paused, status->is_stopped);
    }

    // Get media info (title/filename)
    if (player->current_media) {
        char *meta_title = libvlc_media_get_meta(player->current_media, libvlc_meta_Title);
        char *meta_filename = libvlc_media_get_meta(player->current_media, libvlc_meta_URL);

        if (meta_title && strlen(meta_title) > 0) {
            strncpy(status->title, meta_title, sizeof(status->title) - 1);
        } else if (meta_filename && strlen(meta_filename) > 0) {
            // Extract just the filename from the path
            const char *filename_only = strrchr(meta_filename, '\\');
            if (!filename_only) filename_only = strrchr(meta_filename, '/');
            if (filename_only) {
                filename_only++; // Skip the slash
            } else {
                filename_only = meta_filename;
            }
            strncpy(status->title, filename_only, sizeof(status->title) - 1);
        } else {
            strcpy(status->title, "Unknown");
        }

        if (meta_filename) {
            strncpy(status->filename, meta_filename, sizeof(status->filename) - 1);
        }

        if (meta_title) free(meta_title);
        if (meta_filename) free(meta_filename);
    } else {
        strcpy(status->title, "No media");
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

    // Determine status string for JSON
    const char *status_str;
    if (status->is_playing) {
        status_str = "playing";
    } else if (status->is_paused) {
        status_str = "paused";
    } else if (status->is_stopped) {
        status_str = "stopped";
    } else {
        status_str = "unknown";
    }

    // Create JSON message
    snprintf(json, 2048,
             "{"
             "\"server_timestamp\": %lld,"
             "\"server_id\": \"vlc-status-server\","
             "\"vlc_data\": {"
             "\"state\": \"%s\","
             "\"is_playing\": %s,"
             "\"is_paused\": %s,"
             "\"is_stopped\": %s,"
             "\"time\": %lld,"
             "\"duration\": %lld,"
             "\"title\": \"%s\","
             "\"filename\": \"%s\""
             "}"
             "}",
             server_timestamp_ms,
             status_str,
             status->is_playing ? "true" : "false",
             status->is_paused ? "true" : "false",
             status->is_stopped ? "true" : "false",
             status->time,
             status->duration,
             status->title,
             status->filename);

    return json;
}

// Print status for debugging
void print_status(const vlc_status_t *status) {
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

    // Determine media status
    int has_media = (strcmp(status->title, "No media") != 0 && strlen(status->title) > 0);
    const char *media_status = has_media ? "Loaded" : "None";

    printf("  State: %s (playing=%d, paused=%d, stopped=%d)\n",
           state_str, status->is_playing, status->is_paused, status->is_stopped);
    printf("  Media: %s\n", media_status);
    printf("  Time: %lld ms (%.2f sec)\n", status->time, status->time / 1000.0);
    printf("  Duration: %lld ms (%.2f sec)\n", status->duration, status->duration / 1000.0);
    printf("  Title: %s\n", status->title);
    printf("  Filename: %s\n", status->filename);

    // Show progress percentage if media has duration
    if (status->duration > 0) {
        double percentage = (double)status->time / status->duration * 100.0;
        printf("  Progress: %.1f%%\n", percentage);
    }
}

// Print usage information
void print_usage(const char *program_name) {
    printf("VLC Status Server with Custom Window - Creates embedded VLC player and broadcasts status\n\n");
    printf("Usage: %s [OPTIONS] [FILE]\n\n", program_name);
    printf("Arguments:\n");
    printf("  FILE              Initial media file to load (optional)\n");
    printf("  --file FILE, -f   Specify initial media file to load\n");
    printf("  --debug           Enable verbose debug output\n");
    printf("  --help, -h        Show this help message\n\n");
    printf("Features:\n");
    printf("  - Custom window with embedded VLC video/audio playback\n");
    printf("  - Keyboard controls: Space=Play/Pause, Left/Right=Seek ±10s, Escape=Stop\n");
    printf("  - Right-click to open file dialog\n");
    printf("  - Drag and drop files to play\n");
    printf("  - Broadcasts playback status to UDP multicast group 239.255.0.100:8888\n");
    printf("  - HTTP server on port 8080 for remote file opening (GET /open?file=filepath)\n");
    printf("  - Static linking to libVLC (no dynamic loading)\n\n");
    printf("Examples:\n");
    printf("  %s                           # Start with blank window\n", program_name);
    printf("  %s video.mp4                 # Start with video.mp4 loaded\n", program_name);
    printf("  %s --file audio.mp3          # Start with audio.mp3 loaded\n", program_name);
    printf("  %s --debug                   # Enable debug output\n", program_name);
}
