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

HDC := /apps/harmony/sdk/default/openharmony/toolchains/hdc -t 192.168.1.4:44959
BUNDLE := app.hackeris.hium
HAP_UNSIGNED := entry/build/default/outputs/default/entry-default-unsigned.hap
HAP := entry/build/default/outputs/default/entry-default-signed.hap

all: deps hap

deps:
	$(MAKE) -C deps $(OHOS_ARCH) TOOL_HOME=$(TOOL_HOME)

hap:
	hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon

# 新设备要求已签名包：用 .ohos/ 下的调试证书经 hap-sign-tool 本地签名
#（sign.py/sign.js 借自 wineohos，口令密文由 .ohos/material 解出）
sign: $(HAP_UNSIGNED)
	TOOL_HOME=$(TOOL_HOME) python3 sign.py $(HAP_UNSIGNED) $(HAP)

install: sign
	$(HDC) shell "aa force-stop $(BUNDLE)" || true
	$(HDC) install $(HAP)
	$(HDC) shell "aa start -a EntryAbility -b $(BUNDLE)"

deploy: hap install

log:
	$(HDC) hilog | grep -E "QemuVM|QemuFB|QemuRender|QemuNapi|QemuInput|QemuUI|QemuEntry|CRASH|SIGSEGV"

.PHONY: all deps hap sign install deploy log
