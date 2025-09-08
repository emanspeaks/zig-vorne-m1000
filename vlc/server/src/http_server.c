#include "http_server.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// External variables
extern vlc_player_t *g_vlc_player;

// Handle HTTP requests (for compatibility with external tools)
void handle_http_request(const char *request_line) {
    printf("HTTP request: %s\n", request_line);
    
    // Look for file parameter in the request
    char *file_param = strstr(request_line, "file=");
    if (file_param && g_vlc_player) {
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
        char decoded_path[1024];
        size_t decoded_len = 0;
        for (size_t i = 0; i < len && decoded_len < sizeof(decoded_path) - 1; i++) {
            if (filepath[i] == '+') {
                decoded_path[decoded_len++] = ' ';
            } else if (filepath[i] == '%' && i + 2 < len) {
                // Simple hex decode for %XX
                int hex_val;
                if (sscanf(&filepath[i + 1], "%2x", (unsigned int*)&hex_val) == 1) {
                    decoded_path[decoded_len++] = (char)hex_val;
                    i += 2;
                } else {
                    decoded_path[decoded_len++] = filepath[i];
                }
            } else {
                decoded_path[decoded_len++] = filepath[i];
            }
        }
        decoded_path[decoded_len] = '\0';

        printf("Opening file from HTTP request: %s\n", decoded_path);
        vlc_player_open_file(g_vlc_player, decoded_path);
    }
}