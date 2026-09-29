include ../utils/Makefrag

# libepoxy：virglrenderer 与 qemu --enable-opengl 的共同硬依赖（epoxy.pc +
# epoxy_has_egl=1）。EGL 头来自 OHOS sysroot；glx/x11 关闭。静态链进
# libvirglrenderer.so。
SOURCE_FILE = libepoxy-1.5.10.tar.gz
SOURCE_DIR = libepoxy-1.5.10

all: download/$(SOURCE_FILE)
	rm -rf temp build
	mkdir -p temp build
	cd temp && tar xf ../download/$(SOURCE_FILE)
	cd temp/$(SOURCE_DIR) && patch -p1 < $(shell pwd)/patches/libepoxy-0001-ohos-lib-names.patch
	cd temp/$(SOURCE_DIR) && patch -p1 < $(shell pwd)/patches/libepoxy-0002-ohos-gl-proc-address.patch
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
	-Ddefault_library=static -Degl=yes -Dglx=no -Dx11=false -Dtests=false \
	-Ddocs=false build
	cd temp/$(SOURCE_DIR)/build && meson compile
	cd temp/$(SOURCE_DIR)/build && DESTDIR=$(shell pwd)/build meson install
	mkdir -p ../buildroot
	cp -rfv ./build/$(PREFIX)/. ../buildroot | tee file.lst

download/$(SOURCE_FILE):
	mkdir -p download
	cd download && wget --retry-connrefused --read-timeout=20 --timeout=15 https://codeload.github.com/anholt/libepoxy/tar.gz/refs/tags/1.5.10 -O libepoxy-1.5.10.tar.gz
