# vo_avfoundation.m 拆分（2026-10-18）

只搬代码：`split.py` 按「声明起始行 → 目标文件」的表把拆分前的 `video/out/vo_avfoundation.m` 切开，上方紧挨的注释随声明走；跨文件调用的 static 函数去掉 static、补 `avf_` 前缀并在 `vo_avfoundation_priv.h` 里声明；格式判断、时间换算等小函数改成头文件里的 `static inline`。

复查：

```sh
git show <拆分前的提交>:video/out/vo_avfoundation.m > /tmp/vo_orig.m
python3 quasar/refactor/verify.py /tmp/vo_orig.m .     # 每段原文只经改名和 static/inline 调整后原样出现，新文件无额外代码
python3 quasar/refactor/vo_compile.py .                # 用上次 mpvbuild 构建的参数编译 video/out/*avfoundation*.m，检查跨文件符号
```

`plan.json` 是这次的分段和改名表。`split.py` 只适用于拆分前的那份文件，留作记录。

# ao_avfoundation.m 拆分（2026-10-18）

同样只搬代码：`ao_split.py` 把压缩音频的 AVPlayer 旁路（IEC 61937 解包、ES 窗口、资源加载器 `AVPLoader`、起播和卡顿监督、时钟发布）切到 `audio/out/ao_avfoundation_avplayer.m`，共享的 `struct priv`、两个 `@interface`、常量和小工具放 `audio/out/ao_avfoundation_priv.h`，跨文件的 5 个函数补 `ao_avf_` 前缀。PCM 路径、会话和 ao_driver 回调留在 `ao_avfoundation.m`：两条路径在回调里用 `if (p->spdif)` 写在同一个函数里，只搬代码拆不开。

```sh
git show <拆分前的提交>:audio/out/ao_avfoundation.m > /tmp/ao_orig.m
python3 quasar/refactor/ao_verify.py /tmp/ao_orig.m .
python3 quasar/refactor/vo_compile.py . ao
```
