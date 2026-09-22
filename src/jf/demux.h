/* Container demux and audio decode. Implemented in demux.c against the bundled FFmpeg. */
#pragma once

#include <stdint.h>

void *jf_demux_open(const char *url);
void jf_demux_close(void *demux);
int jf_demux_stream_count(void *demux);
int jf_demux_stream(void *demux, int index, int *kind, int *codec, int *width, int *height);
int jf_demux_next(void *demux, uint8_t **data, int *size, int *stream, int64_t *pts);
int jf_demux_video_fps(void *demux, int index, int *num, int *den);
int jf_demux_audio_open(void *demux, int index, int *rate);
int jf_demux_video_open(void *demux, int index);
int jf_demux_video_unsupported(void *demux);
int jf_demux_audio_decode(void *demux, uint8_t **out, int *size, int64_t *pts);
int jf_demux_seek(void *demux, int64_t position_ns);
int jf_demux_reopen(void *demux, const char *url);
