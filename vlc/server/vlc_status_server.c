/*
 * VLC Status Server - Main Entry Point
 * 
 * A Windows application that provides VLC media player control and broadcasts
 * playback status via multicast UDP for remote monitoring.
 * 
 * Features:
 * - VLC media player integration with file loading and playback controls
 * - Real-time status broadcasting via UDP multicast (239.255.255.250:12345)
 * - Windows UI with status bar and keyboard/mouse controls
 * - Drag & drop file support
 * - Command line options and debug modes
 * 
 * Architecture:
 * - src/vlc_player.c: VLC integration and media control
 * - src/network.c: UDP multicast and JSON status broadcasting
 * - src/ui.c: Windows GUI, keyboard/mouse handling, file dialogs
 * - src/utils.c: Utility functions (time formatting, help text)
 */

#include <stdio.h>
#include <string.h>
#include <windows.h>
#include <winsock2.h>

// Include our modular components
#include "src/vlc_player.h"
#include "src/network.h"
#include "src/ui.h"
#include "src/utils.h"
#include "src/http_server.h"

// Constants
#define UPDATE_INTERVAL_MS 250

// Global variables
int debug_mode = 0;
int suppress_vlc_status_log = 0;
vlc_player_t *g_vlc_player = NULL;
HWND g_status_bar = NULL;


// Main application entry point
int main(int argc, char *argv[]) {
    char *initial_file = NULL;

    // Check for VLC_NO_STATUS_LOG environment variable
    char *no_status_log_env = getenv("VLC_NO_STATUS_LOG");
    if (no_status_log_env && strcmp(no_status_log_env, "1") == 0) {
        suppress_vlc_status_log = 1;
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
                i++; // Skip the next argument as it's the file path
            } else {
                printf("Error: --file option requires a file path\n");
                return 1;
            }
        }
    }

    printf("VLC Status Server starting...\n");
    
    if (suppress_vlc_status_log) {
        printf("VLC status logging suppressed (VLC_NO_STATUS_LOG=1)\n");
    }

    // Initialize Winsock for network communication
    if (!initialize_winsock()) {
        printf("Failed to initialize Winsock\n");
        return 1;
    }

    // Create multicast socket for status broadcasting
    SOCKET multicast_sock = create_multicast_socket();
    if (multicast_sock == INVALID_SOCKET) {
        printf("Failed to create multicast socket\n");
        cleanup_winsock();
        return 1;
    }

    // Initialize VLC player
    g_vlc_player = vlc_player_create();
    if (!g_vlc_player) {
        printf("Failed to create VLC player\n");
        closesocket(multicast_sock);
        cleanup_winsock();
        return 1;
    }

    // Create main window
    HWND main_window = create_player_window();
    if (!main_window) {
        printf("Failed to create main window\n");
        vlc_player_destroy(g_vlc_player);
        closesocket(multicast_sock);
        cleanup_winsock();
        return 1;
    }

    // Set VLC to render in our window
    if (g_vlc_player->media_player) {
        libvlc_media_player_set_hwnd(g_vlc_player->media_player, main_window);
    }

    // Show window
    ShowWindow(main_window, SW_SHOW);
    UpdateWindow(main_window);

    printf("VLC Status Server running. Window created.\n");
    printf("Controls: Space=Play/Pause, Arrows=Seek, Home=Start, Right-click=Open File\n");
    printf("Broadcasting status on 239.255.255.250:12345 every %dms\n", UPDATE_INTERVAL_MS);

    // Load initial file if specified
    if (initial_file && g_vlc_player) {
        printf("Loading initial file: %s\n", initial_file);
        if (!vlc_player_open_file(g_vlc_player, initial_file)) {
            printf("Warning: Failed to load initial file\n");
        }
    }

    // Main event loop with status broadcasting
    MSG msg;
    DWORD last_update = 0;
    vlc_status_t current_status = {0};
    vlc_status_t last_status = {0};

    while (1) {
        // Handle Windows messages (non-blocking)
        while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) {
                goto cleanup;
            }
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }

        // Update VLC status and broadcast at regular intervals
        DWORD current_time = GetTickCount();
        if (current_time - last_update >= UPDATE_INTERVAL_MS) {

            if (debug_mode && !suppress_vlc_status_log) {
                static DWORD last_query_time = 0;
                if (last_query_time > 0) {
                    printf("[DEBUG] Query interval: %lu ms\n", current_time - last_query_time);
                }
                last_query_time = current_time;
            }

            // Get server timestamp at poll time (UTC milliseconds)
            long long server_timestamp_ms = getUnixTimeMs();

            // Query VLC status directly from libvlc
            if (debug_mode && !suppress_vlc_status_log) {
                printf("[DEBUG] About to query VLC status...\n");
            }

            int status_ok = query_vlc_status(g_vlc_player, &current_status);

            if (debug_mode && !suppress_vlc_status_log) {
                printf("[DEBUG] Query VLC status completed, status_ok: %d\n", status_ok);
            }

            if (status_ok) {
                // Update status bar with current playback info
                update_status_bar(&current_status);

                // Check if status changed significantly
                int status_changed = 0;
                if (current_status.is_playing != last_status.is_playing ||
                    current_status.is_paused != last_status.is_paused ||
                    current_status.is_stopped != last_status.is_stopped ||
                    abs((int)(current_status.time - last_status.time)) > 2000 ||  // Time diff > 2 sec
                    strcmp(current_status.title, last_status.title) != 0 ||
                    strcmp(current_status.filename, last_status.filename) != 0) {
                    status_changed = 1;
                }

                if (debug_mode && (!suppress_vlc_status_log || status_changed)) {
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
                    if (debug_mode && !suppress_vlc_status_log) {
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

                        if (!suppress_vlc_status_log) {
                            // Determine status text for broadcast
                            const char *status_text;
                            if (g_vlc_player && g_vlc_player->is_loading) {
                                status_text = "Loading";
                            } else if (current_status.is_playing) {
                                status_text = "Playing";
                            } else if (current_status.is_paused) {
                                status_text = "Paused";
                            } else if (current_status.is_stopped) {
                                status_text = "Stopped";
                            } else {
                                status_text = "Unknown";
                            }

                            printf("[%s] %s | %s\n", time_str, status_text, current_status.filename);
                        }
                    } else {
                        printf("Failed to send multicast data\n");
                    }
                    
                    free(json_message);
                }
            } else {
                // VLC query failed - set default stopped status
                current_status.is_playing = 0;
                current_status.is_paused = 0;
                current_status.is_stopped = 1;
                current_status.is_loading = 0;
                current_status.time = 0;
                current_status.duration = 0;
                strcpy(current_status.title, "No media");
                strcpy(current_status.filename, "No media");
                
                update_status_bar(&current_status);
            }

            last_update = current_time;
        }

        // Small sleep to prevent busy waiting
        Sleep(10);
    }

cleanup:
    printf("\nShutting down VLC Status Server...\n");
    
    // Cleanup VLC player
    if (g_vlc_player) {
        vlc_player_destroy(g_vlc_player);
        g_vlc_player = NULL;
    }
    
    // Cleanup network
    closesocket(multicast_sock);
    cleanup_winsock();
    
    printf("Cleanup completed. Goodbye!\n");
    return 0;
}