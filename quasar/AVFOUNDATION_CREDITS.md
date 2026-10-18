# AVFoundation credits and licenses

The imported native video, audio, and Dolby Vision changes come from [edde746/MPVKit at b8b922ec74b84ac3a496e29e226a3a3e91491045](https://github.com/edde746/MPVKit/tree/b8b922ec74b84ac3a496e29e226a3a3e91491045).

Alex Kim's original video driver retains its LGPL-2.1-or-later header. Plezy's changes at the pinned revision use LGPL-3.0, as recorded in the upstream [licensing notice](https://github.com/edde746/MPVKit/blob/b9e88e80657ec20ced3993c490d9e08b858d9bff/LICENSING.md). This directory includes the [LGPL-3.0 license text](AVFOUNDATION_LGPL-3.0.txt). Quasar builds mpv with `-Dgpl=false`.

In this repository the imported changes are among the commits after upstream `41f6a645` (mpv v0.41.0); each commit message names the patch it came from. The AVFoundation video, audio, and Dolby Vision changes came to MPVUI from edde746/MPVKit; other MPVUI patches and the `0021`–`0023` Quasar patches have their own origins. edde746/MPVKit relicensed its later work to GPL-3.0-only, so nothing after `b8b922ec` may be taken from it.
