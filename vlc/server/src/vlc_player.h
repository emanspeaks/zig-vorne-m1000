#ifndef VLC_PLAYER_H
#define VLC_PLAYER_H

#include <vlc/vlc.h>
#include <windows.h>

// VLC status structure
typedef struct {
    int is_playing;      // 1=playing, 0=paused/stopped
    int is_paused;       // 1=paused, 0=playing/stopped
    int is_stopped;      // 1=stopped, 0=playing/paused
    int is_loading;      // 1=currently loading a file, 0=not loading
    long long time;
    long long duration;
    char title[256];
    char filename[256];
} vlc_status_t;

// VLC player structure
typedef struct {
    libvlc_instance_t *vlc_instance;
    libvlc_media_player_t *media_player;
    libvlc_media_t *current_media;
    char current_filepath[1024];  // Store the original filepath for fallback filename extraction
    int initialized;
    int desired_playing_state;  // 1=should be playing, 0=should be paused/stopped
    int is_loading;  // 1=currently loading a file, 0=not loading
    DWORD loading_start_time;  // When loading started (for timeout detection)
} vlc_player_t;

// External variables
extern int debug_mode;
extern int suppress_vlc_status_log;

// Function declarations
vlc_player_t *vlc_player_create();
void vlc_player_destroy(vlc_player_t *player);
int vlc_player_open_file(vlc_player_t *player, const char *filepath);
int vlc_player_play(vlc_player_t *player);
int vlc_player_pause(vlc_player_t *player);
int vlc_player_stop(vlc_player_t *player);
int vlc_player_toggle_play_pause(vlc_player_t *player);
int query_vlc_status(vlc_player_t *player, vlc_status_t *status);
void print_status(const vlc_status_t *status);

#endif // VLC_PLAYER_H