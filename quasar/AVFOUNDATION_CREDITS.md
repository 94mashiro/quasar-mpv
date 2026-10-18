# AVFoundation credits and licenses

This repository is mpv v0.41.0 (upstream `41f6a645`) with patches for Quasar's Apple player. Every change is a commit after `41f6a645`; each import commit names the patch it came from. Quasar modified this code in 2026; `git log 41f6a645..` is the record of what changed and when.

## Where the AVFoundation code comes from

- Alex Kim wrote the original AVFoundation video output under mpv's LGPL-2.1-or-later header ([MPVKit patch 0004](https://github.com/edde746/MPVKit/blob/b8b922ec74b84ac3a496e29e226a3a3e91491045/Sources/BuildScripts/patch/libmpv/0004-avfoundation-video-output.patch)). That header is kept unchanged.
- edde746 (Plezy) and the MPVKit contributors (cxfksword and others) extended it, and added compressed audio passthrough, Dolby Vision handling, and hardware decoder recovery, in [edde746/MPVKit at `b8b922ec`](https://github.com/edde746/MPVKit/tree/b8b922ec74b84ac3a496e29e226a3a3e91491045). The code reached this repository through LePips/MPVUI `23ba5a72`.
- The `0021`–`0023` commits are Quasar's own work.

## License of the MPVKit code

edde746/MPVKit's `LICENSE` file has this history:

| Commit | Date (UTC) | `LICENSE` |
| --- | --- | --- |
| [`eec521ae`](https://github.com/edde746/MPVKit/blob/eec521ae/LICENSE) | 2024-07-13 | GPL-3.0 (first commit) |
| [`ca111517`](https://github.com/edde746/MPVKit/blob/ca111517/LICENSE) | 2024-08-12 | LGPL-3.0 ("docs: update LICENSE to LGPL v3.0") |
| [`b8b922ec`](https://github.com/edde746/MPVKit/blob/b8b922ec74b84ac3a496e29e226a3a3e91491045/LICENSE) | 2026-08-29 | LGPL-3.0, **the revision used here** |
| [`b9e88e80`](https://github.com/edde746/MPVKit/commit/b9e88e80657ec20ced3993c490d9e08b858d9bff) | 2026-08-30 | GPL-3.0-only ("relicense this fork to GPL-3.0-only") |

So the code taken at `b8b922ec` was published under LGPL-3.0. The change to GPL-3.0-only applies only to later work: a licensor cannot withdraw the license already granted on a published revision (LGPL-3.0 incorporates GPL-3.0 section 2, which makes the grant irrevocable). Nothing after `b8b922ec` may be taken from edde746/MPVKit.

The MPVKit patches kept mpv's LGPL-2.1-or-later file headers, but the changes were contributed to a repository licensed LGPL-3.0. Quasar takes the stricter reading: **files containing MPVKit code are distributed under LGPL-3.0**, and so is any libmpv built from this repository. LGPL-2.1-or-later files may be used under LGPL-3.0, so the rest of mpv is compatible. The [LGPL-3.0 text](AVFOUNDATION_LGPL-3.0.txt) is in this directory; mpv's own `LICENSE.LGPL` and `Copyright` are unchanged.

Files containing MPVKit code (each new file says so in its header):

- `video/out/vo_avfoundation.m`, `vo_avfoundation_priv.h`, `avfoundation_buffers.m`, `avfoundation_hdr.m`, `avfoundation_osd.m`, `avfoundation_subtitle_layer.m`
- `audio/out/ao_avfoundation_avplayer.m`, `ao_avfoundation_priv.h`
- `video/decode/hwdec_recovery.h`, `video/out/vulkan/context_moltenvk.m`
- changes to existing mpv files from commits `0001`, `0006`, and `0008`: `audio/out/ao_avfoundation.m`, `ao.c`, `ao.h`, `ao_audiounit.m`, `ao_coreaudio_chmap.c/.h`, `ao_coreaudio_utils.c/.h`, `buffer.c`, `internal.h`, `player/audio.c`, `video/decode/vd_lavc.c`, `options/options.c`, `player/command.c`, `video/out/gpu/context.c`, `video/out/vo_gpu_next.c`, `video/out/vulkan/common.h`, `video/out/vulkan/context.c`, `video/out/vo.c`, `meson.build`, `meson.options`

Quasar builds mpv with `-Dgpl=false`; no GPL-only mpv file is compiled.
