#include "utils.h"
#include <stdio.h>

// Format time in milliseconds to HH:MM:SS.mmm or MM:SS.mmm format
void format_time_with_ms(long long time_ms, char *buffer, size_t buffer_size) {
    if (time_ms < 0) {
        snprintf(buffer, buffer_size, "--:--:--");
        return;
    }
    
    int ms = time_ms % 1000;
    int total_seconds = (int)(time_ms / 1000);
    int seconds = total_seconds % 60;
    int minutes = (total_seconds / 60) % 60;
    int hours = total_seconds / 3600;
    
    if (hours > 0) {
        snprintf(buffer, buffer_size, "%d:%02d:%02d.%03d", hours, minutes, seconds, ms);
    } else {
        snprintf(buffer, buffer_size, "%d:%02d.%03d", minutes, seconds, ms);
    }
}

// Print usage information
void print_usage(const char *program_name) {
    printf("VLC Status Server - Broadcasts VLC playback status via multicast UDP\n\n");
    printf("Usage: %s [options] [--file <path>]\n\n", program_name);
    printf("Options:\n");
    printf("  --help, -h         Show this help message\n");
    printf("  --debug            Enable debug output\n");
    printf("  --file <path>, -f  Open specified file on startup\n\n");
    printf("Environment Variables:\n");
    printf("  VLC_NO_STATUS_LOG  Set to '1' to suppress repetitive status debug messages\n\n");
    printf("Controls:\n");
    printf("  Space              Play/Pause\n");
    printf("  Left Arrow         Seek backward 10 seconds\n");
    printf("  Right Arrow        Seek forward 10 seconds\n");
    printf("  Home               Seek to beginning\n");
    printf("  Right-click        Open file dialog\n");
    printf("  Escape             Stop playback\n\n");
    printf("Network:\n");
    printf("  Multicast IP:      239.255.255.250\n");
    printf("  Multicast Port:    12345\n");
    printf("  Update Interval:   250ms\n\n");
}