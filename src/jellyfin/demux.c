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
    // Audio is decoded here: NDL DirectMedia only takes PCM, MP3 or Opus, and
    // its MP3 path never builds an audio pipeline on this TV.
    AVCodecContext *audio;
    AVFrame *frame;
    struct SwrContext *swr;
    uint8_t *pcm;
    int pcm_cap, pcm_size;
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
/// stream's own rate; NDL takes nothing else. 1 on success.
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
int jf_demux_next(void *opaque, uint8_t **data, int *size, int *stream, int64_t *pts) {
    struct jf_demux *d = opaque; p_packet_unref(d->packet);
    if (p_read(d->format, d->packet) < 0) return 0;
    *data = d->packet->data; *size = d->packet->size; *stream = d->packet->stream_index;
    if (d->packet->pts == AV_NOPTS_VALUE) *pts = 0;
    else {
        AVRational time_base = d->format->streams[*stream]->time_base;
        *pts = d->packet->pts * (int64_t)time_base.num * 1000000000LL / time_base.den;
    }
    return 1;
}
