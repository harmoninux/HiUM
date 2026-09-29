include ../utils/Makefrag

# libdrm：virglrenderer 的硬依赖（>=2.4.50）。只需核心 xf86drm + drm_fourcc
# 头，全部芯片族子模块关闭。静态链进 libvirglrenderer.so。
SOURCE_FILE = libdrm-2.4.120.tar.xz
SOURCE_DIR = libdrm-2.4.120

all: download/$(SOURCE_FILE)
	rm -rf temp build
	mkdir -p temp build
	cd temp && tar xf ../download/$(SOURCE_FILE)
	cd temp/$(SOURCE_DIR) && echo "[binaries]" > cross.txt
	cd temp/$(SOURCE_DIR) && echo "c = '$(CC)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpp = '$(CXX)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "ar = '$(AR)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "ld = '$(LD)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "strip = '$(STRIP)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "[host_machine]" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "system = 'linux'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpu_family = '$(OHOS_ARCH)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "cpu = '$(OHOS_ARCH)'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "endian = 'little'" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "[properties]" >> cross.txt
	cd temp/$(SOURCE_DIR) && echo "needs_exe_wrapper = true" >> cross.txt
	cd temp/$(SOURCE_DIR) && PKG_CONFIG_LIBDIR=$(shell pwd)/../buildroot/lib/pkgconfig \
	meson setup --cross-file cross.txt --prefix=$(PREFIX) \
	-Ddefault_library=static -Dintel=disabled -Dradeon=disabled \
	-Damdgpu=disabled -Dnouveau=disabled -Dvmwgfx=disabled \
	-Dfreedreno=disabled -Dvc4=disabled -Detnaviv=disabled \
	-Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled \
	-Dtests=false -Dudev=false build
	cd temp/$(SOURCE_DIR)/build && meson compile
	cd temp/$(SOURCE_DIR)/build && DESTDIR=$(shell pwd)/build meson install
	mkdir -p ../buildroot
	cp -rfv ./build/$(PREFIX)/. ../buildroot | tee file.lst

download/$(SOURCE_FILE):
	mkdir -p download
	cd download && wget --retry-connrefused --read-timeout=20 --timeout=15 https://dri.freedesktop.org/libdrm/libdrm-2.4.120.tar.xz
