# TOOL_HOME must be set externally (HarmonyOS Commandline Tools)
ifndef TOOL_HOME
$(error TOOL_HOME is not set. Please download HarmonyOS Commandline Tools from https://developer.huawei.com/consumer/cn/download/ and set TOOL_HOME)
endif

# Set derived SDK paths
export DEVECO_SDK_HOME = $(TOOL_HOME)/sdk
export OHOS_SDK_HOME = $(TOOL_HOME)/sdk/default/openharmony

# Set default platform to x86_64 for emulator
OHOS_ARCH ?= x86_64
OHOS_ABI ?= x86_64

PKGS=zstd \
    zlib \
    pcre2 \
    libglib \
    pixman \
    libqemu
STAMP=$(patsubst %,%/.stamp,$(PKGS))

# 内置 Alpine virt ISO（Linux 模板的启动光盘）：官方镜像站，按 OHOS_ARCH 选架构。
# 下载到 output/（与其他 deps 产物一致），copy 阶段一并拷进 rawfile/vm/。
ALPINE_VER  := 3.21.3
# 镜像站目录用 major.minor（/alpine/v3.21/），不是 /3.21.3/；注释放单独行避免空格进变量值
ALPINE_REL  := 3.21
ALPINE_ARCH := $(OHOS_ARCH)
ALPINE_ISO  := output/alpine-virt-$(ALPINE_VER)-$(ALPINE_ARCH).iso
ALPINE_URL  := https://dl-cdn.alpinelinux.org/alpine/v$(ALPINE_REL)/releases/$(ALPINE_ARCH)/alpine-virt-$(ALPINE_VER)-$(ALPINE_ARCH).iso

# Default target
all: copy

# Build for x86_64 platform
x86_64: clean_libqemu
	$(MAKE) copy OHOS_ARCH=x86_64 OHOS_ABI=x86_64

# Build for aarch64 platform
aarch64: clean_libqemu
	$(MAKE) copy OHOS_ARCH=aarch64 OHOS_ABI=arm64-v8a

clean_libqemu:
	rm -f libqemu/.stamp
	rm -rf libqemu/temp libqemu/build

copy: output/.stamp

output/.stamp: $(STAMP) $(ALPINE_ISO) Makefile
	cp buildroot/lib/libpcre2-8.so.0 output/
	cp buildroot/lib/libz.so.1 output/libz.so
	mkdir -p ../entry/libs/$(OHOS_ABI)
	rm -f ../entry/libs/$(OHOS_ABI)/*
	cp output/*.so ../entry/libs/$(OHOS_ABI)/
	cp output/*.so.* ../entry/libs/$(OHOS_ABI)/
	mkdir -p ../entry/src/main/resources/rawfile/vm/keymaps
	cp output/en-us ../entry/src/main/resources/rawfile/vm/keymaps/
	mkdir -p ../entry/src/main/resources/rawfile/vm/firmware
	for fw in bios-256k.bin bios.bin kvmvapic.bin linuxboot.bin linuxboot_dma.bin \
		vgabios-stdvga.bin vgabios-virtio.bin vgabios-ramfb.bin \
		efi-virtio.rom edk2-aarch64-code.fd edk2-arm-code.fd edk2-loongarch64-code.fd edk2-riscv-code.fd; do cp output/$$fw ../entry/src/main/resources/rawfile/vm/firmware/ 2>/dev/null || true; done
	# Alpine ISO 拷进 rawfile/vm/（bootstrap 运行时解包给内置模板）
	cp $(ALPINE_ISO) ../entry/src/main/resources/rawfile/vm/alpine-virt.iso
	touch output/.stamp

%/.stamp: %/Makefile
	make -C $(patsubst %/.stamp,%,$@) OHOS_ARCH=$(OHOS_ARCH) OHOS_ABI=$(OHOS_ABI)
	touch $@

# Alpine 虚机 ISO：单独下载（不触发 qemu 重编译），copy 阶段自动消费。
.PHONY: alpine
alpine: $(ALPINE_ISO)

$(ALPINE_ISO):
	@mkdir -p output
	cd output && wget --retry-connrefused --read-timeout=20 --timeout=15 -O $(notdir $(ALPINE_ISO)).part $(ALPINE_URL) && mv $(notdir $(ALPINE_ISO)).part $(notdir $(ALPINE_ISO))

clean:
	rm -f $(STAMP)
	rm -rf buildroot
	rm -rf output
