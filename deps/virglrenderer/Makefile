include ../utils/Makefrag

# virglrenderer 0.10.4（经典 VirGL）：qemu --enable-virglrenderer / virtio-gpu-gl
# 的宿主侧实现。
#
# OHOS 适配（patches/virgl-0001-ohos-no-gbm.patch + gbm-stub/）：
#  * OHOS 应用沙箱没有 GBM/DRM 设备，但 0.10.4 的 egl 平台无条件编译
#    vrend_winsys_gbm.c 并要求 gbm.pc。gbm-stub 提供接口全 stub 的
#    libgbm.so（gbm_create_device 运行时返回 NULL），补丁把 meson 的
#    have_egl 与 gbm 解耦、并对无 platform_base 客户端扩展分支加 NULL 守卫。
#    运行时链路：virgl_egl_init(NULL, surfaceless=true, gles=true) →
#    SURFACELESS_MESA 失败 → fallback eglGetDisplay(EGL_DEFAULT_DISPLAY) ✓
#  * qemu 侧需配套 --enable-virglrenderer --enable-opengl，并给
#    virtio_gpu_virgl_init 加 USE_EGL|USE_SURFACELESS|USE_GLES（见
#    libqemu/patches/qemu-0002-virgl-ohos.patch）。
#
# 依赖顺序：libdrm（静态）→ libepoxy（静态）→ gbm-stub（动态，随 HAP 发布）
# → 本包（libvirglrenderer.so，动态，qemu 链接）。
SOURCE_FILE = virglrenderer-0.10.4.tar.gz
SOURCE_DIR = virglrenderer-virglrenderer-0.10.4

all: download/$(SOURCE_FILE) gbm-stub
	rm -rf temp build
	mkdir -p temp build
	cd temp && tar xf ../download/$(SOURCE_FILE)
	# worktree 思路同 libqemu：本地改动以 patch 入库，构建时应用
	cd temp/$(SOURCE_DIR) && git init -q . && git apply $(shell pwd)/patches/virgl-0001-ohos-no-gbm.patch
	cd temp/$(SOURCE_DIR) && echo "[binaries]" > cross.txt
	cd temp/$(SOURCE_DIR) && echo "c = '$(CC)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpp = '$(CXX)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "ar = '$(AR)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "ld = '$(LD)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "strip = '$(STRIP)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "pkg-config = 'pkg-config'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "[host_machine]" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "system = 'linux'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpu_family = '$(OHOS_ARCH)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpu = '$(OHOS_ARCH)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "endian = 'little'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "[properties]" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "needs_exe_wrapper = true" >> cross.txt
	# pc 文件的 Cflags 是虚拟 prefix（/data/app/...，本机不存在）；真实头在
	# buildroot。同 libqemu 手动 -I 的既有模式，通过 cross file 的 c_args 注入。
	cd temp/$(SOURCE_DIR) && echo "[built-in options]" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "c_args = ['-I$(shell pwd)/../buildroot/include', '-I$(shell pwd)/../buildroot/include/libdrm']" >> cross.txt
	cd temp/$(SOURCE_DIR) && PKG_CONFIG_LIBDIR=$(shell pwd)/../buildroot/lib/pkgconfig \
	meson setup --cross-file cross.txt --prefix=$(PREFIX) \
	-Ddefault_library=shared -Dplatforms=egl -Dminigbm_allocation=false \
	-Dvenus-experimental=false -Drender-server=false -Dtests=false build
	cd temp/$(SOURCE_DIR)/build && meson compile
	cd temp/$(SOURCE_DIR)/build && DESTDIR=$(shell pwd)/build meson install
	mkdir -p ../buildroot
	cp -rfv ./build/$(PREFIX)/. ../buildroot | tee file.lst
	# 供 HAP 打包：output/ 是 deps/Makefile copy 段的取件处（*.so + *.so.*）。
	# -L 实体化符号链接：打包不需要链接文件，qemu 的 DT_NEEDED 只找 soname
	# （libvirglrenderer.so.1）与 libgbm.so。
	mkdir -p ../output
	cp -fL ../buildroot/lib/libvirglrenderer.so.1 ../output/
	cp -fL ../buildroot/lib/libvirglrenderer.so ../output/
	cp -fL ../buildroot/lib/libgbm.so ../output/

# gbm stub：目标架构动态库 + pc。libvirglrenderer.so 的 DT_NEEDED 引用它，
# 必须随 HAP 一起发布（deps/Makefile 的 copy 段自动带上）。
.PHONY: gbm-stub
gbm-stub:
	mkdir -p ../buildroot/lib ../buildroot/lib/pkgconfig ../buildroot/include
	cp -f $(shell pwd)/gbm-stub/gbm.h ../buildroot/include/gbm.h
	$(CC) $(CFLAGS) -fPIC -shared -o ../buildroot/lib/libgbm.so \
		$(shell pwd)/gbm-stub/gbm_stub.c
	printf 'prefix=%s\nName: gbm\nDescription: OHOS link-only gbm stub (see gbm-stub/gbm.h)\nVersion: 0.0.0\nLibs: -lgbm\n' '$(PREFIX)' > ../buildroot/lib/pkgconfig/gbm.pc

download/$(SOURCE_FILE):
	mkdir -p download
	cd download && wget --retry-connrefused --read-timeout=20 --timeout=15 https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/virglrenderer-0.10.4/virglrenderer-virglrenderer-0.10.4.tar.gz -O virglrenderer-0.10.4.tar.gz
