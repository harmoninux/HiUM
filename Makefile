# qemuohos top-level build entry.
#
#   make            # deps (qemu .so) + hap
#   make deps       # cross-compile qemu & friends into entry/libs/<abi>/
#   make hap        # build HAP only (ArkTS/cpp changes)
#   make app-release# 发布上架包 build/outputs/release/qemuohos-release-signed.app
#   make install    # push + install + start on the test device
#   make deploy     # hap + install
#
# TOOL_HOME must point at HarmonyOS command line tools (env or make var).

export TOOL_HOME ?= /apps/harmony

OHOS_ARCH ?= aarch64
OHOS_ABI ?= arm64-v8a

# 设备无线调试地址（随 DHCP 变化，不固化在仓库里）：
#   make install HDC_TARGET=<ip>:<port>
# 未指定时不加 -t，用 hdc 自身默认/唯一已连接目标。
HDC_TARGET ?=
HDC := $(TOOL_HOME)/sdk/default/openharmony/toolchains/hdc $(if $(HDC_TARGET),-t $(HDC_TARGET),)
BUNDLE := app.hackeris.hium
HAP := entry/build/default/outputs/default/entry-default-signed.hap

all: deps hap

deps:
	$(MAKE) -C deps $(OHOS_ARCH) TOOL_HOME=$(TOOL_HOME)

# assembleHap 内置 SignHap 任务：按 build-profile.json5 的 signingConfigs
# （.ohos/ 下的调试证书 + 口令密文，均不入库）直接产出 entry-default-signed.hap
hap:
	hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon

# 发布上架包：release 签名配置（含发布材料路径/口令密文）不入库，存放在
# gitignore 的 .ohos/build-profile.release.json5；打包时临时换入根 build-profile.json5，
# 结束（含构建失败）即还原调试配置。assembleApp 内置 SignApp，无需手动签名。
# 注意：若构建被 Ctrl-C 强杀，还原步骤不执行，手动 mv .ohos/pack-bak.json5 build-profile.json5
app-release:
	cp build-profile.json5 .ohos/pack-bak.json5
	cp .ohos/build-profile.release.json5 build-profile.json5
	hvigorw assembleApp --mode project -p product=release -p buildMode=release --no-daemon; \
	  ret=$$?; mv .ohos/pack-bak.json5 build-profile.json5; exit $$ret

install: hap
	$(HDC) shell "aa force-stop $(BUNDLE)" || true
	$(HDC) install $(HAP)
	$(HDC) shell "aa start -a EntryAbility -b $(BUNDLE)"

deploy: hap install

log:
	$(HDC) hilog | grep -E "QemuVM|QemuFB|QemuRender|QemuNapi|QemuInput|QemuUI|QemuEntry|CRASH|SIGSEGV"

.PHONY: all deps hap app-release install deploy log
