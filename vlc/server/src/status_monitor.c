#include "status_monitor.h"
#include "network.h"
#include "ui.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// External variables
extern int debug_mode;
extern int suppress_vlc_status_log;
extern vlc_player_t *g_vlc_player;

// Create status monitor instance
status_monitor_t* status_monitor_create() {
    status_monitor_t* monitor = (status_monitor_t*)malloc(sizeof(status_monitor_t));
    if (!monitor) {
        return NULL;
    }
    
    memset(monitor, 0, sizeof(status_monitor_t));
    return monitor;
}

// Destroy status monitor instance
void status_monitor_destroy(status_monitor_t* monitor) {
    if (monitor) {
        free(monitor);
    }
}

// Update and broadcast VLC status
int status_monitor_update(status_monitor_t* monitor, SOCKET multicast_sock, DWORD update_interval_ms) {
    if (!monitor) return 0;
    
    DWORD current_time = GetTickCount();
    if (current_time - monitor->last_update_time < update_interval_ms) {
        return 0;  // Not time to update yet
    }
    
    // Debug interval tracking
    if (debug_mode && !suppress_vlc_status_log) {
        if (monitor->last_query_time > 0) {
            printf("[DEBUG] Query interval: %lu ms\n", current_time - monitor->last_query_time);
        }
        monitor->last_query_time = current_time;
    }

    // Get server timestamp at poll time (UTC milliseconds)
    long long server_timestamp_ms = getUnixTimeMs();

    // Query VLC status directly from libvlc
    if (debug_mode && !suppress_vlc_status_log) {
        printf("[DEBUG] About to query VLC status...\n");
    }

    int status_ok = query_vlc_status(g_vlc_player, &monitor->current_status);

    if (debug_mode && !suppress_vlc_status_log) {
        printf("[DEBUG] Query VLC status completed, status_ok: %d\n", status_ok);
    }

    if (status_ok) {
        // Update status bar with current playback info
        update_status_bar(&monitor->current_status);

        // Check if status changed significantly
        int status_changed = 0;
        if (monitor->current_status.is_playing != monitor->last_status.is_playing ||
            monitor->current_status.is_paused != monitor->last_status.is_paused ||
            monitor->current_status.is_stopped != monitor->last_status.is_stopped ||
            abs((int)(monitor->current_status.time - monitor->last_status.time)) > 2000 ||  // Time diff > 2 sec
            strcmp(monitor->current_status.title, monitor->last_status.title) != 0 ||
            strcmp(monitor->current_status.filename, monitor->last_status.filename) != 0) {
            status_changed = 1;
        }

        if (debug_mode && (!suppress_vlc_status_log || status_changed)) {
            printf("[DEBUG] Query result - Playing: %s, Time: %lld ms, Status changed: %s\n",
                   monitor->current_status.is_playing ? "Yes" : "No",
                   monitor->current_status.time,
                   status_changed ? "Yes" : "No");
        }

        if (status_changed) {
            // Update last status
            memcpy(&monitor->last_status, &monitor->current_status, sizeof(vlc_status_t));
        }

        // Always send the current status
        char *json_message = create_status_json_with_timestamp(&monitor->current_status, server_timestamp_ms);
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
                    } else if (monitor->current_status.is_playing) {
                        status_text = "Playing";
                    } else if (monitor->current_status.is_paused) {
                        status_text = "Paused";
                    } else if (monitor->current_status.is_stopped) {
                        status_text = "Stopped";
                    } else {
                        status_text = "Unknown";
                    }

                    printf("[%s] %s | %s\n", time_str, status_text, monitor->current_status.filename);
                }
            } else {
                printf("Failed to send multicast data\n");
            }
            
            free(json_message);
        }
    } else {
        // VLC query failed - set default stopped status
        monitor->current_status.is_playing = 0;
        monitor->current_status.is_paused = 0;
        monitor->current_status.is_stopped = 1;
        monitor->current_status.is_loading = 0;
        monitor->current_status.time = 0;
        monitor->current_status.duration = 0;
        strcpy(monitor->current_status.title, "No media");
        strcpy(monitor->current_status.filename, "No media");
        
        update_status_bar(&monitor->current_status);
    }

    monitor->last_update_time = current_time;
    return 1;  // Updated successfully
}