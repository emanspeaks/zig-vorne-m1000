#ifndef UI_H
#define UI_H

#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include "vlc_player.h"

// External variables
extern HWND g_status_bar;
extern vlc_player_t *g_vlc_player;

// Function declarations
LRESULT CALLBACK WindowProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam);
HWND create_player_window();
void update_status_bar_message(const char *message);
void update_status_bar(const vlc_status_t *status);
void open_file_dialog(HWND parent_window);

#endif // UI_H