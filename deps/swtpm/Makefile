# Reproducible build of libswtpm.so for OHOS aarch64 (musl libc).
#
# Replicates the one-off /tmp/swtpm-so-build/build-libswtpm.sh, but now driven
# entirely from controlled repo assets + a git clone of swtpm-0.10.2:
#   - deps/baseline/swtpm-deps/include : libtpms + json-glib headers (no openssl)
#   - deps/baseline/swtpm-generated    : generated headers (config.h, include/swtpm.h)
#   - deps/baseline/swtpm-libs         : 6 prebuilt musl-aarch64 runtime libs
#   - deps/buildroot                   : static glib (built by deps/libglib)
OHOS_SDK_HOME ?= $(TOOL_HOME)/sdk/default/openharmony
include ../utils/Makefrag

BROOT    := $(abspath ../buildroot)
OUTDIR   := $(abspath ../output)
DEPS_INC := $(abspath ../baseline/swtpm-deps/include)
GEN_DIR  := ../baseline/swtpm-generated
LIBDIR   := $(abspath ../baseline/swtpm-libs)

# swtpm-0.10.2 source tree + configured overrides (generated headers)
S := download/swtpm
INC := $(S) $(S)/include $(S)/include/swtpm $(S)/src/utils $(DEPS_INC)
GLIB_INC := $(BROOT)/include/glib-2.0 $(BROOT)/lib/glib-2.0/include $(BROOT)/include

# Replicate the one-off build flags (see build-libswtpm.sh).
SWTPM_CFLAGS := -fPIC -O2 \
	$(addprefix -I,$(INC)) $(addprefix -I,$(GLIB_INC)) \
	-DG_INTL_STATIC_COMPILATION -DHAVE_CONFIG_H -pthread \
	-fstack-protector-strong -D_FORTIFY_SOURCE=2 \
	-Wreturn-type -Wsign-compare -Wswitch-enum -Wmissing-prototypes \
	-Wall -Wformat -Wformat-security -Wshadow

SWTPM_SRCS  := main daemonize swtpm swtpm_chardev
SWTPM_OBJS  := $(addprefix build/,$(addsuffix .o,$(SWTPM_SRCS))) build/entry.o

# Prebuilt musl runtime libs referenced by absolute path (dlopen by SONAME).
SWTPM_LIBS := \
	$(LIBDIR)/libswtpm_libtpms.so.0 $(LIBDIR)/libtpms.so.0 \
	$(LIBDIR)/libjson-glib-1.0.so.0 $(LIBDIR)/libcrypto.so.3 \
	$(LIBDIR)/libz.so.1 $(LIBDIR)/libpcre2-8.so.0

all: download/swtpm
	rm -rf build
	mkdir -p build
	# overlay the configure-generated headers into the pristine clone
	cp -f $(GEN_DIR)/config.h       $(S)/config.h
	cp -f $(GEN_DIR)/include/swtpm.h $(S)/include/swtpm.h
	# compile the swtpm daemon sources + the swtpm_entry shim
	for f in $(SWTPM_SRCS); do \
		$(CC) $(SWTPM_CFLAGS) -c $(S)/src/swtpm/$$f.c -o build/$$f.o ; done
	$(CC) $(SWTPM_CFLAGS) -c entry.c -o build/entry.o
	$(CC) -shared -fPIC -o build/libswtpm.so \
		$(SWTPM_OBJS) \
		$(SWTPM_LIBS) \
		-L$(BROOT)/lib -lgio-2.0 -lgobject-2.0 -lffi -lgmodule-2.0 -lgthread-2.0 -lintl -lglib-2.0 \
		-lm -pthread -ldl \
		-Wl,-z,defs -Wl,--version-script=exports.map
	mkdir -p $(OUTDIR)
	cp -f build/libswtpm.so $(OUTDIR)/libswtpm.so
	@echo "Built $(OUTDIR)/libswtpm.so"
	@$(OHOS_SDK_HOME)/native/llvm/bin/llvm-nm -D $(OUTDIR)/libswtpm.so | grep swtpm_entry

download/swtpm:
	mkdir -p download
	cd download && rm -rf swtpm && git clone -b v0.10.2 --depth=1 https://github.com/stefanberger/swtpm.git swtpm

.PHONY: all
