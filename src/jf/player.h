/*
 * Jellyfin playback: FFmpeg demuxes, LG's Starfish pipeline decodes and presents the
 * video on the TV's own plane, and the decoded audio goes to ALSA.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef enum { JF_IDLE, JF_LOADING, JF_PLAYING, JF_FAILED } jf_player_state;

bool jf_player_play(const char *stream_uri, const char *transcode_uri,
                    uint32_t width, uint32_t height);
void jf_player_pause(void);
void jf_player_resume(void);
void jf_player_stop(void);
void jf_player_deinit(void);

/* Jump `delta_seconds` from the displayed position. The segment loop performs the seek
 * once the feed threads have parked, so this only has to ask. */
void jf_player_seek(int delta_seconds);

jf_player_state jf_player_state_get(void);
const char *jf_player_error(void);
/* Displayed media position in milliseconds. */
int jf_player_position(void);

/* False: the video is on the TV's own plane, not in our framebuffer, so the app punches
 * a transparent hole rather than drawing a background. */
bool jf_player_embedded(void);
bool jf_player_needs_frame(void);
void jf_player_render(uint32_t width, uint32_t height);
