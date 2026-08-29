include ../utils/Makefrag

ifeq ($(OHOS_ARCH), aarch64)
LSE_FLAGS := -D__ARM_LSE_ATOMIC_INLINES
endif

# to disable jit, add --enable-tcg-interpreter option

# guest targets: x86 / x86_64 / arm / arm64 / loongarch64 / riscv64 system emulators
TARGET_LIST := x86_64-softmmu,i386-softmmu,aarch64-softmmu,arm-softmmu,loongarch64-softmmu,riscv64-softmmu
QEMU_LIBS := libqemu-system-x86_64.so libqemu-system-i386.so libqemu-system-aarch64.so libqemu-system-arm.so libqemu-system-loongarch64.so libqemu-system-riscv64.so libqemu-img.so

# firmware blobs needed at runtime (packed into HAP rawfile)
FIRMWARE := bios-256k.bin bios.bin kvmvapic.bin linuxboot.bin linuxboot_dma.bin \
	vgabios-stdvga.bin vgabios-virtio.bin vgabios-ramfb.bin \
	efi-virtio.rom efi-e1000.rom pxe-e1000.rom keymaps/en-us
# optional blobs (present only when the corresponding firmware is shipped)
FIRMWARE_OPT := edk2-x86_64-code.fd edk2-x86_64-secure-code.fd edk2-i386-vars.fd edk2-arm-vars.fd edk2-aarch64-code.fd edk2-arm-code.fd edk2-loongarch64-code.fd edk2-riscv-code.fd

all: download/qemu
	rm -rf temp build
	mkdir -p temp build
	cd download/qemu && git worktree add -f $(shell pwd)/temp/qemu HEAD
	cd temp/qemu && \
	PKG_CONFIG=$(shell which pkg-config) \
	PKG_CONFIG_PATH= \
	PKG_CONFIG_LIBDIR=$(shell pwd)/../buildroot/lib/pkgconfig:$(shell pwd)/../buildroot/share/pkgconfig \
	PKG_CONFIG_buildroot_DIR=$(shell pwd)/../buildroot \
	CFLAGS="$(LSE_FLAGS) -D_UAPI_LINUX_VIRTIO_VSOCK_H -D_UAPI_LINUX_VIRTIO_TYPES_H -D_UAPI_LINUX_VIRTIO_RING_H -D_UAPI_LINUX_VIRTIO_PMEM_H -D_UAPI_LINUX_VIRTIO_NET_H -D_UAPI_LINUX_VIRTIO_IOMMU_H -D_UAPI_LINUX_VIRTIO_FS_H -D_UAPI_LINUX_VIRTIO_CONSOLE_H -D_UAPI_LINUX_VIRTIO_CONFIG_H -D_LINUX_SYSINFO_H -UHAVE_OPENAT2_H -D__user= -D__force= ${CFLAGS} -Wno-unused-command-line-argument -I$(shell pwd)/../buildroot/include/glib-2.0 -I$(shell pwd)/../buildroot/lib/glib-2.0/include -I$(shell pwd)/../buildroot/include/pixman-1 -L$(shell pwd)/../buildroot/lib" \
	./configure --target-list=$(TARGET_LIST) --cross-prefix= --host-cc=cc --disable-kvm --disable-xen --disable-rust --disable-docs --disable-werror \
	 --enable-tcg --enable-lto --enable-strip --with-coroutine=sigaltstack \
	 --enable-trace-backends=nop --disable-qom-cast-debug \
	 --disable-stack-protector \
	 --disable-bsd-user --disable-guest-agent --disable-gcrypt --disable-debug-info --disable-debug-tcg --enable-attr --disable-brlapi --disable-linux-aio \
	 --disable-bzip2 --disable-cap-ng --disable-curl --disable-glusterfs --disable-gnutls --disable-nettle --disable-gtk --disable-rdma --disable-libiscsi \
	 --disable-vnc-jpeg --disable-lzo --disable-curses --disable-libnfs --disable-numa --disable-opengl --disable-rbd --disable-vnc-sasl --disable-sdl \
	 --disable-seccomp --disable-smartcard --disable-snappy --disable-spice --disable-libusb --disable-usb-redir --disable-vde --disable-vhost-net --disable-virglrenderer \
	 --disable-vte --disable-xen-pci-passthrough --enable-tools --disable-libudev --disable-passt \
	 --enable-pixman --enable-vnc --enable-slirp --enable-virtfs
	cd temp/qemu && make $(QEMU_LIBS) -j $(shell nproc)
	for lib in $(QEMU_LIBS); do cp temp/qemu/build/$$lib ./build/; done
	cp temp/qemu/build/subprojects/slirp/libslirp.so.0.4.0 ./build/libslirp.so.0
	for fw in $(FIRMWARE); do cp temp/qemu/pc-bios/$$fw ./build/ || exit 1; done
	for fw in $(FIRMWARE_OPT); do \
	  if [ -f temp/qemu/pc-bios/$$fw.bz2 ]; then \
	    bzip2 -dc temp/qemu/pc-bios/$$fw.bz2 > ./build/$$fw; \
	  elif [ -f temp/qemu/pc-bios/$$fw ]; then \
	    cp temp/qemu/pc-bios/$$fw ./build/; \
	  fi; done
	mkdir -p ../output
	cp -rv ./build/* ../output

download/qemu:
	mkdir -p download
	cd download && git clone -b hish-libqemu --depth=1 https://github.com/harmoninux/qemu qemu
