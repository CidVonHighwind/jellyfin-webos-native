// Runtime FFmpeg demux binding.  This source deliberately links no FFmpeg
// library: webOS supplies ABI-compatible libavformat 58/libavcodec 58, loaded
// only when playback begins.
#include <dlfcn.h>
#include <stdint.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>

struct jf_demux {
    AVFormatContext *format;
    AVPacket *packet;
    // Audio is decoded here: the pipeline only builds an audio sink for PCM.
    AVCodecContext *audio;
    AVFrame *frame;
    struct SwrContext *swr;
    uint8_t *pcm;
    int pcm_cap, pcm_size;
    // A file container stores H.264/H.265 length-prefixed with the parameter
    // sets off in extradata. The hardware decoder wants Annex-B start codes --
    // without them it reports "Sequence Init Fail" and never starts.
    AVBSFContext *bsf;
    AVPacket *filtered;
    int video_index;
};
static void *format_lib, *codec_lib, *util_lib, *swr_lib;
static int (*p_open)(AVFormatContext **, const char *, AVInputFormat *, AVDictionary **);
static int (*p_info)(AVFormatContext *, AVDictionary **);
static int (*p_read)(AVFormatContext *, AVPacket *);
static void (*p_close)(AVFormatContext **);
static AVPacket *(*p_packet_alloc)(void);
static void (*p_packet_free)(AVPacket **);
static void (*p_packet_unref)(AVPacket *);
static AVCodec *(*p_find_decoder)(enum AVCodecID);
static AVCodecContext *(*p_alloc_context)(const AVCodec *);
static int (*p_parameters_to_context)(AVCodecContext *, const AVCodecParameters *);
static int (*p_codec_open)(AVCodecContext *, const AVCodec *, AVDictionary **);
static int (*p_send_packet)(AVCodecContext *, const AVPacket *);
static int (*p_receive_frame)(AVCodecContext *, AVFrame *);
static void (*p_free_context)(AVCodecContext **);
static AVFrame *(*p_frame_alloc)(void);
static void (*p_frame_free)(AVFrame **);
static struct SwrContext *(*p_swr_alloc_set_opts)(struct SwrContext *, int64_t, enum AVSampleFormat, int,
                                                  int64_t, enum AVSampleFormat, int, int, void *);
static int (*p_swr_init)(struct SwrContext *);
static int (*p_swr_convert)(struct SwrContext *, uint8_t **, int, const uint8_t **, int);
static void (*p_swr_free)(struct SwrContext **);
static void (*p_log_set_level)(int);
static int (*p_seek)(AVFormatContext *, int, int64_t, int);
static void (*p_flush_buffers)(AVCodecContext *);
static const AVBitStreamFilter *(*p_bsf_by_name)(const char *);
static int (*p_bsf_alloc)(const AVBitStreamFilter *, AVBSFContext **);
static int (*p_bsf_init)(AVBSFContext *);
static int (*p_bsf_send)(AVBSFContext *, AVPacket *);
static int (*p_bsf_receive)(AVBSFContext *, AVPacket *);
static void (*p_bsf_free)(AVBSFContext **);
static void (*p_bsf_flush)(AVBSFContext *);
static int (*p_parameters_copy)(AVCodecParameters *, const AVCodecParameters *);

static int load(void) {
    if (p_open) return 1;
    format_lib = dlopen("libavformat.so.58", RTLD_NOW | RTLD_LOCAL);
    codec_lib = dlopen("libavcodec.so.58", RTLD_NOW | RTLD_LOCAL);
    if (!format_lib || !codec_lib) return 0;
    *(void **)(&p_open) = dlsym(format_lib, "avformat_open_input");
    *(void **)(&p_info) = dlsym(format_lib, "avformat_find_stream_info");
    *(void **)(&p_read) = dlsym(format_lib, "av_read_frame");
    *(void **)(&p_close) = dlsym(format_lib, "avformat_close_input");
    *(void **)(&p_packet_alloc) = dlsym(codec_lib, "av_packet_alloc");
    *(void **)(&p_packet_free) = dlsym(codec_lib, "av_packet_free");
    *(void **)(&p_packet_unref) = dlsym(codec_lib, "av_packet_unref");
    if (!p_open || !p_info || !p_read || !p_close || !p_packet_alloc || !p_packet_free || !p_packet_unref) return 0;
    // Audio decode is optional: video still plays if these are missing.
    util_lib = dlopen("libavutil.so.56", RTLD_NOW | RTLD_LOCAL);
    swr_lib = dlopen("libswresample.so.3", RTLD_NOW | RTLD_LOCAL);
    if (!util_lib || !swr_lib) return 1;
    *(void **)(&p_find_decoder) = dlsym(codec_lib, "avcodec_find_decoder");
    *(void **)(&p_alloc_context) = dlsym(codec_lib, "avcodec_alloc_context3");
    *(void **)(&p_parameters_to_context) = dlsym(codec_lib, "avcodec_parameters_to_context");
    *(void **)(&p_codec_open) = dlsym(codec_lib, "avcodec_open2");
    *(void **)(&p_send_packet) = dlsym(codec_lib, "avcodec_send_packet");
    *(void **)(&p_receive_frame) = dlsym(codec_lib, "avcodec_receive_frame");
    *(void **)(&p_free_context) = dlsym(codec_lib, "avcodec_free_context");
    *(void **)(&p_frame_alloc) = dlsym(util_lib, "av_frame_alloc");
    *(void **)(&p_frame_free) = dlsym(util_lib, "av_frame_free");
    *(void **)(&p_seek) = dlsym(format_lib, "av_seek_frame");
    *(void **)(&p_flush_buffers) = dlsym(codec_lib, "avcodec_flush_buffers");
    *(void **)(&p_bsf_by_name) = dlsym(codec_lib, "av_bsf_get_by_name");
    *(void **)(&p_bsf_alloc) = dlsym(codec_lib, "av_bsf_alloc");
    *(void **)(&p_bsf_init) = dlsym(codec_lib, "av_bsf_init");
    *(void **)(&p_bsf_send) = dlsym(codec_lib, "av_bsf_send_packet");
    *(void **)(&p_bsf_receive) = dlsym(codec_lib, "av_bsf_receive_packet");
    *(void **)(&p_bsf_free) = dlsym(codec_lib, "av_bsf_free");
    *(void **)(&p_bsf_flush) = dlsym(codec_lib, "av_bsf_flush");
    *(void **)(&p_parameters_copy) = dlsym(codec_lib, "avcodec_parameters_copy");
    *(void **)(&p_swr_alloc_set_opts) = dlsym(swr_lib, "swr_alloc_set_opts");
    *(void **)(&p_swr_init) = dlsym(swr_lib, "swr_init");
    *(void **)(&p_swr_convert) = dlsym(swr_lib, "swr_convert");
    *(void **)(&p_swr_free) = dlsym(swr_lib, "swr_free");
    // find_stream_info opens a decoder per stream to probe it; we only ever
    // demux, so its per-frame complaints are noise on our stderr.
    *(void **)(&p_log_set_level) = dlsym(util_lib, "av_log_set_level");
    if (p_log_set_level) p_log_set_level(AV_LOG_FATAL);
    return 1;
}

/// Open the decoder for one audio stream. Output is always S16LE stereo at the
/// stream's own rate; the pipeline takes nothing else. 1 on success.
int jf_demux_audio_open(void *opaque, int index, int *rate) {
    struct jf_demux *d = opaque;
    if (!p_find_decoder || !p_frame_alloc || !p_swr_alloc_set_opts) return 0;
    if (index < 0 || index >= (int)d->format->nb_streams) return 0;
    AVCodecParameters *par = d->format->streams[index]->codecpar;
    AVCodec *dec = p_find_decoder(par->codec_id);
    if (!dec || !(d->audio = p_alloc_context(dec))) return 0;
    if (p_parameters_to_context(d->audio, par) < 0 || p_codec_open(d->audio, dec, 0) < 0) return 0;
    if (!(d->frame = p_frame_alloc())) return 0;
    int64_t in_layout = d->audio->channel_layout;
    if (!in_layout) in_layout = d->audio->channels == 1 ? AV_CH_LAYOUT_MONO : AV_CH_LAYOUT_STEREO;
    d->swr = p_swr_alloc_set_opts(0, AV_CH_LAYOUT_STEREO, AV_SAMPLE_FMT_S16, d->audio->sample_rate,
                                  in_layout, d->audio->sample_fmt, d->audio->sample_rate, 0, 0);
    if (!d->swr || p_swr_init(d->swr) < 0) return 0;
    *rate = d->audio->sample_rate;
    return 1;
}

/// Decode the packet jf_demux_next last returned into interleaved S16LE stereo.
/// The buffer stays valid until the next call. 1 when there are samples.
int jf_demux_audio_decode(void *opaque, uint8_t **out, int *size) {
    struct jf_demux *d = opaque;
    d->pcm_size = 0;
    if (!d->audio || p_send_packet(d->audio, d->packet) < 0) return 0;
    while (p_receive_frame(d->audio, d->frame) == 0) {
        int need = d->pcm_size + d->frame->nb_samples * 4; // 2 channels, 2 bytes
        if (need > d->pcm_cap) {
            uint8_t *grown = realloc(d->pcm, need);
            if (!grown) return 0;
            d->pcm = grown;
            d->pcm_cap = need;
        }
        uint8_t *dst = d->pcm + d->pcm_size;
        int got = p_swr_convert(d->swr, &dst, d->frame->nb_samples,
                                (const uint8_t **)d->frame->extended_data, d->frame->nb_samples);
        if (got > 0) d->pcm_size += got * 4;
    }
    *out = d->pcm;
    *size = d->pcm_size;
    return d->pcm_size > 0;
}

void *jf_demux_open(const char *url) {
    if (!load()) return 0;
    struct jf_demux *d = calloc(1, sizeof(*d));
    if (!d || p_open(&d->format, url, 0, 0) < 0 || p_info(d->format, 0) < 0 || !(d->packet = p_packet_alloc())) {
        if (d) { if (d->format) p_close(&d->format); free(d); }
        return 0;
    }
    return d;
}

void jf_demux_close(void *opaque) {
    struct jf_demux *d = opaque; if (!d) return;
    if (d->bsf) p_bsf_free(&d->bsf);
    if (d->filtered) p_packet_free(&d->filtered);
    if (d->swr) p_swr_free(&d->swr);
    if (d->frame) p_frame_free(&d->frame);
    if (d->audio) p_free_context(&d->audio);
    free(d->pcm);
    p_packet_free(&d->packet); p_close(&d->format); free(d);
}

int jf_demux_stream_count(void *opaque) { return ((struct jf_demux *)opaque)->format->nb_streams; }

/// Frame rate of a video stream as a rational. The pipeline wants to be told
/// this; left out, it assumes whatever the load payload's maxFrameRate says.
int jf_demux_video_fps(void *opaque, int index, int *num, int *den) {
    struct jf_demux *d = opaque;
    if (index < 0 || index >= (int)d->format->nb_streams) return 0;
    AVStream *st = d->format->streams[index];
    AVRational fps = st->avg_frame_rate.num ? st->avg_frame_rate : st->r_frame_rate;
    if (fps.num <= 0 || fps.den <= 0) return 0;
    *num = fps.num;
    *den = fps.den;
    return 1;
}
int jf_demux_stream(void *opaque, int index, int *kind, int *codec, int *width, int *height) {
    struct jf_demux *d = opaque;
    if (index < 0 || index >= (int)d->format->nb_streams) return 0;
    AVCodecParameters *p = d->format->streams[index]->codecpar;
    *kind = p->codec_type; *codec = p->codec_id; *width = p->width; *height = p->height;
    return 1;
}
/// Route this video stream through a bitstream filter when the container
/// stores it length-prefixed (an AVCC/HVCC extradata block starts with 1).
/// Elementary-stream containers already carry start codes and need none.
int jf_demux_video_open(void *opaque, int index) {
    struct jf_demux *d = opaque;
    d->video_index = index;
    if (d->bsf) p_bsf_free(&d->bsf);
    if (!p_bsf_by_name || index < 0 || index >= (int)d->format->nb_streams) return 0;
    AVCodecParameters *par = d->format->streams[index]->codecpar;
    if (par->extradata_size < 1 || par->extradata[0] != 1) return 0;
    const char *name = par->codec_id == AV_CODEC_ID_H264   ? "h264_mp4toannexb"
                       : par->codec_id == AV_CODEC_ID_HEVC ? "hevc_mp4toannexb"
                                                           : 0;
    const AVBitStreamFilter *filter = name ? p_bsf_by_name(name) : 0;
    if (!filter || p_bsf_alloc(filter, &d->bsf) < 0) return 0;
    if (!d->filtered) d->filtered = p_packet_alloc();
    if (!d->filtered || p_parameters_copy(d->bsf->par_in, par) < 0 || p_bsf_init(d->bsf) < 0) {
        p_bsf_free(&d->bsf);
        return 0;
    }
    return 1;
}

/// Point the handle at a different URL, keeping the handle itself. A server
/// that transcodes on the fly serves no byte ranges, so seeking such a stream
/// means asking the server for it again from a different offset.
int jf_demux_reopen(void *opaque, const char *url) {
    struct jf_demux *d = opaque;
    // Before the context goes: the packet still references buffers it owns.
    p_packet_unref(d->packet);
    if (d->bsf) p_bsf_free(&d->bsf);
    if (d->swr) p_swr_free(&d->swr);
    if (d->frame) p_frame_free(&d->frame);
    if (d->audio) p_free_context(&d->audio);
    d->pcm_size = 0;
    p_close(&d->format);
    if (p_open(&d->format, url, 0, 0) < 0) return 0;
    return p_info(d->format, 0) >= 0;
}

/// Move the source to the keyframe at or before position_ns. Stream index -1
/// means the timestamp is in AV_TIME_BASE units, i.e. microseconds.
int jf_demux_seek(void *opaque, int64_t position_ns) {
    struct jf_demux *d = opaque;
    if (!p_seek) return 0;
    if (p_seek(d->format, -1, position_ns / 1000, AVSEEK_FLAG_BACKWARD) < 0) return 0;
    if (d->audio && p_flush_buffers) p_flush_buffers(d->audio);
    if (d->bsf && p_bsf_flush) p_bsf_flush(d->bsf);
    d->pcm_size = 0;
    return 1;
}

int jf_demux_next(void *opaque, uint8_t **data, int *size, int *stream, int64_t *pts) {
    struct jf_demux *d = opaque;
    for (;;) {
        p_packet_unref(d->packet);
        if (p_read(d->format, d->packet) < 0) return 0;
        AVPacket *out = d->packet;
        if (d->bsf && d->packet->stream_index == d->video_index) {
            // send_packet takes the input; receive can want another one first.
            if (p_bsf_send(d->bsf, d->packet) < 0) continue;
            p_packet_unref(d->filtered);
            if (p_bsf_receive(d->bsf, d->filtered) < 0) continue;
            d->filtered->stream_index = d->video_index;
            out = d->filtered;
        }
        *data = out->data; *size = out->size; *stream = out->stream_index;
        if (out->pts == AV_NOPTS_VALUE) *pts = 0;
        else {
            AVRational time_base = d->format->streams[*stream]->time_base;
            *pts = out->pts * (int64_t)time_base.num * 1000000000LL / time_base.den;
        }
        return 1;
    }
}
