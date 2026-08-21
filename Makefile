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

OHOS_ARCH ?= x86_64
OHOS_ABI ?= x86_64

HDC := /apps/harmony/sdk/default/openharmony/toolchains/hdc -s 192.168.1.3:8710 -t 127.0.0.1:5555
BUNDLE := app.hackeris.hium
HAP := entry/build/default/outputs/default/entry-default-unsigned.hap

all: deps hap

deps:
	$(MAKE) -C deps $(OHOS_ARCH) TOOL_HOME=$(TOOL_HOME)

hap:
	hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon

install: $(HAP)
	$(HDC) shell "aa force-stop $(BUNDLE)" || true
	$(HDC) file send $(HAP) /data/local/tmp/hium.hap
	$(HDC) shell "bm install -p /data/local/tmp/hium.hap"
	$(HDC) shell "aa start -a EntryAbility -b $(BUNDLE)"

deploy: hap install

log:
	$(HDC) hilog | grep -E "QemuVM|QemuFB|QemuRender|QemuNapi|QemuInput|QemuUI|QemuEntry|CRASH|SIGSEGV"

.PHONY: all deps hap install deploy log
