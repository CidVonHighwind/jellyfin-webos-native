// Access the segment controls exposed by libpf's CustomPipeline. They are not
// forwarded by StarfishMediaAPIs, but its documented `player` member leads to
// the same CustomPlayer/CustomPipeline objects used by spool-mpv.
//
// The bridge intentionally uses only the ARM C ABI. This avoids linking a C++
// runtime or compiling a different Boost implementation into the application.
// boost::shared_ptr is two pointers. getPipeline() returns a temporary owner;
// its extra reference is dropped below with the same atomic operation used by
// Boost's inline shared_count destructor.
#include <dlfcn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

typedef enum {
    MEDIA_CUSTOM_SRC_TYPE_ES = 7,
} MEDIA_CUSTOM_SRC_TYPE_T;

typedef struct MEDIA_CUSTOM_CONTENT_INFO {
    int32_t mediaTransportType;
    int32_t mediaSourceType;
    int32_t container;
    uint64_t size;
    uint32_t videoCodec;
    uint32_t audioCodec;
    int32_t esCh;
    int64_t ptsToDecode;
    int32_t restartStreaming;
    int32_t separatedPTS;
    uint8_t svpVersion;
    int32_t preBufferTime;
    int32_t useBufferCtrl;
    int32_t userBufferCtrl;
    int32_t bufferingMinTime;
    int32_t bufferingMaxTime;
    uint8_t bufferMinPercent;
    uint8_t bufferMaxPercent;
    uint8_t padding[2];
    uint8_t videoDataInfo[104];
    uint8_t audioDataInfo[56];
    uint16_t unknown;
    uint32_t delayOffset;
    uint32_t drmType;
    char *drmTypeExtension;
    char *drmClientID;
    uint32_t startBPS;
    uint32_t unknown2;
    uint32_t unknown3;
    int32_t unknown4;
    int32_t unknown5;
    uint32_t startTime;
    uint8_t unknown6[20];
    int32_t unknown7;
} MEDIA_CUSTOM_CONTENT_INFO_T;

typedef struct {
    void *object;
    void *control;
} boost_shared_ptr_abi;

#if UINTPTR_MAX == UINT32_MAX
_Static_assert(sizeof(boost_shared_ptr_abi) == 8,
               "unexpected webOS boost::shared_ptr ABI");
_Static_assert(offsetof(MEDIA_CUSTOM_CONTENT_INFO_T, ptsToDecode) == 40,
               "unexpected MEDIA_CUSTOM_CONTENT_INFO ptsToDecode offset");
_Static_assert(offsetof(MEDIA_CUSTOM_CONTENT_INFO_T, separatedPTS) == 52,
               "unexpected MEDIA_CUSTOM_CONTENT_INFO separatedPTS offset");
_Static_assert(sizeof(MEDIA_CUSTOM_CONTENT_INFO_T) == 312,
               "unexpected MEDIA_CUSTOM_CONTENT_INFO size");
#endif

// A non-trivial C++ return uses a hidden result pointer before `this` on the
// TV's ARM EABI, the same convention already used for Starfish Feed's string.
typedef void (*get_pipeline_fn)(boost_shared_ptr_abi *result, const void *player);
typedef bool (*get_info_fn)(void *pipeline, MEDIA_CUSTOM_CONTENT_INFO_T *info);
typedef void (*set_info_fn)(void *pipeline, MEDIA_CUSTOM_SRC_TYPE_T type,
                            MEDIA_CUSTOM_CONTENT_INFO_T *info);
typedef void (*send_segment_fn)(void *pipeline);

struct segment_symbols {
    get_pipeline_fn getPipeline;
    get_info_fn getInfo;
    set_info_fn setInfo;
    send_segment_fn sendSegment;
};

static struct segment_symbols symbols;
static bool symbols_attempted;
static const char *segment_error = "segment bridge has not run";

static bool resolve_segment_symbols(void)
{
    if (symbols_attempted)
        return symbols.getPipeline && symbols.getInfo && symbols.setInfo &&
               symbols.sendSegment;
    symbols_attempted = true;

    void *lib = dlopen("libpf-1.0.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!lib)
        lib = dlopen("libpf-1.0.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        segment_error = "could not open libpf-1.0";
        return false;
    }

    *(void **)(&symbols.getPipeline) =
        dlsym(lib, "_ZNK13mediapipeline14AbstractPlayer11getPipelineEv");
    *(void **)(&symbols.getInfo) =
        dlsym(lib, "_ZN13mediapipeline14CustomPipeline15loadSpi_getInfoEP25MEDIA_CUSTOM_CONTENT_INFO");
    *(void **)(&symbols.setInfo) =
        dlsym(lib, "_ZN13mediapipeline14CustomPipeline14setContentInfoE23MEDIA_CUSTOM_SRC_TYPE_TP25MEDIA_CUSTOM_CONTENT_INFO");
    *(void **)(&symbols.sendSegment) =
        dlsym(lib, "_ZN13mediapipeline14CustomPipeline16sendSegmentEventEv");
    if (!symbols.getPipeline)
        segment_error = "libpf lacks AbstractPlayer::getPipeline";
    else if (!symbols.getInfo)
        segment_error = "libpf lacks CustomPipeline::loadSpi_getInfo";
    else if (!symbols.setInfo)
        segment_error = "libpf lacks CustomPipeline::setContentInfo";
    else if (!symbols.sendSegment)
        segment_error = "libpf lacks CustomPipeline::sendSegmentEvent";
    else {
        segment_error = "";
        return true;
    }
    return false;
}

// Boost keeps two 32-bit counters immediately after sp_counted_base's vptr.
// This layout and the __atomic fetch-sub implementation are stable across the
// Boost versions used by webOS. We only release the temporary getPipeline()
// copy while Starfish's player still owns the same pipeline, so the count must
// be at least two and no virtual dispose/destroy call can be needed. Refuse an
// unexpected layout/count instead of modifying unknown memory.
static bool release_pipeline_copy(boost_shared_ptr_abi *owner,
                                  uint32_t *before, uint32_t *after)
{
    if (!owner->control) {
        *before = 0;
        *after = 0;
        return true;
    }

    uint32_t *use_count =
        (uint32_t *)((uint8_t *)owner->control + sizeof(void *));
    uint32_t observed = __atomic_load_n(use_count, __ATOMIC_ACQUIRE);
    *before = observed;
    while (observed >= 2 && observed < (1U << 20)) {
        const uint32_t desired = observed - 1;
        if (__atomic_compare_exchange_n(use_count, &observed, desired, true,
                                        __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            *after = desired;
            owner->object = NULL;
            owner->control = NULL;
            return true;
        }
    }
    *after = observed;
    return false;
}

bool jf_starfish_begin_segment(void *opaque, int64_t pts_ns)
{
    if (!opaque) {
        segment_error = "StarfishMediaAPIs instance is null";
        return false;
    }
    if (sizeof(void *) != 4) {
        segment_error = "segment bridge requires the 32-bit webOS ABI";
        return false;
    }
    if (!resolve_segment_symbols())
        return false;

    // StarfishMediaAPIs.h: 76 opaque bytes, then the public player shared_ptr.
    // This is the 32-bit ARM TV ABI; the host test binary never calls here.
    const boost_shared_ptr_abi *player_owner =
        (const boost_shared_ptr_abi *)((const uint8_t *)opaque + 76);
    if (!player_owner->object) {
        segment_error = "Starfish player is null after load";
        return false;
    }

    boost_shared_ptr_abi pipeline_owner = {0};
    symbols.getPipeline(&pipeline_owner, player_owner->object);
    // Keep the non-owning pointer. Starfish's player holds the lifetime for
    // the whole serialized call and for the subsequent playback session.
    void *pipeline = pipeline_owner.object;
    uint32_t refs_before = 0;
    uint32_t refs_after = 0;
    if (!release_pipeline_copy(&pipeline_owner, &refs_before, &refs_after)) {
        fprintf(stderr,
                "Starfish segment: unexpected shared_ptr refcount=%u\n",
                refs_before);
        segment_error = "unexpected Boost shared_ptr control block";
        return false;
    }
    if (!pipeline) {
        segment_error = "Starfish CustomPipeline is null after load";
        return false;
    }

    MEDIA_CUSTOM_CONTENT_INFO_T info;
    memset(&info, 0, sizeof(info));
    bool ok = symbols.getInfo(pipeline, &info);
    if (ok) {
        const int64_t previous_pts = info.ptsToDecode;
        const int32_t previous_separated_pts = info.separatedPTS;
        info.ptsToDecode = pts_ns;
        // The JSON key is misspelled by libpf ("seperatedPTS") and is not
        // reflected in every firmware's loadSpi_getInfo result. Raw ES feeds
        // require this field in the segment descriptor itself so video and
        // PCM retain their independent presentation timestamps.
        info.separatedPTS = 1;
        symbols.setInfo(pipeline, MEDIA_CUSTOM_SRC_TYPE_ES, &info);
        symbols.sendSegment(pipeline);
        fprintf(stderr,
                "Starfish segment: previous=%lldns target=%lldns "
                "separatedPTS=%d->%d refs=%u->%u\n",
                (long long)previous_pts, (long long)pts_ns,
                previous_separated_pts, info.separatedPTS,
                refs_before, refs_after);
        segment_error = "";
    } else {
        fprintf(stderr, "Starfish segment: loadSpi_getInfo returned false\n");
        segment_error = "CustomPipeline::loadSpi_getInfo rejected the pipeline";
    }
    return ok;
}

const char *jf_starfish_segment_error(void)
{
    return segment_error;
}
