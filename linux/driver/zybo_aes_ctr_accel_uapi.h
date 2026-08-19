/* SPDX-License-Identifier: MIT */
#ifndef ZYBO_AES_CTR_ACCEL_UAPI_H
#define ZYBO_AES_CTR_ACCEL_UAPI_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define ZYBO_AES_CTR_ACCEL_DEVICE_NAME   "zybo_aes_ctr0"
#define ZYBO_AES_CTR_ACCEL_ABI_VERSION   1U
#define ZYBO_AES_CTR_ACCEL_IOCTL_MAGIC   'A'

#define ZYBO_AES_CTR_DMA_CAP_BLOCKING_SUBMIT       (1U << 0)
#define ZYBO_AES_CTR_DMA_CAP_DRIVER_STAGING_BUFS   (1U << 1)

struct zybo_aes_ctr_accel_info {
	__u32 abi_version;
	__u32 hardware_version;
	__u32 register_span;
	__u32 reserved;
};

struct zybo_aes_ctr_dma_caps {
	__u32 max_transfer_bytes;
	__u32 transfer_alignment_bytes;
	__u32 default_timeout_ms;
	__u32 max_timeout_ms;
	__u32 flags;
	__u32 reserved[3];
};

struct zybo_aes_ctr_config {
	__u32 key_words[4];       /* key[127:96], key[95:64], key[63:32], key[31:0] */
	__u32 nonce_words[3];     /* nonce[95:64], nonce[63:32], nonce[31:0] */
	__u32 initial_counter;
	__u32 reserved[4];
};

struct zybo_aes_ctr_transfer {
	__u64 input_ptr;
	__u64 output_ptr;
	__u32 length;
	__u32 timeout_ms;
	__u32 flags;
	__u32 reserved;
};

struct zybo_aes_ctr_status {
	__u32 status;
	__u32 idle;
	__u32 busy;
	__u32 reserved;
};

struct zybo_aes_ctr_stats {
	__u64 submit_count;
	__u64 complete_count;
	__u64 timeout_count;
	__u64 error_count;
	__u32 last_transfer_bytes;
	__s32 last_error;
	__u32 reserved[2];
};

#define ZYBO_AES_CTR_IOCTL_GET_INFO \
	_IOR(ZYBO_AES_CTR_ACCEL_IOCTL_MAGIC, 0x00, struct zybo_aes_ctr_accel_info)

#define ZYBO_AES_CTR_IOCTL_GET_DMA_CAPS \
	_IOR(ZYBO_AES_CTR_ACCEL_IOCTL_MAGIC, 0x20, struct zybo_aes_ctr_dma_caps)

#define ZYBO_AES_CTR_IOCTL_SUBMIT \
	_IOW(ZYBO_AES_CTR_ACCEL_IOCTL_MAGIC, 0x21, struct zybo_aes_ctr_transfer)

#define ZYBO_AES_CTR_IOCTL_GET_STATS \
	_IOR(ZYBO_AES_CTR_ACCEL_IOCTL_MAGIC, 0x22, struct zybo_aes_ctr_stats)

#define ZYBO_AES_CTR_IOCTL_SET_CONFIG \
	_IOW(ZYBO_AES_CTR_ACCEL_IOCTL_MAGIC, 0x30, struct zybo_aes_ctr_config)

#define ZYBO_AES_CTR_IOCTL_GET_STATUS \
	_IOR(ZYBO_AES_CTR_ACCEL_IOCTL_MAGIC, 0x31, struct zybo_aes_ctr_status)

#endif /* ZYBO_AES_CTR_ACCEL_UAPI_H */