# vendor-init — unified userspace bringup utility for X00TD (SDM636 IPA v2.6L).
#
# Replaces scattered tools (wda-force, wds-bearer, wds-iattach) with a single
# binary that replicates Android RIL + netmgrd + IPACM bringup byte-for-byte.
#
# Cross-build for arm64 with -static so it runs on PostmarketOS without libc
# version coupling. Run with sudo on target.
#
# Build:        make
# Cross-target: aarch64-linux-gnu-gcc
# Deploy:       scp vendor-init root@asus-x00td:/usr/local/sbin/

# Override Make's built-in CC=cc default. Pass CC=other-gcc on command line
# to use a different cross toolchain.
ifeq ($(origin CC),default)
CC := aarch64-linux-gnu-gcc
endif
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter -std=gnu11 -static \
           -D_GNU_SOURCE -I.
LDFLAGS ?=

SRCS := vendor-init.c \
        qrtr.c \
        qmi.c \
        log.c \
        state.c \
        stage_dms_online.c \
        stage_nas_rat.c \
        stage_dpm_open.c \
        stage_iattach.c \
        stage_bind_mux.c \
        stage_dsd.c \
        stage_wda_set.c \
        stage_fff2.c \
        stage_wds_start.c \
        stage_post_tune.c

OBJS := $(SRCS:.c=.o)
OUT  := vendor-init

.PHONY: all clean

all: $(OUT)

$(OUT): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LDFLAGS)
	@file $@ | head -1
	@echo "Built $@ — push to device via scp/adb"

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(OUT)
