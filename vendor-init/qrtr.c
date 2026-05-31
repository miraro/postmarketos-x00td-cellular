#include "qrtr.h"
#include "log.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <sys/socket.h>

int qrtr_open(void)
{
	int fd = socket(AF_QIPCRTR, SOCK_DGRAM, 0);
	if (fd < 0)
		LOGE("qrtr", "socket(AF_QIPCRTR) failed: %s", strerror(errno));
	return fd;
}

/* qrtr_ctrl_pkt is defined in <linux/qrtr.h> via qrtr.h. We send NEW_LOOKUP
 * and wait for one or more NEW_SERVER packets. The control port is (node=0,
 * port=QRTR_PORT_CTRL = 0xFFFFFFFE). */
/* Verified from capture: vendor netmgrd sends cmd=0x0a (NEW_LOOKUP) and
 * receives cmd=0x04 (NEW_SERVER) responses. Earlier values 2/7 were wrong. */
#ifndef QRTR_TYPE_NEW_SERVER
#define QRTR_TYPE_NEW_SERVER 4
#endif
#ifndef QRTR_TYPE_NEW_LOOKUP
#define QRTR_TYPE_NEW_LOOKUP 10
#endif

uint32_t qrtr_lookup(int fd, uint32_t service)
{
	struct qrtr_ctrl_pkt pkt;
	/* Capture shows vendor netmgrd sends NEW_LOOKUP to (node=1, CTRL).
	 * Node 1 = remote modem QRTR daemon (node 0 = local AP). */
	struct sockaddr_qrtr sa = {
		.sq_family = AF_QIPCRTR,
		.sq_node   = 1,
		.sq_port   = QRTR_PORT_CTRL,
	};

	memset(&pkt, 0, sizeof(pkt));
	pkt.cmd             = QRTR_TYPE_NEW_LOOKUP;
	pkt.server.service  = service;
	pkt.server.instance = 0;
	pkt.server.node     = 0;
	pkt.server.port     = 0;

	if (sendto(fd, &pkt, sizeof(pkt), 0,
		   (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		LOGE("qrtr", "lookup sendto svc=0x%04x failed: %s",
		     service, strerror(errno));
		return 0;
	}

	/* Read NEW_SERVER responses until end-of-list (port=0 + node=0)
	 * or short timeout. */
	for (int i = 0; i < 64; i++) {
		struct pollfd pfd = { .fd = fd, .events = POLLIN };
		int pr = poll(&pfd, 1, 500);
		if (pr <= 0) {
			LOGW("qrtr", "lookup timeout for svc=0x%04x", service);
			return 0;
		}
		socklen_t sl = sizeof(sa);
		int n = recvfrom(fd, &pkt, sizeof(pkt), 0,
				 (struct sockaddr *)&sa, &sl);
		if (n < (int)sizeof(struct qrtr_ctrl_pkt))
			continue;
		if (pkt.cmd != QRTR_TYPE_NEW_SERVER)
			continue;
		if (pkt.server.service != service)
			continue;
		if (pkt.server.port == 0)
			continue;
		LOGD("qrtr", "lookup svc=0x%04x -> node=%u port=%u",
		     service, pkt.server.node, pkt.server.port);
		return pkt.server.port;
	}
	return 0;
}

int qrtr_txn(int fd, uint32_t node, uint32_t port,
	     const uint8_t *req, int req_len, uint16_t msg_id,
	     uint8_t *resp, int resp_sz, int timeout_ms)
{
	struct sockaddr_qrtr sa = {
		.sq_family = AF_QIPCRTR,
		.sq_node   = node,
		.sq_port   = port,
	};

	if (sendto(fd, req, req_len, 0,
		   (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		LOGE("qrtr", "txn sendto port=%u failed: %s",
		     port, strerror(errno));
		return -1;
	}

	struct pollfd pfd = { .fd = fd, .events = POLLIN };
	for (int tries = 0; tries < 32; tries++) {
		int pr = poll(&pfd, 1, timeout_ms);
		if (pr <= 0) {
			LOGW("qrtr", "txn timeout msg=0x%04x port=%u",
			     msg_id, port);
			return -1;
		}
		socklen_t sl = sizeof(sa);
		int n = recvfrom(fd, resp, resp_sz, 0,
				 (struct sockaddr *)&sa, &sl);
		if (n < 5)
			continue;
		uint16_t mid = resp[3] | (resp[4] << 8);
		uint8_t  ctl = resp[0];

		/* ctl=0x02 = response, =0x04 = indication, =0x01 = ack */
		if (ctl == 0x02 && mid == msg_id)
			return n;

		LOGD("qrtr", "skipping ctl=0x%02x msg=0x%04x %dB while waiting for 0x%04x",
		     ctl, mid, n, msg_id);
	}
	LOGW("qrtr", "txn no matching response after 32 tries msg=0x%04x", msg_id);
	return -1;
}
