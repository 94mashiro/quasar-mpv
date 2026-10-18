# quasar-mpv

Quasar 苹果端 libmpv 的 mpv 源码：mpv v0.41.0（`upstream` 远端，提交 `41f6a645`）的 fork。`main` 上基线之后的每个提交原是一个补丁，提交说明写了出处（LePips/MPVUI 的补丁，或 quasar-app 原来的 `libmpv-patches/mpv/`）。

| 规则 | 谁来挡住 |
| --- | --- |
| 这里不编译。quasar-app 的 `iosApp/tool/build_libmpv.sh` 按其中的 `QUASAR_MPV_COMMIT` 取这里的代码，生成一个补丁交给 mpvbuild。改完在这里提交，再到 quasar-app 更新 `QUASAR_MPV_COMMIT`、重编、真机验证，按 quasar-app 的流程审查合入 | 判断 |
| 构建是 `-Dgpl=false`。不引入只能按 GPL 用的代码 | quasar-app 的 `build_libmpv.sh` 检查 `HAVE_GPL 0` |
| edde746/MPVKit 的代码只用到 `b8b922ec` 为止（LGPL-3.0），之后的版本是 GPL-3.0-only，不再拿。出处和许可全文在 `quasar/` | 判断 |
| `quasar/` 和本文件不进构建（生成补丁时排除） | `build_libmpv.sh` |
| quasar-app 钉的每个提交都打 tag `pin/<日期>-<序号>`，例如 `pin/2026-10-18-1`。rebase、amend 之后旧提交只靠 tag 留住，quasar-app 的旧版本才还能构建。2026-10-18 改写过一次历史，旧→新提交对照见 `quasar/HISTORY_REWRITE.md`；推 tag 时只点名推 `pin/*`，不要 `git push --tags`（本地 `pin/2026-10-18-0` 是改写前的）。`origin` 是 GitHub 上的公开仓库 `94mashiro/quasar-mpv`（上游的 fork），推 `main` 和 `pin/*` tag | 判断 |
| 升级 mpv：本仓库是浅克隆，基线 `41f6a645` 没有父提交。`git fetch --depth=1 upstream <新标签>`，再 `git rebase --onto <新标签的提交> 41f6a645 main`；quasar-app 那边同时改 `iosApp/tool/quasar_mpv.sh` 的 `QUASAR_MPV_BASE`，并升级 `build_libmpv.sh` 的 MPVUI `COMMIT`（或让脚本改写锁文件里 mpv 的 commit 和 version），否则脚本里的基线核对会失败 | 判断 |
