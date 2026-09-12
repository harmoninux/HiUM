# qemuohos top-level build entry.
#
#   make            # deps (qemu .so) + hap
#   make deps       # cross-compile qemu & friends into entry/libs/<abi>/
#   make hap        # build HAP only (ArkTS/cpp changes)
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

install: hap
	$(HDC) shell "aa force-stop $(BUNDLE)" || true
	$(HDC) install $(HAP)
	$(HDC) shell "aa start -a EntryAbility -b $(BUNDLE)"

deploy: hap install

log:
	$(HDC) hilog | grep -E "QemuVM|QemuFB|QemuRender|QemuNapi|QemuInput|QemuUI|QemuEntry|CRASH|SIGSEGV"

.PHONY: all deps hap install deploy log
