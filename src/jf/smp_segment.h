/*
 * Establish the CustomPipeline segment both the load payload and every later seek depend
 * on. libpf describes the timeline at load, but does not activate it until the pipeline
 * receives a segment event, and StarfishMediaAPIs' public setTimeToDecode wrapper rejects
 * the LOADED state - so the underlying transition is used instead, as spool-mpv does.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

bool jf_starfish_begin_segment(int64_t pts_ns);
const char *jf_starfish_segment_error(void);
