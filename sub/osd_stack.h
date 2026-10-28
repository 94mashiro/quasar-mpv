#ifndef MP_OSD_STACK_H_
#define MP_OSD_STACK_H_

// --secondary-sub-stack 的纯计算部分：只看位图的竖直区间，不依赖 mpv 的其他头文件，
// 主机测试直接 include 这个文件。

#include <limits.h>
#include <stdbool.h>

// 一个位图 part 的竖直区间 [y0, y1)
struct osd_stack_span {
    int y0, y1;
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

// 同一条主字幕显示期间保持副字幕区间，供 osd_stack_lift 当副字幕用：same_pri 为真时把这一帧的副字幕
// 区间并进 held，为假时 held 只取这一帧的。副字幕先消失或换成矮的一句，held 不缩，主字幕不回落。
// held 为空时 y0 > y1；osd_stack_hold_num() 给出传给 osd_stack_lift 的 num_sec（0 或 1）。
static inline void osd_stack_hold(struct osd_stack_span *held, bool same_pri,
                                  const struct osd_stack_span *sec, int num_sec)
{
    if (!same_pri)
        *held = (struct osd_stack_span){INT_MAX, INT_MIN};
    for (int n = 0; n < num_sec; n++) {
        held->y0 = sec[n].y0 < held->y0 ? sec[n].y0 : held->y0;
        held->y1 = sec[n].y1 > held->y1 ? sec[n].y1 : held->y1;
    }
}

static inline int osd_stack_hold_num(const struct osd_stack_span *held)
{
    return held->y0 <= held->y1;
}

#endif
