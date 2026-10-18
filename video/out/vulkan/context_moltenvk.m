/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Contains code from edde746/MPVKit at b8b922ec, whose repository license at
 * that revision was LGPL-3.0, and changes by Quasar (2026). This file as a
 * whole is distributed under the GNU LGPL version 3; see
 * quasar/AVFOUNDATION_CREDITS.md.
 */

#include <CoreGraphics/CoreGraphics.h>
#include <QuartzCore/CAMetalLayer.h>
#include <QuartzCore/CATransaction.h>
#include <MoltenVK/mvk_vulkan.h>
#include <limits.h>
#include <math.h>

#include "common.h"
#include "context.h"
#include "utils.h"

struct priv {
    struct mpvk_ctx vk;
    CAMetalLayer *layer;
    int last_successful_width;
    int last_successful_height;
};

static void moltenvk_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    ra_vk_ctx_uninit(ctx);
    mpvk_uninit(&p->vk);
}

static bool moltenvk_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    struct mpvk_ctx *vk = &p->vk;
    int msgl = ctx->opts.probing ? MSGL_V : MSGL_ERR;

    if (ctx->vo->opts->WinID == -1) {
        MP_MSG(ctx, msgl, "WinID missing\n");
        goto fail;
    }

    if (!mpvk_init(vk, ctx, VK_EXT_METAL_SURFACE_EXTENSION_NAME))
        goto fail;

    p->layer = (__bridge CAMetalLayer *)(intptr_t)ctx->vo->opts->WinID;
    VkMetalSurfaceCreateInfoEXT info = {
         .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
         .pLayer = p->layer,
    };

    struct ra_ctx_params params = {0};

    VkInstance inst = vk->vkinst->instance;
    VkResult res = vkCreateMetalSurfaceEXT(inst, &info, NULL, &vk->surface);
    if (res != VK_SUCCESS) {
        MP_MSG(ctx, msgl, "Failed creating MoltenVK surface\n");
        goto fail;
    }

    if (!ra_vk_ctx_init(ctx, vk, params, VK_PRESENT_MODE_FIFO_KHR))
        goto fail;

    return true;
fail:
    moltenvk_uninit(ctx);
    return false;
}

static bool size_to_extent(CGSize size, int *width, int *height)
{
    double rounded_width = size.width - remainder(size.width, 1.0);
    double rounded_height = size.height - remainder(size.height, 1.0);
    if (!isfinite(rounded_width) || !isfinite(rounded_height) ||
        rounded_width <= 1 || rounded_height <= 1 ||
        rounded_width > INT_MAX || rounded_height > INT_MAX)
        return false;

    *width = (int)rounded_width;
    *height = (int)rounded_height;
    return true;
}

static bool resize_swapchain(struct ra_ctx *ctx, int width, int height)
{
    // The VO thread has no UI run loop to commit an implicit transaction.
    // Publish the replacement drawable pool and its layer state together.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    bool resized = ra_vk_ctx_resize(ctx, width, height);
    [CATransaction commit];
    return resized;
}

static bool moltenvk_reconfig(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    int rollback_width = p->last_successful_width;
    int rollback_height = p->last_successful_height;

    int width = ctx->vo->opts->android_surface_size.w;
    int height = ctx->vo->opts->android_surface_size.h;

    if (width <= 1 || height <= 1) {
        CGSize previous_size = p->layer.drawableSize;
        if (!size_to_extent(previous_size, &width, &height))
            return false;
    }

    // libplacebo retires the old swapchain with its in-flight work. Draining
    // the entire GPU here stalls playback at every live-resize update.
    // MoltenVK installs drawableSize with the replacement swapchain.
    if (resize_swapchain(ctx, width, height) &&
        ctx->vo->dwidth == width && ctx->vo->dheight == height)
    {
        p->last_successful_width = ctx->vo->dwidth;
        p->last_successful_height = ctx->vo->dheight;
        return true;
    }

    // Roll back at same native boundary; host drawableSize writes can race
    // active Vulkan swapchain.
    if (rollback_width > 1 && rollback_height > 1) {
        if (!resize_swapchain(ctx, rollback_width, rollback_height)) {
            MP_WARN(ctx, "Failed restoring MoltenVK swapchain to %dx%d\n",
                    rollback_width, rollback_height);
            ctx->vo->dwidth = p->last_successful_width;
            ctx->vo->dheight = p->last_successful_height;
        } else {
            p->last_successful_width = ctx->vo->dwidth;
            p->last_successful_height = ctx->vo->dheight;
            if (ctx->vo->dwidth == width && ctx->vo->dheight == height)
                return true;

            MP_WARN(ctx, "MoltenVK resize to %dx%d failed; restored %dx%d\n",
                    width, height, ctx->vo->dwidth, ctx->vo->dheight);
        }
    }
    return false;
}

static int moltenvk_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    return VO_NOTIMPL;
}

const struct ra_ctx_fns ra_ctx_vulkan_moltenvk = {
    .type           = "vulkan",
    .name           = "moltenvk",
    .reconfig       = moltenvk_reconfig,
    .control        = moltenvk_control,
    .init           = moltenvk_init,
    .uninit         = moltenvk_uninit,
};
