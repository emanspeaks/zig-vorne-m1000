#ifndef STATUS_MONITOR_H
#define STATUS_MONITOR_H

#include <windows.h>
#include <winsock2.h>
#include "vlc_player.h"

// Status monitor state structure
typedef struct {
    DWORD last_update_time;
    vlc_status_t current_status;
    vlc_status_t last_status;
    DWORD last_query_time;  // For debug interval tracking
} status_monitor_t;

// Function declarations
status_monitor_t* status_monitor_create();
void status_monitor_destroy(status_monitor_t* monitor);
int status_monitor_update(status_monitor_t* monitor, SOCKET multicast_sock, DWORD update_interval_ms);

#endif // STATUS_MONITOR_H