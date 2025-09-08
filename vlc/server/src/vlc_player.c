#include "vlc_player.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// External variables (defined in main file)
extern int debug_mode;
extern int suppress_vlc_status_log;

// Create VLC player instance
vlc_player_t *vlc_player_create() {
    vlc_player_t *player = (vlc_player_t *)malloc(sizeof(vlc_player_t));
    if (!player) {
        return NULL;
    }

    // Initialize all fields to zero/NULL
    memset(player, 0, sizeof(vlc_player_t));

    // Create VLC instance - use minimal arguments for better compatibility
    const char *vlc_args[] = {
        "--quiet",              // Suppress VLC console output
        "--no-xlib",            // Disable X11 (not needed on Windows)
        "--extraintf=dummy",    // Use dummy interface
        "--intf=dummy",         // No interface
        "--no-video-title-show" // Don't show video title overlay
    };

    player->vlc_instance = libvlc_new(sizeof(vlc_args)/sizeof(vlc_args[0]), vlc_args);

    if (!player->vlc_instance) {
        printf("Failed to create VLC instance\n");
        free(player);
        return NULL;
    }

    // Create media player
    player->media_player = libvlc_media_player_new(player->vlc_instance);
    if (!player->media_player) {
        printf("Failed to create VLC media player\n");
        libvlc_release(player->vlc_instance);
        free(player);
        return NULL;
    }

    player->initialized = 1;

    if (debug_mode) {
        printf("[DEBUG] VLC player created successfully\n");
    }

    return player;
}

// Destroy VLC player instance
void vlc_player_destroy(vlc_player_t *player) {
    if (!player) return;

    // Stop playback first
    if (player->media_player) {
        libvlc_media_player_stop(player->media_player);
        libvlc_media_player_set_hwnd(player->media_player, NULL);
    }

    // Release media
    if (player->current_media) {
        libvlc_media_release(player->current_media);
        player->current_media = NULL;
    }

    // Release media player
    if (player->media_player) {
        libvlc_media_player_release(player->media_player);
        player->media_player = NULL;
    }

    // Release VLC instance
    if (player->vlc_instance) {
        libvlc_release(player->vlc_instance);
        player->vlc_instance = NULL;
    }

    player->initialized = 0;
    free(player);
}

// Open a media file
int vlc_player_open_file(vlc_player_t *player, const char *filepath) {
    if (!player || !player->initialized || !filepath) {
        return 0;
    }

    // Set loading state
    player->is_loading = 1;
    player->loading_start_time = GetTickCount();

    // Store the filepath for filename extraction
    strncpy(player->current_filepath, filepath, sizeof(player->current_filepath) - 1);
    player->current_filepath[sizeof(player->current_filepath) - 1] = '\0';

    // Release previous media if any
    if (player->current_media) {
        libvlc_media_release(player->current_media);
    }

    // Create media from file path
    player->current_media = libvlc_media_new_path(player->vlc_instance, filepath);
    if (!player->current_media) {
        printf("Failed to create media from path: %s\n", filepath);
        player->is_loading = 0;
        return 0;
    }

    // Set media to player
    libvlc_media_player_set_media(player->media_player, player->current_media);

    if (debug_mode) {
        printf("[DEBUG] Opened file: %s\n", filepath);
    }

    return 1;
}

// Play media
int vlc_player_play(vlc_player_t *player) {
    if (!player || !player->media_player || !player->current_media) {
        return 0;
    }

    int result = libvlc_media_player_play(player->media_player);
    if (result == 0) {
        player->desired_playing_state = 1;
    }

    return result == 0;
}

// Pause media
int vlc_player_pause(vlc_player_t *player) {
    if (!player || !player->media_player) {
        return 0;
    }

    libvlc_media_player_pause(player->media_player);
    player->desired_playing_state = 0;
    return 1;
}

// Stop media
int vlc_player_stop(vlc_player_t *player) {
    if (!player || !player->media_player) {
        return 0;
    }

    libvlc_media_player_stop(player->media_player);
    player->desired_playing_state = 0;
    return 1;
}

// Toggle play/pause
int vlc_player_toggle_play_pause(vlc_player_t *player) {
    if (!player || !player->media_player) {
        return 0;
    }

    int vlc_is_playing = libvlc_media_player_is_playing(player->media_player);

    if (vlc_is_playing) {
        return vlc_player_pause(player);
    } else {
        return vlc_player_play(player);
    }
}

// Simplified query VLC status function
int query_vlc_status(vlc_player_t *player, vlc_status_t *status) {
    if (!player || !status) {
        return 0;
    }

    // Initialize status
    memset(status, 0, sizeof(vlc_status_t));

    if (!player->initialized || !player->media_player) {
        status->is_stopped = 1;
        status->time = -1;
        status->duration = -1;
        strcpy(status->title, "No VLC");
        strcpy(status->filename, "No VLC");
        return 1;
    }

    // Get basic playback info
    int vlc_is_playing = libvlc_media_player_is_playing(player->media_player);
    status->time = libvlc_media_player_get_time(player->media_player);
    status->duration = libvlc_media_player_get_length(player->media_player);

    // Simplified state detection
    if (vlc_is_playing && status->time > 0) {
        status->is_playing = 1;
        status->is_paused = 0;
        status->is_stopped = 0;
        player->is_loading = 0;  // Clear loading if we have time progress
    } else if (player->current_media && status->duration > 0) {
        status->is_playing = 0;
        status->is_paused = 1;
        status->is_stopped = 0;
        if (status->time == 0 && vlc_is_playing && !player->is_loading) {
            player->is_loading = 1;
            player->loading_start_time = GetTickCount();
        }
    } else {
        status->is_playing = 0;
        status->is_paused = 0;
        status->is_stopped = 1;
        player->is_loading = 0;
    }

    // Check for loading timeout
    if (player->is_loading && GetTickCount() - player->loading_start_time > 45000) {
        player->is_loading = 0;
    }

    // Get media info
    if (player->current_media) {
        char *meta_title = libvlc_media_get_meta(player->current_media, libvlc_meta_Title);
        char *meta_filename = libvlc_media_get_meta(player->current_media, libvlc_meta_URL);

        if (meta_title && strlen(meta_title) > 0) {
            strncpy(status->title, meta_title, sizeof(status->title) - 1);
            status->title[sizeof(status->title) - 1] = '\0';
        } else {
            strcpy(status->title, "");
        }

        if (meta_filename && strlen(meta_filename) > 0) {
            const char *filename_only = strrchr(meta_filename, '\\');
            if (!filename_only) filename_only = strrchr(meta_filename, '/');
            if (filename_only) {
                strncpy(status->filename, filename_only + 1, sizeof(status->filename) - 1);
            } else {
                strncpy(status->filename, meta_filename, sizeof(status->filename) - 1);
            }
            status->filename[sizeof(status->filename) - 1] = '\0';
        } else if (strlen(player->current_filepath) > 0) {
            const char *filename_only = strrchr(player->current_filepath, '\\');
            if (!filename_only) filename_only = strrchr(player->current_filepath, '/');
            if (filename_only) {
                strncpy(status->filename, filename_only + 1, sizeof(status->filename) - 1);
            } else {
                strncpy(status->filename, player->current_filepath, sizeof(status->filename) - 1);
            }
            status->filename[sizeof(status->filename) - 1] = '\0';
        } else {
            strcpy(status->filename, "Unknown");
        }

        if (meta_title) libvlc_free(meta_title);
        if (meta_filename) libvlc_free(meta_filename);
    } else {
        strcpy(status->title, "No media");
        strcpy(status->filename, "No media");
    }

    status->is_loading = player->is_loading;
    return 1;
}

// Print status information
void print_status(const vlc_status_t *status) {
    printf("\n=== VLC Status ===\n");
    printf("State: %s\n", status->is_playing ? "Playing" : 
                          status->is_paused ? "Paused" : "Stopped");
    printf("Time: %lld ms\n", status->time);
    printf("Duration: %lld ms\n", status->duration);
    printf("Filename: %s\n", status->filename);
    printf("==================\n\n");
}