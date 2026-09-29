/*
 * OHOS gbm stub — 仅满足 virglrenderer 的编译与链接。
 *
 * OHOS 应用沙箱没有 GBM/DRM 设备（/dev/dri 不可见），virglrenderer 0.10.4 的
 * EGL winsys 却无条件编译 vrend_winsys_gbm.c 并链接 gbm。这里提供一份接口
 * 全 stub 的实现：gbm_create_device 运行时返回 NULL → virgl_gbm_init 返回
 * NULL → egl->gbm = NULL，所有 gbm 代码路径不可达（vrend_winsys_egl.c 的
 * NULL 守卫见 patches/virgl-0001-ohos-no-gbm.patch）。
 *
 * GBM_FORMAT_* 必须用真值：它们就是 DRM fourcc，virgl_gbm_convert_format
 * 拿它们做格式查表，值错了 fourcc 会错乱。
 */
#ifndef GBM_STUB_H
#define GBM_STUB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- 不透明句柄（真实 gbm 里同样不透明） ---- */
struct gbm_device;
struct gbm_bo;

/* ---- GBM_FORMAT_*（= DRM fourcc，四字符码） ---- */
#define __gbm_fourcc_code(a, b, c, d) \
    ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))

#define GBM_FORMAT_BIG_ENDIAN 0x80000000
#define GBM_FORMAT_C8         0x20203843
#define GBM_FORMAT_RGB332     0x38325247
#define GBM_FORMAT_XRGB4444   0x32315258
#define GBM_FORMAT_XBGR4444   0x32314258
#define GBM_FORMAT_RGBX4444   0x32334252
#define GBM_FORMAT_BGRX4444   0x32334258
#define GBM_FORMAT_ARGB4444   0x32315241
#define GBM_FORMAT_ABGR4444   0x32314241
#define GBM_FORMAT_RGBA4444   0x32334152
#define GBM_FORMAT_BGRA4444   0x32334142
#define GBM_FORMAT_XRGB1555   0x35315258
#define GBM_FORMAT_XBGR1555   0x35314258
#define GBM_FORMAT_RGBX5551   0x35334252
#define GBM_FORMAT_BGRX5551   0x35334258
#define GBM_FORMAT_ARGB1555   0x35315241
#define GBM_FORMAT_ABGR1555   0x35314241
#define GBM_FORMAT_RGBA5551   0x35334152
#define GBM_FORMAT_BGRA5551   0x35334142
#define GBM_FORMAT_RGB565     0x36314752
#define GBM_FORMAT_BGR565     0x36314742
#define GBM_FORMAT_RGB888     0x34324752
#define GBM_FORMAT_BGR888     0x34324742
#define GBM_FORMAT_XRGB8888   0x34325258
#define GBM_FORMAT_XBGR8888   0x34324258
#define GBM_FORMAT_RGBX8888   0x34335852
#define GBM_FORMAT_BGRX8888   0x34335842
#define GBM_FORMAT_ARGB8888   0x34325241
#define GBM_FORMAT_ABGR8888   0x34324241
#define GBM_FORMAT_RGBA8888   0x34334152
#define GBM_FORMAT_BGRA8888   0x34334142
#define GBM_FORMAT_XRGB2101010 0x30335258
#define GBM_FORMAT_XBGR2101010 0x30334258
#define GBM_FORMAT_RGBX1010102 0x30335852
#define GBM_FORMAT_BGRX1010102 0x30335842
#define GBM_FORMAT_ARGB2101010 0x30335241
#define GBM_FORMAT_ABGR2101010 0x30334241
#define GBM_FORMAT_RGBA1010102 0x30334152
#define GBM_FORMAT_BGRA1010102 0x30334142
#define GBM_FORMAT_YVU420     0x32315659
#define GBM_FORMAT_NV12       0x3231564e
#define GBM_FORMAT_R8         0x20203852
#define GBM_FORMAT_GR88       0x38325247
#define GBM_FORMAT_ABGR16161616F 0x48344241

/* ---- gbm_bo 句柄 ---- */
union gbm_bo_handle {
    uint64_t u64;
    void *ptr;
    uint32_t u32;
    int32_t s32;
};

#define GBM_BO_USE_SCANOUT     (1 << 0)
#define GBM_BO_USE_CURSOR_64X64 (1 << 1)
#define GBM_BO_USE_RENDERING   (1 << 2)
#define GBM_BO_USE_WRITE       (1 << 3)
#define GBM_BO_USE_LINEAR      (1 << 4)

/* ---- 设备 ---- */
struct gbm_device *gbm_create_device(int fd);
void gbm_device_destroy(struct gbm_device *gbm);
int gbm_device_get_fd(struct gbm_device *gbm);
const char *gbm_device_get_backend_name(struct gbm_device *gbm);
int gbm_device_is_format_supported(struct gbm_device *gbm,
                                   uint32_t format, uint32_t usage);
int gbm_get_default_device_fd(void);

/* ---- buffer object ---- */
struct gbm_bo *gbm_bo_create(struct gbm_device *gbm,
                             uint32_t width, uint32_t height,
                             uint32_t format, uint32_t flags);
void gbm_bo_destroy(struct gbm_bo *bo);
union gbm_bo_handle gbm_bo_get_handle(struct gbm_bo *bo);
union gbm_bo_handle gbm_bo_get_handle_for_plane(struct gbm_bo *bo, int plane);
uint32_t gbm_bo_get_format(struct gbm_bo *bo);
uint32_t gbm_bo_get_width(struct gbm_bo *bo);
uint32_t gbm_bo_get_height(struct gbm_bo *bo);
uint32_t gbm_bo_get_stride(struct gbm_bo *bo);
uint32_t gbm_bo_get_stride_for_plane(struct gbm_bo *bo, int plane);
uint32_t gbm_bo_get_offset(struct gbm_bo *bo, int plane);
uint32_t gbm_bo_get_plane_count(struct gbm_bo *bo);
uint64_t gbm_bo_get_modifier(struct gbm_bo *bo);
uint32_t gbm_bo_get_plane_size(struct gbm_bo *bo, int plane);
int gbm_bo_get_fd(struct gbm_bo *bo);
struct gbm_device *gbm_bo_get_device(struct gbm_bo *bo);

/* ---- CPU map（virgl 的 minigbm 分支才用，一并提供符号） ---- */
#include <stddef.h>
struct gbm_bo_map_data; /* opaque */
void *gbm_bo_map(struct gbm_bo *bo, uint32_t x, uint32_t y, uint32_t width,
                 uint32_t height, uint32_t flags, uint32_t *stride,
                 void **map_data);
void gbm_bo_unmap(struct gbm_bo *bo, void *map_data);

/* ---- OHOS 扩展：virglrenderer 0.10.4 的 vrend_winsys_egl.c 引用 ---- */
/*（属于 minigbm_allocation 专用 API，非标准 gbm；stub 仍提供符号保链接） */
struct gbm_device_info {
    int dri_node_num;
    uint32_t dev_type_flags;
};
#define GBM_DEV_TYPE_FLAG_ARMSOC 1
int gbm_detect_device_info(int fd_in, int fd_out, struct gbm_device_info *info);
int gbm_detect_device_info_path(const char *path, struct gbm_device_info *info);

#ifdef __cplusplus
}
#endif

#endif /* GBM_STUB_H */
