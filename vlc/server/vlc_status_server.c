// Include VLC headers for type safety
#include <vlc/vlc.h>
#include <vlc/libvlc.h>
#include <vlc/libvlc_media.h>
#include <vlc/libvlc_media_player.h>
#include <math.h>
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


// Dynamic loading for VLC
typedef void* (*libvlc_new_t)(int, const char **);
typedef void (*libvlc_release_t)(void*);
typedef void* (*libvlc_media_player_new_t)(void*);
typedef void (*libvlc_media_player_release_t)(void*);
typedef int (*libvlc_media_player_play_t)(void*);
typedef void (*libvlc_media_player_pause_t)(void*);
typedef void (*libvlc_media_player_stop_t)(void*);
typedef int (*libvlc_media_player_is_playing_t)(void*);
typedef int64_t (*libvlc_media_player_get_time_t)(void*);
typedef void (*libvlc_media_player_set_time_t)(void*, int64_t);
typedef int64_t (*libvlc_media_player_get_length_t)(void*);
typedef void (*libvlc_media_player_set_hwnd_t)(void*, void*);
typedef void (*libvlc_media_release_t)(void*);
typedef void (*libvlc_media_player_set_media_t)(void*, void*);
typedef char* (*libvlc_media_get_meta_t)(void*, int);
typedef const char* (*libvlc_errmsg_t)(void);

// Function pointers
libvlc_new_t p_libvlc_new = NULL;
libvlc_release_t p_libvlc_release = NULL;
libvlc_media_player_new_t p_libvlc_media_player_new = NULL;
libvlc_media_player_release_t p_libvlc_media_player_release = NULL;
libvlc_media_player_play_t p_libvlc_media_player_play = NULL;
libvlc_media_player_pause_t p_libvlc_media_player_pause = NULL;
libvlc_media_player_stop_t p_libvlc_media_player_stop = NULL;
libvlc_media_player_is_playing_t p_libvlc_media_player_is_playing = NULL;
libvlc_media_player_get_time_t p_libvlc_media_player_get_time = NULL;
libvlc_media_player_set_time_t p_libvlc_media_player_set_time = NULL;
libvlc_media_player_get_length_t p_libvlc_media_player_get_length = NULL;
libvlc_media_new_path_t p_libvlc_media_new_path = NULL;
libvlc_media_release_t p_libvlc_media_release = NULL;
libvlc_media_player_set_media_t p_libvlc_media_player_set_media = NULL;
libvlc_media_get_meta_t p_libvlc_media_get_meta = NULL;
libvlc_errmsg_t p_libvlc_errmsg = NULL;

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

// VLC instance structure
typedef struct {
    libvlc_instance_t *vlc_instance;
    libvlc_media_player_t *media_player;
    libvlc_media_t *current_media;
    int initialized;
} vlc_player_t;

int debug_mode = 0;

// Function declarations
int check_vlc_and_qt_libraries();
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
int query_vlc_status(vlc_player_t *player, vlc_status_t *status);
char *create_status_json_with_timestamp(const vlc_status_t *status, long long server_timestamp_ms);
void print_status(const vlc_status_t *status);
void print_usage(const char *program_name);
HWND create_player_window(vlc_player_t *player);
LRESULT CALLBACK WindowProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam);

// Check for Qt DLLs required for VLC Qt interface
int check_vlc_and_qt_libraries() {
    int missing = 0;
    HMODULE qt5core_dll = LoadLibrary("Qt5Core.dll");
    if (!qt5core_dll) {
        printf("Warning: Could not load Qt5Core.dll. VLC Qt interface may not work.\n");
        missing = 1;
    } else {
        FreeLibrary(qt5core_dll);
    }
    HMODULE qt5gui_dll = LoadLibrary("Qt5Gui.dll");
    if (!qt5gui_dll) {
        printf("Warning: Could not load Qt5Gui.dll. VLC Qt interface may not work.\n");
        missing = 1;
    } else {
        FreeLibrary(qt5gui_dll);
    }
    HMODULE qt5widgets_dll = LoadLibrary("Qt5Widgets.dll");
    if (!qt5widgets_dll) {
        printf("Warning: Could not load Qt5Widgets.dll. VLC Qt interface may not work.\n");
        missing = 1;
    } else {
        FreeLibrary(qt5widgets_dll);
    }
    return missing ? 0 : 1;
}

// Dynamically load VLC and resolve functions
int load_vlc_functions() {
    HMODULE vlc_dll = LoadLibrary("libvlc.dll");
    if (!vlc_dll) {
        printf("Error: Could not load libvlc.dll\n");
        return 0;
    }

    {
        union { FARPROC fp; libvlc_new_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_new");
        p_libvlc_new = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_release_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_release");
        p_libvlc_release = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_media_player_new_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_media_player_new");
        p_libvlc_media_player_new = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_media_player_release_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_media_player_release");
        p_libvlc_media_player_release = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_media_player_play_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_media_player_play");
        p_libvlc_media_player_play = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_media_player_pause_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_media_player_pause");
        p_libvlc_media_player_pause = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_media_player_stop_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_media_player_stop");
        p_libvlc_media_player_stop = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_media_player_is_playing_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_media_player_is_playing");
        p_libvlc_media_player_is_playing = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_media_player_get_time_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_media_player_get_time");
        p_libvlc_media_player_get_time = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_media_player_set_time_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_media_player_set_time");
        p_libvlc_media_player_set_time = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_media_player_get_length_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_media_player_get_length");
        p_libvlc_media_player_get_length = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_media_new_path_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_media_new_path");
        p_libvlc_media_new_path = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_media_release_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_media_release");
        p_libvlc_media_release = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_media_player_set_media_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_media_player_set_media");
        p_libvlc_media_player_set_media = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_media_get_meta_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_media_get_meta");
        p_libvlc_media_get_meta = caster.fn;
    }
    {
        union { FARPROC fp; libvlc_errmsg_t fn; } caster;
        caster.fp = GetProcAddress(vlc_dll, "libvlc_errmsg");
        p_libvlc_errmsg = caster.fn;
    }

    if (!p_libvlc_new || !p_libvlc_release || !p_libvlc_media_player_new || !p_libvlc_media_player_release ||
        !p_libvlc_media_player_play || !p_libvlc_media_player_pause || !p_libvlc_media_player_stop ||
        !p_libvlc_media_player_is_playing || !p_libvlc_media_player_get_time || !p_libvlc_media_player_set_time ||
        !p_libvlc_media_player_get_length || !p_libvlc_media_new_path || !p_libvlc_media_release ||
        !p_libvlc_media_player_set_media || !p_libvlc_media_get_meta || !p_libvlc_errmsg) {
        printf("Error: One or more VLC functions could not be loaded.\n");
        FreeLibrary(vlc_dll);
        return 0;
    }

    printf("VLC functions loaded dynamically.\n");
    return 1;
}

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

// Create player window
HWND create_player_window(vlc_player_t *player) {
    WNDCLASS wc = {0};
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = GetModuleHandle(NULL);
    wc.lpszClassName = "VLCPlayerWindow";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    
    if (!RegisterClass(&wc)) {
        printf("Error: Failed to register window class\n");
        return NULL;
    }
    
    // Create window with player as parameter
    HWND hwnd = CreateWindowEx(
        0,
        "VLCPlayerWindow",
        "VLC Player",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT, CW_USEDEFAULT,
        800, 600,
        NULL, NULL, GetModuleHandle(NULL), player
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
    static vlc_player_t *player = NULL;
    
    switch (uMsg) {
        case WM_CREATE: {
            // Store player pointer in window data
            CREATESTRUCT *cs = (CREATESTRUCT*)lParam;
            player = (vlc_player_t*)cs->lpCreateParams;
            SetWindowLongPtr(hwnd, GWLP_USERDATA, (LONG_PTR)player);
            break;
        }
        case WM_CLOSE:
            PostQuitMessage(0);
            return 0;
        case WM_KEYDOWN:
            // Handle keyboard shortcuts for VLC player
            switch (wParam) {
                case VK_SPACE: {
                    // Space bar to play/pause
                    if (player && player->media_player) {
                        if (p_libvlc_media_player_is_playing(player->media_player)) {
                            p_libvlc_media_player_pause(player->media_player);
                        } else {
                            p_libvlc_media_player_play(player->media_player);
                        }
                    }
                    break;
                }
                case VK_ESCAPE:
                    // Escape to stop
                    if (player && player->media_player) {
                        p_libvlc_media_player_stop(player->media_player);
                    }
                    break;
                case VK_LEFT:
                    // Left arrow to seek backward (10 seconds)
                    if (player && player->media_player) {
                        int64_t current_time = p_libvlc_media_player_get_time(player->media_player);
                        p_libvlc_media_player_set_time(player->media_player,
                            current_time > 10000 ? current_time - 10000 : 0);
                    }
                    break;
                case VK_RIGHT:
                    // Right arrow to seek forward (10 seconds)
                    if (player && player->media_player) {
                        int64_t current_time = p_libvlc_media_player_get_time(player->media_player);
                        p_libvlc_media_player_set_time(player->media_player, current_time + 10000);
                    }
                    break;
            }
            break;
        case WM_RBUTTONDOWN: {
            // Right-click to open file dialog
            OPENFILENAME ofn;
            char szFile[MAX_PATH] = "";
            
            ZeroMemory(&ofn, sizeof(ofn));
            ofn.lStructSize = sizeof(ofn);
            ofn.hwndOwner = hwnd;
            ofn.lpstrFile = szFile;
            ofn.nMaxFile = sizeof(szFile);
            ofn.lpstrFilter = "All Files\0*.*\0Video Files\0*.mp4;*.avi;*.mkv;*.mov;*.wmv;*.flv;*.webm\0Audio Files\0*.mp3;*.wav;*.flac;*.aac;*.ogg\0";
            ofn.nFilterIndex = 1;
            ofn.lpstrFileTitle = NULL;
            ofn.nMaxFileTitle = 0;
            ofn.lpstrInitialDir = NULL;
            ofn.Flags = OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST;
            
            if (GetOpenFileName(&ofn) == TRUE) {
                if (player) {
                    vlc_player_open_file(player, szFile);
                    vlc_player_play(player);
                }
            }
            break;
        }
        case WM_DROPFILES: {
            // Handle drag and drop of files
            HDROP hDrop = (HDROP)wParam;
            UINT fileCount = DragQueryFile(hDrop, 0xFFFFFFFF, NULL, 0);
            if (fileCount > 0) {
                char filePath[MAX_PATH];
                if (DragQueryFile(hDrop, 0, filePath, MAX_PATH)) {
                    if (player) {
                        vlc_player_open_file(player, filePath);
                        vlc_player_play(player);
                    }
                }
            }
            DragFinish(hDrop);
            break;
        }
    }
    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

// Main server loop
int main(int argc, char *argv[]) {
    char *initial_file = NULL;
    
    // Check for Qt DLLs required for VLC Qt interface
    check_vlc_and_qt_libraries();
    
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

    // Dynamically load VLC functions
    if (!load_vlc_functions()) {
        fprintf(stderr, "VLC functions not available. Please ensure VLC is installed and in PATH.\n");
        return 1;
    }

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

    // Create VLC player instance
    vlc_player_t *vlc_player = vlc_player_create();
    if (!vlc_player) {
        fprintf(stderr, "Failed to create VLC player instance\n");
        closesocket(multicast_sock);
        cleanup_winsock();
        return 1;
    }

    // Create player window
    HWND player_window = create_player_window(vlc_player);
    if (!player_window) {
        fprintf(stderr, "Failed to create player window\n");
        vlc_player_destroy(vlc_player);
        closesocket(multicast_sock);
        cleanup_winsock();
        return 1;
    }

    // Set window handle for VLC video output
    if (vlc_player->media_player) {
        // Use libvlc_media_player_set_hwnd to set the window for video output
        typedef void (*libvlc_media_player_set_hwnd_t)(void*, void*);
        union { FARPROC fp; libvlc_media_player_set_hwnd_t fn; } caster;
        caster.fp = GetProcAddress(GetModuleHandle("libvlc.dll"), "libvlc_media_player_set_hwnd");
        if (caster.fn) {
            caster.fn(vlc_player->media_player, player_window);
            printf("Set custom window for VLC video output\n");
        } else {
            printf("Warning: Could not set custom window for VLC video output\n");
        }
    }

    // Load initial file if provided
    if (initial_file) {
        if (vlc_player_open_file(vlc_player, initial_file)) {
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
    printf("[%s] Controls: Space=Play/Pause, Left/Right=Seek, Right-click=Open File, Drag&Drop=Load File\n", time_str);

    vlc_status_t current_status = {0};
    vlc_status_t last_status = {0};

    // Main loop
    MSG msg;
    DWORD last_update = GetTickCount();

    while (1) {
        // Process Windows messages (blocking)
        if (GetMessage(&msg, NULL, 0, 0) > 0) {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
            
            if (msg.message == WM_QUIT) {
                goto cleanup;
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
            int status_ok = query_vlc_status(vlc_player, &current_status);

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

                        if (!suppress_status_log) {
                            printf("[%s] Status broadcast: %s - %s\n",
                                   time_str,
                                   current_status.is_playing ? "Playing" : "Stopped",
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
            }

            last_update = current_time;
        }

        // Small sleep to prevent busy waiting
        Sleep(10);
    }

cleanup:
    // Cleanup
    vlc_player_destroy(vlc_player);
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

// Create VLC player with native VLC interface
vlc_player_t *vlc_player_create() {
    vlc_player_t *player = malloc(sizeof(vlc_player_t));
    if (!player) {
        return NULL;
    }

    memset(player, 0, sizeof(vlc_player_t));

    // Initialize VLC instance with full Qt interface enabled
    const char *vlc_args[] = {
        // "--intf", "qt",             // Use Qt interface (full VLC UI)
        // "--volume", "50",           // Set initial volume
        // "--video-title-show",       // Show video title
        // "--mouse-events",           // Enable mouse events
        // "--keyboard-events",        // Enable keyboard events
        // "--no-qt-privacy-ask",      // Skip privacy dialog
        // "--no-qt-updates-notif",    // Skip update notifications
        // "--qt-start-minimized"      // Start minimized to reduce initial load
    };


    player->vlc_instance = p_libvlc_new(sizeof(vlc_args) / sizeof(vlc_args[0]), vlc_args);
    if (!player->vlc_instance) {
        printf("Warning: Failed to create VLC instance with Qt interface: %s\n", p_libvlc_errmsg());
        printf("Attempting fallback to dummy interface...\n");

        // Fallback to dummy interface if Qt fails
        const char *fallback_args[] = {
            "--intf", "dummy",
            "--quiet"
        };

        player->vlc_instance = p_libvlc_new(sizeof(fallback_args) / sizeof(fallback_args[0]), fallback_args);
        if (!player->vlc_instance) {
            printf("Error: Failed to create VLC instance even with fallback: %s\n", p_libvlc_errmsg());
            free(player);
            return NULL;
        }
        printf("Successfully created VLC instance with dummy interface fallback\n");
    } else {
        printf("Successfully created VLC instance with Qt interface\n");
    }

    // Create media player
    player->media_player = p_libvlc_media_player_new(player->vlc_instance);
    if (!player->media_player) {
        printf("Error: Failed to create media player: %s\n", p_libvlc_errmsg());
        p_libvlc_release(player->vlc_instance);
        free(player);
        return NULL;
    }

    // VLC will create its own window - no need to set hwnd
    player->initialized = 1;

    if (debug_mode) {
        printf("[DEBUG] VLC player created successfully with native interface\n");
    }

    return player;

    if (debug_mode) {
        printf("[DEBUG] VLC player created successfully\n");
    }

    return player;
}

// Destroy VLC player
void vlc_player_destroy(vlc_player_t *player) {
    if (!player) return;


    if (player->current_media) {
        p_libvlc_media_release(player->current_media);
    }

    if (player->media_player) {
        p_libvlc_media_player_stop(player->media_player);
        p_libvlc_media_player_release(player->media_player);
    }

    if (player->vlc_instance) {
        p_libvlc_release(player->vlc_instance);
    }

    // VLC manages its own windows, no need to destroy them manually

    free(player);
}

// Open file in VLC player
int vlc_player_open_file(vlc_player_t *player, const char *filepath) {
    if (!player || !filepath) {
        return 0;
    }

    // Release previous media
    if (player->current_media) {
        p_libvlc_media_release(player->current_media);
        player->current_media = NULL;
    }

    // Create new media from file path

    player->current_media = p_libvlc_media_new_path(player->vlc_instance, filepath);
    if (!player->current_media) {
        printf("Error: Failed to create media from path: %s\n", p_libvlc_errmsg());
        return 0;
    }

    // Set media to player
    p_libvlc_media_player_set_media(player->media_player, player->current_media);

    if (debug_mode) {
        printf("[DEBUG] Opened file: %s\n", filepath);
    }

    return 1;
}

// Play media
int vlc_player_play(vlc_player_t *player) {
    if (!player || !player->media_player) {
        return 0;
    }

    int result = p_libvlc_media_player_play(player->media_player);

    if (debug_mode) {
        printf("[DEBUG] Play command sent, result: %d\n", result);
    }

    return result == 0; // libvlc_media_player_play returns 0 on success
}

// Pause media
int vlc_player_pause(vlc_player_t *player) {
    if (!player || !player->media_player) {
        return 0;
    }

    p_libvlc_media_player_pause(player->media_player);

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

    p_libvlc_media_player_stop(player->media_player);

    if (debug_mode) {
        printf("[DEBUG] Stop command sent\n");
    }

    return 1;
}

// Query VLC status using libvlc API
int query_vlc_status(vlc_player_t *player, vlc_status_t *status) {
    if (!player || !status) {
        return 0;
    }

    // Initialize status
    memset(status, 0, sizeof(vlc_status_t));

    // Get playing status

    status->is_playing = p_libvlc_media_player_is_playing(player->media_player);

    // Get current time and duration
    status->time = p_libvlc_media_player_get_time(player->media_player);
    status->duration = p_libvlc_media_player_get_length(player->media_player);

    // Get media info (title/filename)
    if (player->current_media) {
        char *meta_title = p_libvlc_media_get_meta(player->current_media, 0);  // libvlc_meta_Title = 0
        char *meta_filename = p_libvlc_media_get_meta(player->current_media, 15); // libvlc_meta_URL = 15

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
    printf("VLC Status Server with LibVLC - Creates native VLC instance and broadcasts status\n\n");
    printf("Usage: %s [--debug]\n\n", program_name);
    printf("Arguments:\n");
    printf("  --debug     Enable verbose debug output\n");
    printf("  --help, -h  Show this help message\n\n");
    printf("Features:\n");
    printf("  - Creates a full VLC media player with native VLC interface\n");
    printf("  - Use VLC's built-in controls to open files, play, pause, seek, etc.\n");
    printf("  - Broadcasts playback status to UDP multicast group 239.255.0.100:8888\n\n");
    printf("Examples:\n");
    printf("  %s                    # Start VLC player with status server\n", program_name);
    printf("  %s --debug            # Enable debug output\n", program_name);
}
