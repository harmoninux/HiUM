include ../utils/Makefrag

ifeq ($(OHOS_ARCH), aarch64)
LSE_FLAGS := -D__ARM_LSE_ATOMIC_INLINES
endif

# to disable jit, add --enable-tcg-interpreter option

# guest targets: x86 / x86_64 / arm / arm64 / loongarch64 / riscv64 system emulators
TARGET_LIST := x86_64-softmmu,i386-softmmu,aarch64-softmmu,arm-softmmu,loongarch64-softmmu,riscv64-softmmu
QEMU_LIBS := libqemu-system-x86_64.so libqemu-system-i386.so libqemu-system-aarch64.so libqemu-system-arm.so libqemu-system-loongarch64.so libqemu-system-riscv64.so libqemu-img.so

# firmware blobs needed at runtime (packed into HAP rawfile)
#
# vgabios-*.bin 必须与编辑页可选的每个 -vga 型号一一对应。缺一个的后果不是干净报错，
# 而是 qemu 陷入重复打印 `failed to find romfile "vgabios-<x>.bin"` 的死循环
# （不退 + 满速灌盘，实测 2GB/30s）。romfile 需求出自 qemu 源码：
#   hw/display/vga-pci.c:385     std     → vgabios-stdvga.bin
#   hw/display/virtio-vga.c:232  virtio  → vgabios-virtio.bin
#   hw/display/cirrus_vga.c      cirrus  → vgabios-cirrus.bin
#   hw/display/vmware_vga.c:1348 vmware  → vgabios-vmware.bin
# （ramfb 是 -device ramfb 用的，不属于 -vga 型号。）
# 改动 UI 的 vga 选项时，务必同步这一行 + deps/Makefile 的 rawfile 拷贝 + bootstrap.ets。
FIRMWARE := bios-256k.bin bios.bin kvmvapic.bin linuxboot.bin linuxboot_dma.bin \
	vgabios-stdvga.bin vgabios-virtio.bin vgabios-ramfb.bin \
	vgabios-cirrus.bin vgabios-vmware.bin \
	efi-virtio.rom opensbi-riscv64-generic-fw_dynamic.bin keymaps/en-us
#
# ↑ opensbi-riscv64-generic-fw_dynamic.bin：riscv64 的固件链是**两级**的——qemu 先把
# OpenSBI 载入 RAM(M-mode)，OpenSBI 再经 ROM reset vector 里的 kernel_entry(= flash
# base 0x20000000) 跳进 pflash 中的 edk2(S-mode)。riscv 的 edk2 只能走 -drive if=pflash
# （-bios 会把按 flash 地址链接的固件塞进 RAM 0x80000000，整段跑飞），而这时
# machine->firmware 为空，hw/riscv/boot.c riscv_find_firmware() 就按默认名去找这份
# OpenSBI（源码注释原话："we are going to load the OpenSBI binary included in the
# QEMU source"）。缺失的后果**由源码推得、未实测**：按 hw/riscv/boot.c 的
# riscv_find_firmware()，找不到时打印
#   Unable to find the RISC-V BIOS "opensbi-riscv64-generic-fw_dynamic.bin"
# 然后按空 firmware 继续，跳到空 RAM。故必须与 edk2-*.fd 一同发货。
# 改 riscv 固件链时同步这三处（本文件 + deps/Makefile 的 rawfile 拷贝 + bootstrap.ets）。
# optional blobs (present only when the corresponding firmware is shipped)
FIRMWARE_OPT := edk2-aarch64-code.fd edk2-arm-code.fd edk2-loongarch64-code.fd edk2-riscv-code.fd \
	edk2-riscv-vars.fd
#
# ↑ edk2-riscv-vars.fd：riscv64 的**第二块 pflash**（变量存储），32MB。edk2 的
# RiscVVirt 把代码与变量区分开，qemu 官方 tests/qtest/bios-tables-test.c 的 riscv64
# 用例就是双 pflash（code 只读 + vars snapshot=on）。缺它时变量服务没有 flash 后备，
# edk2 的变量读写会失败。该文件在 pc-bios 里只有 .bz2（故列在 FIRMWARE_OPT，走下面的
# bzip2 解压分支），解压后 32MB，恰好等于 riscv virt 的 pflash1 大小。
# ⚠️ 两份 vars 的用途不同，别混：随包的这份是**模板**，bootstrap 解成
# edk2-riscv-vars-template.fd，各 VM 启动时从它拷一份自己的（vmprofile.ensureRiscvVars）。
# 不能把同一份直接交给 qemu：edk2 会往里写 BootOrder/Boot####，内容一旦陈旧（任何设备
# 组合变化都会），它就不再自动引导光盘、直接掉进 UEFI Interactive Shell。
# 另外它**不解决**「客户机内核在 ACPI 下 setup_smp BUG」那个问题，那是 -machine
# virt,acpi=off 的事（见 vmprofile.ets）。

all: download/qemu
	rm -rf temp build
	mkdir -p temp build
	cd download/qemu && git worktree add -f $(shell pwd)/temp/qemu HEAD
	# worktree 出自 download/qemu 的 HEAD；HiUM 对 qemu 源树的改动以
	# patches/*.patch 形式入库，worktree 创建后立即应用（本地未提交改动
	# 不进 worktree，构建可复现的保证全在此步）。
	cd temp/qemu && git apply $(shell pwd)/patches/qemu-0001-audio-ohos-backend.patch
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
