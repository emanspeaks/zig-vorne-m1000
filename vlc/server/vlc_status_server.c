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
#include "src/status_monitor.h"

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

    // Create status monitor
    status_monitor_t* status_monitor = status_monitor_create();
    if (!status_monitor) {
        printf("Failed to create status monitor\n");
        vlc_player_destroy(g_vlc_player);
        closesocket(multicast_sock);
        cleanup_winsock();
        return 1;
    }

    // Main event loop with status broadcasting
    MSG msg;

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
        status_monitor_update(status_monitor, multicast_sock, UPDATE_INTERVAL_MS);

        // Small sleep to prevent busy waiting
        Sleep(10);
    }

cleanup:
    printf("\nShutting down VLC Status Server...\n");
    
    // Cleanup status monitor
    status_monitor_destroy(status_monitor);
    
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