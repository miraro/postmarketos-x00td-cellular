#ifndef VENDOR_INIT_QRTR_H
#define VENDOR_INIT_QRTR_H

#include <stdint.h>
#include <linux/qrtr.h>

/* QRTR service IDs we use. Decoded from capture qmi_trace.log NEW_SERVER
 * responses (cmd=4) on 2026-05-30. */
#define QRTR_SVC_WDS  0x0001  /* Wireless Data Service */
#define QRTR_SVC_DMS  0x0002  /* Device Management Service */
#define QRTR_SVC_NAS  0x0003  /* Network Access Service */
#define QRTR_SVC_WDA  0x001A  /* Wireless Data Administrative */
#define QRTR_SVC_DPM  0x002F  /* Data Port Mapper (svc 47, NOT 0x47) */
#define QRTR_SVC_DSD  0x0042  /* Data System Determination */

/* Open AF_QIPCRTR datagram socket. Returns fd or -1. */
int qrtr_open(void);

/* Look up service: returns first matching port on node 0, or 0 on failure.
 * service is QRTR_SVC_* above. instance/version can be 0 for "any". */
uint32_t qrtr_lookup(int fd, uint32_t service);

/* Send to (node, port) and wait for the QMI response matching msg_id.
 * Skips async indications (ctl=0x04) and unrelated responses.
 * Returns response length or -1. */
int qrtr_txn(int fd, uint32_t node, uint32_t port,
	     const uint8_t *req, int req_len, uint16_t msg_id,
	     uint8_t *resp, int resp_sz, int timeout_ms);

#endif
