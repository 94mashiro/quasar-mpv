#ifndef MP_AV_LOG_H
#define MP_AV_LOG_H

#include <stdbool.h>

struct mpv_global;
struct mp_log;
void init_libav(struct mpv_global *global);
// Route structured decoder diagnostics to their owning libmpv instance.
// opaque is copied into FFmpeg frame-worker contexts. Unregister after closing
// the codec, once all workers and callbacks have joined.
void mp_av_log_register_decoder(void *opaque, struct mpv_global *global);
void mp_av_log_unregister_decoder(void *opaque);
void uninit_libav(struct mpv_global *global);
void check_library_versions(struct mp_log *log, int v);
#endif
