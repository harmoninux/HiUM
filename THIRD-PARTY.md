# 第三方组件声明（THIRD-PARTY NOTICES）

HiUM 随包分发了以下第三方库的编译产物。全部源码（含我们的修改与构建链）见
<https://github.com/harmoninux/HiUM> 仓库 `deps/` 目录。
清单以 `entry/libs/` 实际打包内容为准。

## 随包分发的动态库

| 组件 | 许可证 | 用途 | 上游 |
|---|---|---|---|
| QEMU | GPL-2.0 | 全系统模拟器（修改版：OHOS 音频/显示/输入后端等） | <https://gitlab.com/qemu-project/qemu> |
| libslirp | BSD-3-Clause | 用户态网络（slirp 后端） | <https://gitlab.com/qemu-project/libslirp> |
| zlib | zlib | 压缩 | <https://zlib.net> |
| pcre2 | BSD-3-Clause | 正则（glib 依赖） | <https://github.com/PCRE2Project/pcre2> |

QEMU 以 `--disable-virglrenderer` 配置构建（deps/libqemu/Makefile），不含 virgl/GL 加速链路。

## 静态链接成分（不单独分发 .so）

glib（LGPL-2.1）、pixman（MIT）等以静态链接方式编入 QEMU 内部，随包分发其编译产物
的一部分；源码在 `deps/` 构建链中可得。

## 运行时下载（非随包分发）

- Alpine Linux 发行镜像（alpine-virt / alpine-standard）：首次使用「内置镜像」时
  按需从 Alpine 官方镜像站下载到应用数据目录，详见 `entry/src/main/ets/lib/isoDl.ets`。

## 应用代码

HiUM 应用代码（`entry/`、`AppScope/`、构建脚本）以 GPL-2.0 发布，见仓库根 `LICENSE`。
