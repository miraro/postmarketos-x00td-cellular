#include "qmi.h"

#include <string.h>

int qmi_hdr_req(uint8_t *b, uint16_t txid, uint16_t msg_id, uint16_t body_len)
{
	b[0] = QMI_FLAG_REQ;
	b[1] = txid & 0xff;
	b[2] = (txid >> 8) & 0xff;
	b[3] = msg_id & 0xff;
	b[4] = (msg_id >> 8) & 0xff;
	b[5] = body_len & 0xff;
	b[6] = (body_len >> 8) & 0xff;
	return 7;
}

int qmi_tlv_bytes(uint8_t *b, int off, uint8_t type,
		  const void *data, uint16_t len)
{
	b[off++] = type;
	b[off++] = len & 0xff;
	b[off++] = (len >> 8) & 0xff;
	if (len)
		memcpy(&b[off], data, len);
	return off + len;
}

int qmi_tlv_u8(uint8_t *b, int off, uint8_t type, uint8_t v)
{
	return qmi_tlv_bytes(b, off, type, &v, 1);
}

int qmi_tlv_u16(uint8_t *b, int off, uint8_t type, uint16_t v)
{
	uint8_t le[2] = { v & 0xff, (v >> 8) & 0xff };
	return qmi_tlv_bytes(b, off, type, le, 2);
}

int qmi_tlv_u32(uint8_t *b, int off, uint8_t type, uint32_t v)
{
	uint8_t le[4] = {
		v & 0xff, (v >> 8) & 0xff,
		(v >> 16) & 0xff, (v >> 24) & 0xff,
	};
	return qmi_tlv_bytes(b, off, type, le, 4);
}

int qmi_tlv_find(const uint8_t *p, int n, uint8_t type,
		 int *out_off, int *out_len)
{
	int i = 7;
	while (i + 3 <= n) {
		uint8_t  t = p[i];
		uint16_t l = p[i + 1] | (p[i + 2] << 8);
		if (i + 3 + l > n)
			break;
		if (t == type) {
			if (out_off) *out_off = i + 3;
			if (out_len) *out_len = l;
			return 1;
		}
		i += 3 + l;
	}
	return 0;
}

int qmi_result(const uint8_t *p, int n)
{
	int off, len;
	if (!qmi_tlv_find(p, n, 0x02, &off, &len) || len < 4)
		return -1;
	return p[off + 2] | (p[off + 3] << 8);   /* err code (skip result u16) */
}

int qmi_tlv_get_u32(const uint8_t *p, int n, uint8_t type, uint32_t *out)
{
	int off, len;
	if (!qmi_tlv_find(p, n, type, &off, &len) || len < 4)
		return 0;
	*out = p[off] | (p[off + 1] << 8) |
	       (p[off + 2] << 16) | ((uint32_t)p[off + 3] << 24);
	return 1;
}
