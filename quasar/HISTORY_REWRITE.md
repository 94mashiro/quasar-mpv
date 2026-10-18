# 2026-10-18 历史改写

首次公开前，用 `git filter-branch` 改写了 `41f6a645..main`：只删掉注释里提到的另一款播放器名，另外 `0021` 的提交说明改了一句。代码、作者、日期都没变。改写前后逐个提交核对过，差异只有这几行注释。

所以 quasar-app 在改写之前钉的提交，在公开仓库里不存在。要构建那些旧版本，用下表换成对应的新提交（两边编出来的二进制一样）；旧提交只留在本机的 `backup/pre-scrub` 分支和 `pin/2026-10-18-0` tag，不推远端。`pin/2026-10-18-1` 到 `-5` 已重打在新提交上，tag 说明里提到的 quasar-app 提交，钉的是对应的旧号。

| 旧提交 | 新提交 | 标题 |
| --- | --- | --- |
| `8efba35` | `cb696c9` | 0001-moltenvk-embedding |
| `685ebc0` | `ca1662b` | 0002-apple-audio-portability |
| `d29679c` | `5cac298` | 0003-text-subtitle-interception |
| `78a7045` | `2f25402` | 0004-swift-object-build |
| `641a60e` | `83e7441` | 0005-avfoundation-native-video |
| `4f8ee62` | `f4e2678` | 0006-avfoundation-compressed-audio: avfoundation: compressed audio opt-in; per-player recovery |
| `317dae6` | `45502af` | 0007-native-dolby-vision-compatibility: Native P7 opt-in; strict sample checks |
| `ec698e7` | `c04726f` | 0008-bounded-hardware-decoder-recovery: Bound native HEVC recovery; honor fallback options |
| `b690192` | `9f304b3` | 0009-native-hdr-color-metadata |
| `59ba525` | `de36292` | 0010-apple-rendering-quality |
| `b36c09e` | `8a17e8a` | 0011-native-subtitle-image-cache |
| `c674a47` | `0f612f5` | 0012-text-subtitle-queries: Query complete text subtitle tracks and notify paused cue updates |
| `8f4d6d0` | `f96d6ec` | 0013-subtitle-roles: Preserve subtitle track identity and live selection role |
| `70cb979` | `eb76be7` | 0014-webp-animation-duration |
| `d11c928` | `ac6012e` | 0015-apple-spatial-audio: Apple spatial audio eligibility, session ownership and diagnostics |
| `346f695` | `ae5a5f7` | 0016-native-audio-clock-wakeup |
| `de5967f` | `447b3e5` | 0017-track-switch-buffering: Preserve buffered playback during audio and subtitle refresh seeks |
| `09d65f2` | `1c322a9` | 0018-simulator-frame-upload: Copy software frame uploads on Apple simulators |
| `6b76701` | `fd22536` | 0019-avfoundation-buffer-reuse-and-subtitle-compositing: avfoundation: reuse frame buffers and streamline subtitle compositing |
| `32298c7` | `fc08f88` | 0020-unavailable-pixel-aspect-ratio: player: omit unavailable pixel aspect ratios |
| `3d5c21c` | `a77606a` | 0021-quasar-dovi-subtitle-layer: avfoundation: draw subtitles on a separate EDR layer for Dolby Vision |
| `25529b4` | `ced74d6` | 0022-quasar-hdr-vivid: avfoundation: map HDR Vivid frames to the display peak |
| `ef3da7f` | `0de8bda` | 0023-quasar-dovi-fel: Dolby Vision Profile 7: decode the FEL and compose it in the native output |
| `5a44aed` | `2aa0824` | docs: 仓库说明和 AVFoundation 代码的出处、许可 |
| `5ed579e` | `87dc883` | refactor(vo_avfoundation): 按职责拆成 5 个源文件和一个共享头，只搬代码 |
| `af95503` | `4ca60c2` | refactor(vo_avfoundation): 第一轮审查的问题 |
| `4ddc912` | `d978724` | refactor(vo_avfoundation): verify.py 第二轮审查的问题 |
| `9c70316` | `8c8f66c` | refactor(ao_avfoundation): 压缩音频的 AVPlayer 旁路拆到单独文件，只搬代码 |
| `8e8e9e8` | `168576c` | docs(refactor): 写明 ao_split.py 只用一次、升级时 priv.h 的冲突 |
