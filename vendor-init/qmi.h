#ifndef VENDOR_INIT_QMI_H
#define VENDOR_INIT_QMI_H

#include <stdint.h>

/* QMI control flags (first byte of message). */
#define QMI_FLAG_REQ  0x00
#define QMI_FLAG_RESP 0x02
#define QMI_FLAG_IND  0x04

/* Builder: writes QMI header into b. Returns offset past header. */
int qmi_hdr_req(uint8_t *b, uint16_t txid, uint16_t msg_id, uint16_t body_len);

/* Append a TLV with raw bytes (small payloads). */
int qmi_tlv_bytes(uint8_t *b, int off, uint8_t type,
		  const void *data, uint16_t len);

/* Convenience appenders for u8 / u16 (LE) / u32 (LE). */
int qmi_tlv_u8 (uint8_t *b, int off, uint8_t type, uint8_t  v);
int qmi_tlv_u16(uint8_t *b, int off, uint8_t type, uint16_t v);
int qmi_tlv_u32(uint8_t *b, int off, uint8_t type, uint32_t v);

/* Decoder: return error code from result TLV (0x02), or -1 if absent. */
int qmi_result(const uint8_t *p, int n);

/* Look up a TLV by type; if found returns 1 and sets *out_off / *out_len
 * to the value range. Returns 0 if not found. */
int qmi_tlv_find(const uint8_t *p, int n, uint8_t type,
		 int *out_off, int *out_len);

/* Fetch u32 (LE) TLV. Returns 1 on success. */
int qmi_tlv_get_u32(const uint8_t *p, int n, uint8_t type, uint32_t *out);

#endif
