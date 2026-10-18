# vo_avfoundation.m 拆分（2026-10-18）

只搬代码：`split.py` 按「声明起始行 → 目标文件」的表把拆分前的 `video/out/vo_avfoundation.m` 切开，上方紧挨的注释随声明走；跨文件调用的 static 函数去掉 static、补 `avf_` 前缀并在 `vo_avfoundation_priv.h` 里声明；格式判断、时间换算等小函数改成头文件里的 `static inline`。

复查：

```sh
git show <拆分前的提交>:video/out/vo_avfoundation.m > /tmp/vo_orig.m
python3 quasar/refactor/verify.py /tmp/vo_orig.m .     # 每段原文只经改名和 static/inline 调整后原样出现，新文件无额外代码
python3 quasar/refactor/vo_compile.py .                # 用上次 mpvbuild 构建的参数编译 video/out/*avfoundation*.m，检查跨文件符号
```

`plan.json` 是这次的分段和改名表。`split.py` 只适用于拆分前的那份文件，留作记录。
