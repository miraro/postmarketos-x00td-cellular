/*
 * vendor-init — Android-identical modem bringup for X00TD (SDM636 IPA v2.6L)
 *
 * Replicates the full vendor RIL + netmgrd + IPACM bringup sequence on a
 * single AF_QIPCRTR socket, so the modem sees the EXACT byte-for-byte init
 * Android sends. This is the experimental answer to the "carrier-cap"
 * hypothesis: by matching every stage Android performs (DPM_OPEN ... 0xfff2
 * pre-setup ... 7-TLV WDS_START_NETWORK), we expect the modem to accept
 * QMAPv3 + 8192-byte DL aggregation, unlocking throughput above the
 * mainline-MM-driven 67 KB/s wall.
 *
 * The exact reference is the Android capture at
 *   trace/android_capture/captures/capture_20260530_213719/qmi_trace.log
 * plus the vendor strace report at trace/VENDOR_STRACE_ANALYSIS.md.
 *
 * Stages (called in strict order from main()):
 *   stage_dpm_open    — Data Port Mapper handshake (NEW vs prior tools)
 *   stage_iattach     — WDS_SET_INITIAL_ATTACH_APN (was wds-iattach.c)
 *   stage_bind_mux    — WDS_BIND_MUX_DATA_PORT × N (was wds-bearer.c, N=1)
 *   stage_dsd         — DSD service event registration (NEW)
 *   stage_wda_set     — WDA SET_DATA_FORMAT QMAPv3+8192+10 (was wda-force.c)
 *   stage_fff2        — proprietary bearer pre-setup, msg 0xfff2 (NEW)
 *   stage_wds_start   — WDS_START_NETWORK with 7 TLVs (was wds-bearer.c, 2 TLV)
 *   stage_post_tune   — sysctl/ethtool/RPS tuning (NEW)
 *
 * Each stage runs sequentially; first failure aborts and writes /run/vendor-init/state.
 *
 * Build: make
 * Run:   sudo ./vendor-init [--apn NAME] [--num-muxes N] [--dry-run] [-v]
 */

#include "vendor-init.h"
#include "qrtr.h"
#include "log.h"
#include "state.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <signal.h>
#include <errno.h>

/* Stage order matches vendor's per-process pattern.
 *
 * netmgrd-equivalent (system-wide config, each on own socket, close after):
 *   dpm_open      — DPM_OPEN_PORT_REQ on DPM service
 *   wda_set       — WDA SET_DATA_FORMAT on WDA service
 *   dsd           — DSD lookup only (no register sent)
 *
 * qcrild-equivalent (bearer activation, FRESH socket kept alive):
 *   bind_mux      — opens persistent socket, BIND_MUX_DATA_PORT, stores ctx.fd
 *   wds_start     — same ctx.fd: 0x00AF + 0x004D + WDS_START_NETWORK
 *
 * post_tune       — shell-outs only
 *
 * iattach + fff2 still in source but NOT in STAGES[] (see earlier commits). */
static const struct {
	const char *name;
	stage_fn    fn;
} STAGES[] = {
	{ "dms_online", stage_dms_online },   /* 1st: ensure modem ONLINE */
	{ "nas_rat",    stage_nas_rat    },   /* 2nd: force LTE preferred + wait */
	{ "dpm_open",   stage_dpm_open  },
	{ "wda_set",    stage_wda_set   },
	{ "dsd",        stage_dsd       },
	{ "bind_mux",   stage_bind_mux  },
	{ "wds_start",  stage_wds_start },
	{ "post_tune",  stage_post_tune },
};

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

static void usage(const char *prog)
{
	fprintf(stderr,
"vendor-init — Android-identical X00TD modem bringup\n"
"Usage: %s [options]\n"
"  --apn NAME         APN string (default: %s)\n"
"  --num-muxes N      number of mux channels to bind (default: 1, vendor: %d)\n"
"  --skip-mm          don't try to stop ModemManager\n"
"  --dry-run          plan stages but skip QMI sends\n"
"  --log-file PATH    log file (default: /var/log/vendor-init.log)\n"
"  -s, --simple-wds   minimal 2-TLV WDS_START (DEFAULT — matches wds-bearer.c,\n"
"                     proven-working on mainline modem state)\n"
"  -F, --full-wds     vendor-byte-exact 6-TLV WDS_START + 0xAF/0x4D prefix\n"
"                     (Android vendor parity, fails with err=74 PROFILE_NOT_FOUND\n"
"                     on PostmarketOS modem NV state — for testing only)\n"
"  -U, --full-ul      request QMAPv3 UL (WDA UL=7) — requires driver\n"
"                     qmapv3_ul_enable=1 + rmnet egress-mapv4-checksum on\n"
"  -v, --verbose      enable DEBUG logging\n"
"  -h, --help         this help\n",
		prog, DEFAULT_APN, MUX_COUNT_VENDOR);
}

int main(int argc, char **argv)
{
	struct vi_ctx ctx = {
		.fd          = -1,
		.txid        = 1,
		.apn         = DEFAULT_APN,
		.num_muxes   = 1,
		.simple_wds  = 1,        /* default: 2-TLV WDS_START (matches wds-bearer.c) */
	};
	int verbose = 0;
	const char *log_file = NULL;

	static const struct option opts[] = {
		{ "apn",         required_argument, 0, 'a' },
		{ "num-muxes",   required_argument, 0, 'n' },
		{ "skip-mm",     no_argument,       0, 'S' },
		{ "dry-run",     no_argument,       0, 'D' },
		{ "log-file",    required_argument, 0, 'L' },
		{ "simple-wds",  no_argument,       0, 's' },
		{ "full-wds",    no_argument,       0, 'F' },
		{ "full-ul",     no_argument,       0, 'U' },
		{ "verbose",     no_argument,       0, 'v' },
		{ "help",        no_argument,       0, 'h' },
		{ 0, 0, 0, 0 },
	};
	int c;
	while ((c = getopt_long(argc, argv, "a:n:SDL:sFUvh", opts, NULL)) != -1) {
		switch (c) {
		case 'a': ctx.apn = optarg; break;
		case 'n': ctx.num_muxes = atoi(optarg); break;
		case 'S': ctx.skip_mm = 1; break;
		case 'D': ctx.dry_run = 1; break;
		case 'L': log_file = optarg; break;
		case 's': ctx.simple_wds = 1; break;
		case 'F': ctx.simple_wds = 0; break;
		case 'U': ctx.full_ul = 1; break;
		case 'v': verbose = 1; break;
		case 'h': usage(argv[0]); return 0;
		default:  usage(argv[0]); return 1;
		}
	}

	log_init(verbose ? LOG_DEBUG : LOG_INFO, log_file);
	signal(SIGINT,  on_signal);
	signal(SIGTERM, on_signal);

	LOGI("main", "vendor-init starting — apn='%s' muxes=%d dry_run=%d",
	     ctx.apn, ctx.num_muxes, ctx.dry_run);
	state_set_result("STARTING");
	state_record("apn",       "%s",  ctx.apn);
	state_record("num_muxes", "%d",  ctx.num_muxes);
	state_record("dry_run",   "%d",  ctx.dry_run);

	/* Architecture change 2026-05-31: stages open OWN sockets, not shared.
	 *
	 * Three deploy iterations showed err=74 on WDS_START_NETWORK when our
	 * single shared socket carried DPM+WDA+WDS traffic. Vendor (and our
	 * own proven-working wds-bearer.c / wda-force.c) use SEPARATE QRTR
	 * sockets per service role — modem firmware appears to track per-
	 * (source-port, service) state in ways that get inconsistent when
	 * one source-port talks to multiple services.
	 *
	 * Each stage now manages its own QRTR socket lifetime:
	 *   dpm_open  — opens socket, sends, closes (DPM state is system-wide)
	 *   wda_set   — opens socket, sends, closes (WDA state is system-wide)
	 *   dsd       — opens socket for lookup, closes (no-op anyway)
	 *   bind_mux  — opens socket, BINDS, stores in ctx.fd (KEEPS open)
	 *   wds_start — uses ctx.fd (same client as bind_mux — modem requires)
	 *
	 * Main loop just keeps ctx.fd alive after wds_start to hold the
	 * bearer up; tearing the socket down kills the call. */
	ctx.fd = -1;          /* opened later by bind_mux */

	/* Run stages in order. */
	int rc = 0;
	size_t n_stages = sizeof(STAGES) / sizeof(STAGES[0]);
	for (size_t i = 0; i < n_stages; i++) {
		if (g_stop) {
			LOGW("main", "interrupted before stage %s", STAGES[i].name);
			state_set_result("INTERRUPTED");
			rc = 130;
			break;
		}
		state_set_stage(STAGES[i].name);
		LOGI("main", "=== stage %zu/%zu: %s ===",
		     i + 1, n_stages, STAGES[i].name);
		rc = STAGES[i].fn(&ctx);
		if (rc != 0) {
			LOGE("main", "stage %s failed rc=%d", STAGES[i].name, rc);
			char buf[64];
			snprintf(buf, sizeof(buf), "FAILED_%s", STAGES[i].name);
			state_set_result(buf);
			break;
		}
		LOGI("main", "stage %s OK", STAGES[i].name);
	}

	if (rc == 0) {
		LOGI("main", "ALL STAGES OK — bearer should be up, post-tune applied");
		state_set_result("READY");
		LOGI("main", "bearer IP=%u.%u.%u.%u mtu=%u",
		     (ctx.bearer_ipv4 >> 24) & 0xff,
		     (ctx.bearer_ipv4 >> 16) & 0xff,
		     (ctx.bearer_ipv4 >> 8)  & 0xff,
		     ctx.bearer_ipv4 & 0xff, ctx.bearer_mtu);
		LOGI("main", "holding socket open — Ctrl-C to tear down bearer");
		/* Keep socket open: tearing it down drops the bearer. */
		while (!g_stop)
			pause();
		LOGI("main", "signal received, exiting");
	}

	if (ctx.fd >= 0)
		close(ctx.fd);
	log_close();
	return rc;
}
