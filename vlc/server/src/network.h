#ifndef NETWORK_H
#define NETWORK_H

#include <windows.h>
#include <winsock2.h>
#include "vlc_player.h"

// Function declarations
long long getUnixTimeMs();
int initialize_winsock();
void cleanup_winsock();
SOCKET create_multicast_socket();
int send_multicast_data(SOCKET sock, const char *data);
char *create_status_json_with_timestamp(const vlc_status_t *status, long long server_timestamp_ms);

#endif // NETWORK_H