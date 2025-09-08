#include "ui.h"
#include "utils.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <commdlg.h>

// External variables (defined in main file)
extern int debug_mode;
extern vlc_player_t *g_vlc_player;
extern HWND g_status_bar;

// Format time in milliseconds to HH:MM:SS.mmm or MM:SS.mmm format
static void format_time_with_ms_local(long long time_ms, char *buffer, size_t buffer_size) {
    format_time_with_ms(time_ms, buffer, buffer_size);
}

// Update status bar with custom message
void update_status_bar_message(const char *message) {
    if (!g_status_bar) return;
    SendMessage(g_status_bar, SB_SETTEXT, 0, (LPARAM)message);
}

// Update status bar with current playback information
void update_status_bar(const vlc_status_t *status) {
    if (!g_status_bar) return;

    // Skip loading messages - go straight to normal playback status once media is ready

    char current_time_str[32];
    char duration_str[32];
    char status_text[512];  // Increased buffer size to avoid truncation warnings

    // Format current time and duration
    format_time_with_ms_local(status->time, current_time_str, sizeof(current_time_str));
    format_time_with_ms_local(status->duration, duration_str, sizeof(duration_str));

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

    // Create status text with better formatting
    if (status->duration > 0) {
        double progress = ((double)status->time / (double)status->duration) * 100.0;
        snprintf(status_text, sizeof(status_text), "%s - %s / %s (%.1f%%) | %s", 
                state_text, current_time_str, duration_str, progress, status->filename);
    } else if (strlen(status->filename) > 0 && strcmp(status->filename, "No media") != 0) {
        snprintf(status_text, sizeof(status_text), "%s - %s | %s", 
                state_text, current_time_str, status->filename);
    } else {
        snprintf(status_text, sizeof(status_text), "%s - Ready to load media", state_text);
    }

    SendMessage(g_status_bar, SB_SETTEXT, 0, (LPARAM)status_text);
}

// Open file dialog and load selected file
void open_file_dialog(HWND parent_window) {
    OPENFILENAME ofn;
    char szFile[260] = {0};

    ZeroMemory(&ofn, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = parent_window;
    ofn.lpstrFile = szFile;
    ofn.nMaxFile = sizeof(szFile);
    ofn.lpstrFilter = "Media Files\0*.mp4;*.avi;*.mkv;*.mov;*.wmv;*.flv;*.webm;*.m4v;*.3gp;*.mp3;*.wav;*.flac;*.aac;*.ogg;*.wma\0All Files\0*.*\0";
    ofn.nFilterIndex = 1;
    ofn.lpstrFileTitle = NULL;
    ofn.nMaxFileTitle = 0;
    ofn.lpstrInitialDir = NULL;
    ofn.Flags = OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST;

    if (GetOpenFileName(&ofn) == TRUE) {
        // User selected a file, try to open it
        if (g_vlc_player) {
            if (vlc_player_open_file(g_vlc_player, szFile)) {
                // File opened successfully
                printf("Opened file: %s\n", szFile);
            } else {
                printf("Failed to open file: %s\n", szFile);
                // Clear loading state on failure
                g_vlc_player->is_loading = 0;
                update_status_bar_message("Failed to open file - Right-click to try again");
            }
        }
    } else {
        // Dialog was cancelled, restore ready message
        update_status_bar_message("Ready - Right-click to open file, Space to play/pause, Home to seek to start");
    }
}

// Window procedure for handling messages
LRESULT CALLBACK WindowProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
        case WM_CREATE:
            // Create status bar
            g_status_bar = CreateWindowEx(
                0,
                STATUSCLASSNAME,
                NULL,
                WS_CHILD | WS_VISIBLE | SBARS_SIZEGRIP,
                0, 0, 0, 0,
                hwnd,
                NULL,
                GetModuleHandle(NULL),
                NULL
            );

            if (g_status_bar) {
                // Set initial status bar text
                SendMessage(g_status_bar, SB_SETTEXT, 0, (LPARAM)"Ready - Right-click to open file, Space to play/pause, Home to seek to start");
            }
            return 0;

        case WM_SIZE:
            // Resize status bar when window is resized
            if (g_status_bar) {
                SendMessage(g_status_bar, WM_SIZE, 0, 0);
            }
            return 0;

        case WM_CLOSE:
            // Handle window close - stop VLC first to prevent crashes
            if (g_vlc_player && g_vlc_player->media_player) {
                // Stop playback first
                libvlc_media_player_stop(g_vlc_player->media_player);

                // Clear the window handle to prevent VLC from trying to render
                libvlc_media_player_set_hwnd(g_vlc_player->media_player, NULL);

                // Give VLC a moment to cleanup
                // Sleep(100);
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
                    // Escape key to stop
                    if (g_vlc_player) {
                        vlc_player_stop(g_vlc_player);
                    }
                    return 0;

                case VK_LEFT:
                    // Left arrow to seek backward (10 seconds)
                    if (g_vlc_player && g_vlc_player->media_player) {
                        int64_t current_time = libvlc_media_player_get_time(g_vlc_player->media_player);
                        int64_t new_time = (current_time > 10000) ? current_time - 10000 : 0;
                        if (debug_mode) {
                            printf("[DEBUG] Seeking from %lld ms to %lld ms\n", current_time, new_time);
                        }
                        libvlc_media_player_set_time(g_vlc_player->media_player, new_time);
                        
                        // Reset desired state to allow playback restart after file ends
                        g_vlc_player->desired_playing_state = 0;
                        
                        // Give VLC a moment to process the seek
                        // Sleep(100);

                        // Don't auto-resume after seek - let user control with spacebar
                        // This avoids timing issues with VLC state transitions
                        if (debug_mode) {
                            printf("[DEBUG] Seek completed, user can resume with spacebar if desired\n");
                        }
                    }
                    return 0;

                case VK_RIGHT:
                    // Right arrow to seek forward (10 seconds)
                    if (g_vlc_player && g_vlc_player->media_player) {
                        int64_t current_time = libvlc_media_player_get_time(g_vlc_player->media_player);
                        int64_t duration = libvlc_media_player_get_length(g_vlc_player->media_player);
                        int64_t new_time = current_time + 10000;

                        // Prevent seeking beyond file duration
                        if (duration > 0 && new_time >= duration) {
                            new_time = duration - 1000; // Leave 1 second before end
                            if (new_time <= current_time) {
                                // Already at or near the end, don't seek
                                if (debug_mode) {
                                    printf("[DEBUG] Cannot seek forward - already at end of file (duration: %lld ms)\n", duration);
                                }
                                return 0;
                            }
                        }

                        if (debug_mode) {
                            printf("[DEBUG] Seeking from %lld ms to %lld ms (duration: %lld ms)\n", current_time, new_time, duration);
                        }
                        libvlc_media_player_set_time(g_vlc_player->media_player, new_time);
                        
                        // Reset desired state to allow playback restart after file ends
                        g_vlc_player->desired_playing_state = 0;
                        
                        // Give VLC a moment to process the seek
                        // Sleep(100);

                        // Don't auto-resume after seek - let user control with spacebar
                        // This avoids timing issues with VLC state transitions
                        if (debug_mode) {
                            printf("[DEBUG] Seek completed, user can resume with spacebar if desired\n");
                        }
                    }
                    return 0;

                case VK_HOME:
                    // Home key to seek to beginning
                    if (g_vlc_player && g_vlc_player->media_player) {
                        int64_t current_time = libvlc_media_player_get_time(g_vlc_player->media_player);
                        if (debug_mode) {
                            printf("[DEBUG] Seeking from %lld ms to 0 ms (Home)\n", current_time);
                        }
                        libvlc_media_player_set_time(g_vlc_player->media_player, 0);
                        
                        // Reset desired state to allow playback restart after file ends
                        g_vlc_player->desired_playing_state = 0;
                        
                        // Give VLC a moment to process the seek
                        // Sleep(100);

                        // Don't auto-resume after seek - let user control with spacebar
                        // This avoids timing issues with VLC state transitions
                        if (debug_mode) {
                            printf("[DEBUG] Seek completed, user can resume with spacebar if desired\n");
                        }
                    }
                    return 0;

                default:
                    break;
            }
            break;

        case WM_CONTEXTMENU:
        case WM_RBUTTONUP:
            // Right-click to open file dialog
            open_file_dialog(hwnd);
            return 0;

        case WM_DROPFILES:
            {
                HDROP hDrop = (HDROP)wParam;
                UINT fileCount = DragQueryFile(hDrop, 0xFFFFFFFF, NULL, 0);
                
                if (fileCount > 0) {
                    char filePath[MAX_PATH];
                    if (DragQueryFile(hDrop, 0, filePath, sizeof(filePath))) {
                        printf("Dropped file: %s\n", filePath);
                        
                        if (g_vlc_player) {
                            if (vlc_player_open_file(g_vlc_player, filePath)) {
                                printf("Successfully opened dropped file: %s\n", filePath);
                            } else {
                                printf("Failed to open dropped file: %s\n", filePath);
                                // Clear loading state on failure
                                g_vlc_player->is_loading = 0;
                                update_status_bar_message("Failed to open dropped file");
                            }
                        }
                    }
                }
                
                DragFinish(hDrop);
            }
            return 0;

        default:
            break;
    }

    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

// Create the main player window
HWND create_player_window() {
    const char* CLASS_NAME = "VLCStatusServerWindow";
    
    WNDCLASS wc = {0};
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = GetModuleHandle(NULL);
    wc.lpszClassName = CLASS_NAME;
    wc.hbrBackground = CreateSolidBrush(RGB(0, 0, 0));  // Black background
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    
    if (!RegisterClass(&wc)) {
        printf("Failed to register window class\n");
        return NULL;
    }
    
    HWND hwnd = CreateWindowEx(
        WS_EX_ACCEPTFILES,  // Enable drag & drop
        CLASS_NAME,
        "VLC Status Server",
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT,
        600, 600,  // Square-ish window
        NULL,
        NULL,
        GetModuleHandle(NULL),
        NULL
    );
    
    if (!hwnd) {
        printf("Failed to create window\n");
        return NULL;
    }
    
    return hwnd;
}