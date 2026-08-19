#define _GNU_SOURCE
/* SPDX-License-Identifier: MIT */
/*
 * Configurable AES-CTR validation tool for /dev/zybo_aes_ctr0.
 *
 * No hardcoded test vector is used.
 *
 * User provides:
 *   --key      128-bit AES key as 32 hex chars
 *   --nonce    96-bit nonce as 24 hex chars
 *   --counter  32-bit initial counter as 8 hex chars
 *   --size     transfer size in bytes
 *   --pattern  input pattern
 *
 * The program:
 *   1. Generates input data from the selected pattern.
 *   2. Computes AES-CTR output in software.
 *   3. Configures the FPGA AES-CTR driver.
 *   4. Runs one DMA-backed FPGA transaction.
 *   5. Compares FPGA output against software output byte-for-byte.
 */

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "zybo_aes_ctr_accel_uapi.h"

#define AES_BLOCK_BYTES             16U
#define AES_128_KEY_BYTES           16U
#define AES_CTR_NONCE_BYTES         12U
#define AES_CTR_COUNTER_BYTES       4U
#define AES_128_ROUND_KEY_BYTES     176U
#define AES_128_ROUNDS              10U
#define OUTPUT_SENTINEL             0xcdU

enum input_pattern {
	PATTERN_ZERO = 0,
	PATTERN_FF,
	PATTERN_INCREMENT,
	PATTERN_AFFINE,
	PATTERN_ALTERNATING,
};

struct cli_options {
	const char *device_path;
	const char *key_hex;
	const char *nonce_hex;
	const char *counter_hex;
	const char *pattern_name;
	uint32_t size;
	uint32_t timeout_ms;
	uint32_t count;
	bool size_set;
};

static const uint8_t aes_sbox[256] = {
	0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
	0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
	0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
	0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
	0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
	0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
	0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
	0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
	0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
	0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
	0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
	0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
	0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
	0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
	0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
	0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
};

static const uint8_t aes_rcon[10] = {
	0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36
};

static void print_usage(const char *program)
{
	printf("usage:\n");
	printf("  %s --key HEX32 --nonce HEX24 --counter HEX8 --size BYTES --pattern NAME [options]\n", program);
	printf("\n");
	printf("required:\n");
	printf("  --key HEX32        AES-128 key, 32 hex chars\n");
	printf("  --nonce HEX24      96-bit nonce, 24 hex chars\n");
	printf("  --counter HEX8     32-bit initial counter, 8 hex chars\n");
	printf("  --size BYTES       transfer size in bytes\n");
	printf("  --pattern NAME     zero, ff, increment, affine, alternating\n");
	printf("\n");
	printf("optional:\n");
	printf("  --device PATH      default /dev/%s\n", ZYBO_AES_CTR_ACCEL_DEVICE_NAME);
	printf("  --timeout MS       default 0, meaning driver default\n");
	printf("  --count N          repeat test N times, default 1\n");
	printf("  --help             show this help\n");
}

static int parse_u32(const char *text, uint32_t *value)
{
	char *end = NULL;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(text, &end, 0);
	if (errno || end == text || *end != '\0' || parsed > UINT32_MAX)
		return -1;

	*value = (uint32_t)parsed;
	return 0;
}

static int hex_value(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

static int parse_hex_exact(const char *hex, uint8_t *out, size_t out_len)
{
	size_t i;

	if (!hex || strlen(hex) != out_len * 2U)
		return -1;

	for (i = 0; i < out_len; ++i) {
		int hi = hex_value(hex[2U * i]);
		int lo = hex_value(hex[2U * i + 1U]);

		if (hi < 0 || lo < 0)
			return -1;

		out[i] = (uint8_t)((hi << 4) | lo);
	}

	return 0;
}

static uint32_t load_be32(const uint8_t bytes[4])
{
	return ((uint32_t)bytes[0] << 24) |
	       ((uint32_t)bytes[1] << 16) |
	       ((uint32_t)bytes[2] << 8) |
	       ((uint32_t)bytes[3]);
}

static int parse_pattern(const char *name, enum input_pattern *pattern)
{
	if (!strcmp(name, "zero")) {
		*pattern = PATTERN_ZERO;
		return 0;
	}
	if (!strcmp(name, "ff")) {
		*pattern = PATTERN_FF;
		return 0;
	}
	if (!strcmp(name, "increment")) {
		*pattern = PATTERN_INCREMENT;
		return 0;
	}
	if (!strcmp(name, "affine")) {
		*pattern = PATTERN_AFFINE;
		return 0;
	}
	if (!strcmp(name, "alternating")) {
		*pattern = PATTERN_ALTERNATING;
		return 0;
	}

	return -1;
}

static void fill_input_pattern(uint8_t *buffer, uint32_t length,
			       enum input_pattern pattern, uint32_t run_index)
{
	uint32_t i;

	switch (pattern) {
	case PATTERN_ZERO:
		memset(buffer, 0x00, length);
		break;

	case PATTERN_FF:
		memset(buffer, 0xff, length);
		break;

	case PATTERN_INCREMENT:
		for (i = 0; i < length; ++i)
			buffer[i] = (uint8_t)((i + run_index) & 0xffU);
		break;

	case PATTERN_AFFINE:
		for (i = 0; i < length; ++i)
			buffer[i] = (uint8_t)((i * 37U + 11U + run_index * 17U) & 0xffU);
		break;

	case PATTERN_ALTERNATING:
		for (i = 0; i < length; ++i)
			buffer[i] = ((i + run_index) & 1U) ? 0x55U : 0xaaU;
		break;
	}
}

static void aes_add_round_key(uint8_t state[16],
			      const uint8_t round_keys[AES_128_ROUND_KEY_BYTES],
			      uint32_t round)
{
	uint32_t i;
	const uint8_t *rk = &round_keys[round * AES_BLOCK_BYTES];

	for (i = 0; i < AES_BLOCK_BYTES; ++i)
		state[i] ^= rk[i];
}

static void aes_sub_bytes(uint8_t state[16])
{
	uint32_t i;

	for (i = 0; i < AES_BLOCK_BYTES; ++i)
		state[i] = aes_sbox[state[i]];
}

static void aes_shift_rows(uint8_t state[16])
{
	uint8_t tmp;

	tmp = state[1];
	state[1] = state[5];
	state[5] = state[9];
	state[9] = state[13];
	state[13] = tmp;

	tmp = state[2];
	state[2] = state[10];
	state[10] = tmp;
	tmp = state[6];
	state[6] = state[14];
	state[14] = tmp;

	tmp = state[15];
	state[15] = state[11];
	state[11] = state[7];
	state[7] = state[3];
	state[3] = tmp;
}

static uint8_t aes_xtime(uint8_t x)
{
	return (uint8_t)((x << 1) ^ ((x & 0x80U) ? 0x1bU : 0x00U));
}

static void aes_mix_columns(uint8_t state[16])
{
	uint32_t c;

	for (c = 0; c < 4U; ++c) {
		uint8_t *col = &state[4U * c];
		uint8_t a0 = col[0];
		uint8_t a1 = col[1];
		uint8_t a2 = col[2];
		uint8_t a3 = col[3];
		uint8_t t = (uint8_t)(a0 ^ a1 ^ a2 ^ a3);
		uint8_t u = a0;

		col[0] ^= t ^ aes_xtime((uint8_t)(a0 ^ a1));
		col[1] ^= t ^ aes_xtime((uint8_t)(a1 ^ a2));
		col[2] ^= t ^ aes_xtime((uint8_t)(a2 ^ a3));
		col[3] ^= t ^ aes_xtime((uint8_t)(a3 ^ u));
	}
}

static void aes_key_expand_128(const uint8_t key[AES_128_KEY_BYTES],
			       uint8_t round_keys[AES_128_ROUND_KEY_BYTES])
{
	uint32_t bytes_generated = AES_128_KEY_BYTES;
	uint32_t rcon_index = 0;
	uint8_t temp[4];
	uint32_t i;

	memcpy(round_keys, key, AES_128_KEY_BYTES);

	while (bytes_generated < AES_128_ROUND_KEY_BYTES) {
		for (i = 0; i < 4U; ++i)
			temp[i] = round_keys[bytes_generated - 4U + i];

		if ((bytes_generated % AES_128_KEY_BYTES) == 0U) {
			uint8_t rotate = temp[0];

			temp[0] = aes_sbox[temp[1]] ^ aes_rcon[rcon_index++];
			temp[1] = aes_sbox[temp[2]];
			temp[2] = aes_sbox[temp[3]];
			temp[3] = aes_sbox[rotate];
		}

		for (i = 0; i < 4U; ++i) {
			round_keys[bytes_generated] =
				round_keys[bytes_generated - AES_128_KEY_BYTES] ^ temp[i];
			++bytes_generated;
		}
	}
}

static void aes_encrypt_block_128(const uint8_t input[16],
				  uint8_t output[16],
				  const uint8_t round_keys[AES_128_ROUND_KEY_BYTES])
{
	uint8_t state[16];
	uint32_t round;

	memcpy(state, input, AES_BLOCK_BYTES);

	aes_add_round_key(state, round_keys, 0);

	for (round = 1U; round < AES_128_ROUNDS; ++round) {
		aes_sub_bytes(state);
		aes_shift_rows(state);
		aes_mix_columns(state);
		aes_add_round_key(state, round_keys, round);
	}

	aes_sub_bytes(state);
	aes_shift_rows(state);
	aes_add_round_key(state, round_keys, AES_128_ROUNDS);

	memcpy(output, state, AES_BLOCK_BYTES);
}

static void store_counter_block(uint8_t block[16],
				const uint8_t nonce[AES_CTR_NONCE_BYTES],
				uint32_t counter)
{
	memcpy(block, nonce, AES_CTR_NONCE_BYTES);
	block[12] = (uint8_t)(counter >> 24);
	block[13] = (uint8_t)(counter >> 16);
	block[14] = (uint8_t)(counter >> 8);
	block[15] = (uint8_t)counter;
}

static void aes_ctr_software_reference(const uint8_t *input,
				       uint8_t *output,
				       uint32_t length,
				       const uint8_t key[AES_128_KEY_BYTES],
				       const uint8_t nonce[AES_CTR_NONCE_BYTES],
				       uint32_t initial_counter)
{
	uint8_t round_keys[AES_128_ROUND_KEY_BYTES];
	uint8_t counter_block[AES_BLOCK_BYTES];
	uint8_t keystream[AES_BLOCK_BYTES];
	uint32_t offset = 0;
	uint32_t counter = initial_counter;

	aes_key_expand_128(key, round_keys);

	while (offset < length) {
		uint32_t i;
		uint32_t chunk = length - offset;

		if (chunk > AES_BLOCK_BYTES)
			chunk = AES_BLOCK_BYTES;

		store_counter_block(counter_block, nonce, counter);
		aes_encrypt_block_128(counter_block, keystream, round_keys);

		for (i = 0; i < chunk; ++i) {
			uint32_t word_base = i & ~3U;
			uint32_t byte_in_word = i & 3U;
			uint32_t aes_byte = word_base + (3U - byte_in_word);

			output[offset + i] = input[offset + i] ^ keystream[aes_byte];
		}

		++counter;
		offset += chunk;
	}
}

static int first_mismatch(const uint8_t *expected,
			  const uint8_t *observed,
			  uint32_t length)
{
	uint32_t i;

	for (i = 0; i < length; ++i) {
		if (expected[i] != observed[i])
			return (int)i;
	}

	return -1;
}

static void print_hex_window(const char *label,
			     const uint8_t *buffer,
			     uint32_t length,
			     uint32_t start)
{
	uint32_t i;
	uint32_t end = start + 32U;

	if (end > length)
		end = length;

	printf("%s [%" PRIu32 "..%" PRIu32 "): ", label, start, end);
	for (i = start; i < end; ++i)
		printf("%02x", buffer[i]);
	printf("\n");
}

static int parse_options(int argc, char **argv, struct cli_options *options)
{
	static const struct option long_options[] = {
		{ "device",  required_argument, NULL, 'd' },
		{ "key",     required_argument, NULL, 'k' },
		{ "nonce",   required_argument, NULL, 'n' },
		{ "counter", required_argument, NULL, 'c' },
		{ "size",    required_argument, NULL, 's' },
		{ "pattern", required_argument, NULL, 'p' },
		{ "timeout", required_argument, NULL, 't' },
		{ "count",   required_argument, NULL, 'r' },
		{ "help",    no_argument,       NULL, 'h' },
		{ NULL,      0,                 NULL,  0  },
	};
	int opt;

	options->device_path = "/dev/" ZYBO_AES_CTR_ACCEL_DEVICE_NAME;
	options->key_hex = NULL;
	options->nonce_hex = NULL;
	options->counter_hex = NULL;
	options->pattern_name = NULL;
	options->size = 0U;
	options->timeout_ms = 0U;
	options->count = 1U;
	options->size_set = false;

	while ((opt = getopt_long(argc, argv, "d:k:n:c:s:p:t:r:h",
				  long_options, NULL)) != -1) {
		switch (opt) {
		case 'd':
			options->device_path = optarg;
			break;

		case 'k':
			options->key_hex = optarg;
			break;

		case 'n':
			options->nonce_hex = optarg;
			break;

		case 'c':
			options->counter_hex = optarg;
			break;

		case 's':
			if (parse_u32(optarg, &options->size) < 0) {
				fprintf(stderr, "error: invalid --size '%s'\n", optarg);
				return -1;
			}
			options->size_set = true;
			break;

		case 'p':
			options->pattern_name = optarg;
			break;

		case 't':
			if (parse_u32(optarg, &options->timeout_ms) < 0) {
				fprintf(stderr, "error: invalid --timeout '%s'\n", optarg);
				return -1;
			}
			break;

		case 'r':
			if (parse_u32(optarg, &options->count) < 0 || !options->count) {
				fprintf(stderr, "error: invalid --count '%s'\n", optarg);
				return -1;
			}
			break;

		case 'h':
			print_usage(argv[0]);
			exit(EXIT_SUCCESS);

		default:
			return -1;
		}
	}

	if (optind != argc) {
		fprintf(stderr, "error: unexpected argument '%s'\n", argv[optind]);
		return -1;
	}

	if (!options->key_hex || !options->nonce_hex ||
	    !options->counter_hex || !options->size_set ||
	    !options->pattern_name) {
		fprintf(stderr, "error: --key, --nonce, --counter, --size, and --pattern are required\n");
		return -1;
	}

	return 0;
}

static int validate_against_caps(const struct cli_options *options,
				 const struct zybo_aes_ctr_dma_caps *caps)
{
	if (!options->size || options->size > caps->max_transfer_bytes) {
		fprintf(stderr,
			"error: size %" PRIu32 " violates DMA max %" PRIu32 "\n",
			options->size, caps->max_transfer_bytes);
		return -1;
	}

	if (caps->transfer_alignment_bytes &&
	    options->size % caps->transfer_alignment_bytes) {
		fprintf(stderr,
			"error: size %" PRIu32 " is not aligned to %" PRIu32 " bytes\n",
			options->size, caps->transfer_alignment_bytes);
		return -1;
	}

	if (options->timeout_ms > caps->max_timeout_ms) {
		fprintf(stderr,
			"error: timeout %" PRIu32 " exceeds max %" PRIu32 "\n",
			options->timeout_ms, caps->max_timeout_ms);
		return -1;
	}

	return 0;
}

static void fill_driver_config(struct zybo_aes_ctr_config *config,
			       const uint8_t key[AES_128_KEY_BYTES],
			       const uint8_t nonce[AES_CTR_NONCE_BYTES],
			       uint32_t initial_counter)
{
	memset(config, 0, sizeof(*config));

	config->key_words[0] = load_be32(&key[0]);
	config->key_words[1] = load_be32(&key[4]);
	config->key_words[2] = load_be32(&key[8]);
	config->key_words[3] = load_be32(&key[12]);

	config->nonce_words[0] = load_be32(&nonce[0]);
	config->nonce_words[1] = load_be32(&nonce[4]);
	config->nonce_words[2] = load_be32(&nonce[8]);

	config->initial_counter = initial_counter;
}

static int print_device_info(int fd)
{
	struct zybo_aes_ctr_accel_info info = { 0 };
	struct zybo_aes_ctr_dma_caps caps = { 0 };
	struct zybo_aes_ctr_status status = { 0 };

	if (ioctl(fd, ZYBO_AES_CTR_IOCTL_GET_INFO, &info) < 0) {
		perror("ioctl(GET_INFO)");
		return -1;
	}

	if (ioctl(fd, ZYBO_AES_CTR_IOCTL_GET_DMA_CAPS, &caps) < 0) {
		perror("ioctl(GET_DMA_CAPS)");
		return -1;
	}

	if (ioctl(fd, ZYBO_AES_CTR_IOCTL_GET_STATUS, &status) < 0) {
		perror("ioctl(GET_STATUS)");
		return -1;
	}

	printf("Device path        : /dev/%s\n", ZYBO_AES_CTR_ACCEL_DEVICE_NAME);
	printf("ABI version        : %" PRIu32 "\n", info.abi_version);
	printf("Hardware VERSION   : 0x%08" PRIx32 "\n", info.hardware_version);
	printf("Register span      : %" PRIu32 " bytes\n", info.register_span);
	printf("DMA max transfer   : %" PRIu32 " bytes\n", caps.max_transfer_bytes);
	printf("DMA alignment      : %" PRIu32 " bytes\n", caps.transfer_alignment_bytes);
	printf("Default timeout    : %" PRIu32 " ms\n", caps.default_timeout_ms);
	printf("Max timeout        : %" PRIu32 " ms\n", caps.max_timeout_ms);
	printf("AES status raw     : 0x%08" PRIx32 "\n", status.status);
	printf("AES idle           : %" PRIu32 "\n", status.idle);
	printf("AES busy           : %" PRIu32 "\n", status.busy);
	printf("\n");

	return 0;
}

static int run_one_test(int fd,
			const struct cli_options *options,
			enum input_pattern pattern,
			const uint8_t key[AES_128_KEY_BYTES],
			const uint8_t nonce[AES_CTR_NONCE_BYTES],
			uint32_t initial_counter,
			uint32_t run_index)
{
	struct zybo_aes_ctr_config config;
	struct zybo_aes_ctr_transfer transfer = { 0 };
	uint8_t *input = NULL;
	uint8_t *expected = NULL;
	uint8_t *observed = NULL;
	int mismatch;
	int ret = -1;

	input = malloc(options->size);
	expected = malloc(options->size);
	observed = malloc(options->size);

	if (!input || !expected || !observed) {
		fprintf(stderr, "error: failed to allocate %" PRIu32 "-byte buffers\n",
			options->size);
		goto out;
	}

	fill_input_pattern(input, options->size, pattern, run_index);
	memset(expected, 0, options->size);
	memset(observed, OUTPUT_SENTINEL, options->size);

	aes_ctr_software_reference(input, expected, options->size,
				   key, nonce, initial_counter);

	fill_driver_config(&config, key, nonce, initial_counter);

	if (ioctl(fd, ZYBO_AES_CTR_IOCTL_SET_CONFIG, &config) < 0) {
		perror("ioctl(SET_CONFIG)");
		goto out;
	}

	transfer.input_ptr = (uintptr_t)input;
	transfer.output_ptr = (uintptr_t)observed;
	transfer.length = options->size;
	transfer.timeout_ms = options->timeout_ms;
	transfer.flags = 0U;
	transfer.reserved = 0U;

	if (ioctl(fd, ZYBO_AES_CTR_IOCTL_SUBMIT, &transfer) < 0) {
		perror("ioctl(SUBMIT)");
		goto out;
	}

	mismatch = first_mismatch(expected, observed, options->size);
	if (mismatch >= 0) {
		uint32_t start = (mismatch >= 16) ? (uint32_t)mismatch - 16U : 0U;

		fprintf(stderr,
			"[FAIL] mismatch at byte %d: expected 0x%02x got 0x%02x\n",
			mismatch, expected[mismatch], observed[mismatch]);
		print_hex_window("input   ", input, options->size, start);
		print_hex_window("expected", expected, options->size, start);
		print_hex_window("observed", observed, options->size, start);
		goto out;
	}

	printf("[PASS] run=%" PRIu32 " size=%" PRIu32
	       " pattern=%s timeout=%" PRIu32 "\n",
	       run_index + 1U, options->size,
	       options->pattern_name, options->timeout_ms);

	ret = 0;

out:
	free(observed);
	free(expected);
	free(input);
	return ret;
}

int main(int argc, char **argv)
{
	struct cli_options options;
	struct zybo_aes_ctr_dma_caps caps = { 0 };
	enum input_pattern pattern;
	uint8_t key[AES_128_KEY_BYTES];
	uint8_t nonce[AES_CTR_NONCE_BYTES];
	uint8_t counter_bytes[AES_CTR_COUNTER_BYTES];
	uint32_t initial_counter;
	uint32_t run;
	int fd = -1;
	int ret = EXIT_FAILURE;

	if (parse_options(argc, argv, &options) < 0) {
		print_usage(argv[0]);
		return EXIT_FAILURE;
	}

	if (parse_hex_exact(options.key_hex, key, sizeof(key)) < 0) {
		fprintf(stderr, "error: --key must be exactly 32 hex chars\n");
		return EXIT_FAILURE;
	}

	if (parse_hex_exact(options.nonce_hex, nonce, sizeof(nonce)) < 0) {
		fprintf(stderr, "error: --nonce must be exactly 24 hex chars\n");
		return EXIT_FAILURE;
	}

	if (parse_hex_exact(options.counter_hex, counter_bytes,
			    sizeof(counter_bytes)) < 0) {
		fprintf(stderr, "error: --counter must be exactly 8 hex chars\n");
		return EXIT_FAILURE;
	}

	if (parse_pattern(options.pattern_name, &pattern) < 0) {
		fprintf(stderr,
			"error: --pattern must be one of: zero, ff, increment, affine, alternating\n");
		return EXIT_FAILURE;
	}

	initial_counter = load_be32(counter_bytes);

	fd = open(options.device_path, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		perror("open device");
		return EXIT_FAILURE;
	}

	if (ioctl(fd, ZYBO_AES_CTR_IOCTL_GET_DMA_CAPS, &caps) < 0) {
		perror("ioctl(GET_DMA_CAPS)");
		goto out;
	}

	if (validate_against_caps(&options, &caps) < 0)
		goto out;

	if (print_device_info(fd) < 0)
		goto out;

	printf("Configured test\n");
	printf("Size               : %" PRIu32 " bytes\n", options.size);
	printf("Pattern            : %s\n", options.pattern_name);
	printf("Count              : %" PRIu32 "\n", options.count);
	printf("Timeout            : %" PRIu32 " ms%s\n",
	       options.timeout_ms,
	       options.timeout_ms ? "" : " (driver default)");
	printf("\n");

	for (run = 0; run < options.count; ++run) {
		if (run_one_test(fd, &options, pattern, key, nonce,
				 initial_counter, run) < 0)
			goto out;
	}

	ret = EXIT_SUCCESS;

out:
	if (fd >= 0 && close(fd) < 0 && ret == EXIT_SUCCESS) {
		perror("close");
		ret = EXIT_FAILURE;
	}

	puts(ret == EXIT_SUCCESS ? "Overall result      : PASS" :
				   "Overall result      : FAIL");
	return ret;
}