/*
 * OHOS gbm stub — 所有操作返回失败/空值，配合 virglrenderer 补丁的 NULL 守卫，
 * 保证运行时永远不进入 gbm 代码路径（见同目录 gbm.h 头注释）。
 */
#include "gbm.h"

struct gbm_device *gbm_create_device(int fd)
{
    (void)fd;
    return NULL;
}

void gbm_device_destroy(struct gbm_device *gbm)
{
    (void)gbm;
}

int gbm_device_get_fd(struct gbm_device *gbm)
{
    (void)gbm;
    return -1;
}

const char *gbm_device_get_backend_name(struct gbm_device *gbm)
{
    (void)gbm;
    return "stub";
}

int gbm_device_is_format_supported(struct gbm_device *gbm,
                                   uint32_t format, uint32_t usage)
{
    (void)gbm; (void)format; (void)usage;
    return 0;
}

int gbm_get_default_device_fd(void)
{
    return -1;
}

struct gbm_bo *gbm_bo_create(struct gbm_device *gbm,
                             uint32_t width, uint32_t height,
                             uint32_t format, uint32_t flags)
{
    (void)gbm; (void)width; (void)height; (void)format; (void)flags;
    return NULL;
}

void gbm_bo_destroy(struct gbm_bo *bo)
{
    (void)bo;
}

union gbm_bo_handle gbm_bo_get_handle(struct gbm_bo *bo)
{
    union gbm_bo_handle h = { .u64 = 0 };
    (void)bo;
    return h;
}

union gbm_bo_handle gbm_bo_get_handle_for_plane(struct gbm_bo *bo, int plane)
{
    union gbm_bo_handle h = { .u64 = 0 };
    (void)bo; (void)plane;
    return h;
}

uint32_t gbm_bo_get_format(struct gbm_bo *bo)
{
    (void)bo;
    return 0;
}

uint32_t gbm_bo_get_width(struct gbm_bo *bo)
{
    (void)bo;
    return 0;
}

uint32_t gbm_bo_get_height(struct gbm_bo *bo)
{
    (void)bo;
    return 0;
}

uint32_t gbm_bo_get_stride(struct gbm_bo *bo)
{
    (void)bo;
    return 0;
}

uint32_t gbm_bo_get_stride_for_plane(struct gbm_bo *bo, int plane)
{
    (void)bo; (void)plane;
    return 0;
}

uint32_t gbm_bo_get_offset(struct gbm_bo *bo, int plane)
{
    (void)bo; (void)plane;
    return 0;
}

uint32_t gbm_bo_get_plane_count(struct gbm_bo *bo)
{
    (void)bo;
    return 0;
}

uint64_t gbm_bo_get_modifier(struct gbm_bo *bo)
{
    (void)bo;
    return 0;
}

uint32_t gbm_bo_get_plane_size(struct gbm_bo *bo, int plane)
{
    (void)bo; (void)plane;
    return 0;
}

int gbm_bo_get_fd(struct gbm_bo *bo)
{
    (void)bo;
    return -1;
}

struct gbm_device *gbm_bo_get_device(struct gbm_bo *bo)
{
    (void)bo;
    return NULL;
}

void *gbm_bo_map(struct gbm_bo *bo, uint32_t x, uint32_t y, uint32_t width,
                 uint32_t height, uint32_t flags, uint32_t *stride,
                 void **map_data)
{
    (void)bo; (void)x; (void)y; (void)width; (void)height; (void)flags;
    if (stride) *stride = 0;
    if (map_data) *map_data = NULL;
    return NULL;
}

void gbm_bo_unmap(struct gbm_bo *bo, void *map_data)
{
    (void)bo; (void)map_data;
}

int gbm_detect_device_info(int fd_in, int fd_out, struct gbm_device_info *info)
{
    (void)fd_in; (void)fd_out; (void)info;
    return -1;
}

int gbm_detect_device_info_path(const char *path, struct gbm_device_info *info)
{
    (void)path; (void)info;
    return -1;
}
