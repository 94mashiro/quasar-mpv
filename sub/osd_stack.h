#ifndef MP_OSD_STACK_H_
#define MP_OSD_STACK_H_

// --secondary-sub-stack 的纯计算部分：只看位图的竖直区间，不依赖 mpv 的其他头文件，
// 主机测试直接 include 这个文件。

#include <limits.h>
#include <stdbool.h>
#include <string.h>

// 一个位图 part 的竖直区间 [y0, y1)。x0/x1 是水平区间，只在 osd_stack_frame 判断是不是同一句时用
struct osd_stack_span {
    int y0, y1, x0, x1;
};

// 算主字幕贴底那一簇要上移多少像素（>= 0），簇里的 part 在 lift[] 里标 true。
// 簇的起点是和副字幕竖直区间 [副字幕顶 - gap, 副字幕底) 相交的主字幕 part，
// 再把离簇不到 join 像素的 part 并进来，直到不再增加；离得远的（顶部标牌等）不动。
// 上移后簇底在副字幕顶上方 gap 像素处，但簇顶不越过画面顶（libass 位图必须在画面内）。
// 任一边为空或没冲突时返回 0，lift[] 全为 false。
static inline int osd_stack_lift(const struct osd_stack_span *pri, int num_pri,
                                 const struct osd_stack_span *sec, int num_sec,
                                 int gap, int join, bool *lift)
{
    for (int n = 0; n < num_pri; n++)
        lift[n] = false;
    if (!num_pri || !num_sec)
        return 0;

    int sec_top = INT_MAX, sec_bottom = INT_MIN;
    for (int n = 0; n < num_sec; n++) {
        sec_top = sec[n].y0 < sec_top ? sec[n].y0 : sec_top;
        sec_bottom = sec[n].y1 > sec_bottom ? sec[n].y1 : sec_bottom;
    }

    int top = INT_MAX, bottom = INT_MIN;
    // ponytail: 每轮扫全部 part，最坏 O(n²)；libass 一帧几百个 part 以内，慢了再按 y 排序
    for (bool grew = true; grew;) {
        grew = false;
        for (int n = 0; n < num_pri; n++) {
            if (lift[n])
                continue;
            bool hit = (pri[n].y1 > sec_top - gap && pri[n].y0 < sec_bottom) ||
                       (top <= bottom && pri[n].y1 > top - join &&
                        pri[n].y0 < bottom + join);
            if (!hit)
                continue;
            lift[n] = grew = true;
            top = pri[n].y0 < top ? pri[n].y0 : top;
            bottom = pri[n].y1 > bottom ? pri[n].y1 : bottom;
        }
    }
    if (top > bottom)
        return 0;

    int dy = bottom - (sec_top - gap);
    if (dy > top)
        dy = top;
    return dy > 0 ? dy : 0;
}

// 叠放的保持状态：held 是这一句主字幕显示期间副字幕竖直区间的并集，box 是上一帧主字幕
// 贴底那一簇抬起前的外包框。valid 为假时下一帧重新开始（换轨、seek、关叠放、没有主字幕）。
struct osd_stack_hold {
    bool valid;
    struct osd_stack_span held, box;
};

static inline void osd_stack_union(struct osd_stack_span *a, const struct osd_stack_span *b)
{
    a->y0 = b->y0 < a->y0 ? b->y0 : a->y0;
    a->y1 = b->y1 > a->y1 ? b->y1 : a->y1;
    a->x0 = b->x0 < a->x0 ? b->x0 : a->x0;
    a->x1 = b->x1 > a->x1 ? b->x1 : a->x1;
}

// 一帧的叠放位移，参数和返回值同 osd_stack_lift。先当作还是同一句，用 held 并上这一帧的副字幕
// 算出要抬的簇；簇的外包框和上一帧一样就是同一句，held 留着并集，副字幕先结束或变矮主字幕也不回落。
// 框变了（换句、行数或宽度变）就只按这一帧的副字幕重算。只比几何不比内容：\fad 淡入淡出、
// \k 卡拉 OK 只改颜色、透明度或把一行拆成几段，框不变。
static inline int osd_stack_frame(struct osd_stack_hold *st,
                                  const struct osd_stack_span *pri, int num_pri,
                                  const struct osd_stack_span *sec, int num_sec,
                                  int gap, int join, bool *lift)
{
    const struct osd_stack_span empty = {INT_MAX, INT_MIN, INT_MAX, INT_MIN};
    struct osd_stack_span held = st->valid ? st->held : empty;
    for (int pass = 0;; pass++) {
        for (int n = 0; n < num_sec; n++)
            osd_stack_union(&held, &sec[n]);
        int dy = osd_stack_lift(pri, num_pri, &held, held.y0 <= held.y1,
                                gap, join, lift);
        struct osd_stack_span box = empty;
        for (int n = 0; n < num_pri; n++) {
            if (lift[n])
                osd_stack_union(&box, &pri[n]);
        }
        if (pass || (st->valid && !memcmp(&box, &st->box, sizeof(box)))) {
            *st = (struct osd_stack_hold){true, held, box};
            return dy;
        }
        held = empty;
    }
}

#endif
