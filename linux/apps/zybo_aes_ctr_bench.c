#define _GNU_SOURCE
/* SPDX-License-Identifier: MIT */
/*
 * End-to-end AES-CTR benchmark tool for the Zybo Z7-20 accelerator platform.
 *
 * Modes:
 *
 *   --mode fpga
 *     Measures the Linux-controlled FPGA transaction path:
 *
 *       user-space benchmark
 *       -> blocking SUBMIT ioctl
 *       -> zybo_aes_ctr_accel kernel driver
 *       -> AXI DMA MM2S
 *       -> FPGA AES-CTR AXI-Stream accelerator
 *       -> AXI DMA S2MM
 *       -> driver return to user space
 *
 *   --mode cpu
 *     Measures software AES-CTR encryption on the ARM CPU.
 *
 *   --mode compare
 *     Runs both paths separately and writes both result rows to the same CSV.
 *
 * Correctness checks are outside the timed loop.
 *
 * The FPGA timed interval is the blocking SUBMIT ioctl only.
 * The CPU timed interval is the software AES-CTR encryption call only.
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
#include <time.h>
#include <unistd.h>

#include "zybo_aes_ctr_accel_uapi.h"

#define AES_BLOCK_BYTES             16U
#define AES_128_KEY_BYTES           16U
#define AES_CTR_NONCE_BYTES         12U
#define AES_CTR_COUNTER_BYTES       4U
#define AES_128_ROUND_KEY_BYTES     176U
#define AES_128_ROUNDS              10U

#define OUTPUT_SENTINEL             0xcdU
#define DEFAULT_CSV_PATH            "zybo_aes_ctr_bench_results.csv"

#define DEFAULT_KEY_HEX             "00112233445566778899aabbccddeeff"
#define DEFAULT_NONCE_HEX           "0102030405060708090a0b0c"
#define DEFAULT_COUNTER_HEX         "00000001"

enum input_pattern {
	PATTERN_ZERO = 0,
	PATTERN_FF,
	PATTERN_INCREMENT,
	PATTERN_AFFINE,
	PATTERN_ALTERNATING,
};

enum benchmark_mode {
	BENCHMARK_MODE_FPGA = 0,
	BENCHMARK_MODE_CPU,
	BENCHMARK_MODE_COMPARE,
};

enum benchmark_size_mode {
	BENCHMARK_SWEEP = 0,
	BENCHMARK_SINGLE,
};

struct benchmark_case {
	uint32_t length;
	uint32_t iterations;
};

static const struct benchmark_case standard_cases[] = {
	{        64U, 10000U },
	{       256U, 10000U },
	{      1024U,  5000U },
	{      4096U,  5000U },
	{     16384U,  2000U },
	{     65536U,  1000U },
	{    262144U,   300U },
	{   1048576U,  100U },
};

struct cli_options {
	const char *device_path;
	const char *csv_path;
	const char *key_hex;
	const char *nonce_hex;
	const char *counter_hex;
	const char *pattern_name;

	enum input_pattern pattern;
	enum benchmark_mode benchmark_mode;
	enum benchmark_size_mode size_mode;

	uint32_t single_length;
	uint32_t single_iterations;
	uint32_t timeout_ms;

	bool sweep_requested;
	bool size_was_set;
	bool count_was_set;
};

struct aes_ctr_parameters {
	uint8_t key[AES_128_KEY_BYTES];
	uint8_t nonce[AES_CTR_NONCE_BYTES];
	uint32_t initial_counter;
	struct zybo_aes_ctr_config driver_config;
};

struct benchmark_result {
	uint32_t length;
	uint32_t requested_iterations;
	uint32_t successful_iterations;
	uint32_t failed_iterations;

	uint64_t total_payload_bytes;
	uint64_t wall_time_ns;
	uint64_t cpu_time_ns;

	uint64_t latency_sum_ns;
	uint64_t latency_min_ns;
	uint64_t latency_max_ns;

	uint64_t submit_delta;
	uint64_t complete_delta;
	uint64_t timeout_delta;
	uint64_t error_delta;

	bool precheck_passed;
	bool postcheck_passed;
	bool passed;
};

static volatile uint8_t cpu_output_sink;

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

static int die_errno(const char *what)
{
	fprintf(stderr, "error: %s: %s\n", what, strerror(errno));
	return EXIT_FAILURE;
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

static uint64_t timespec_to_ns(const struct timespec *value)
{
	return (uint64_t)value->tv_sec * 1000000000ULL +
	       (uint64_t)value->tv_nsec;
}

static uint64_t elapsed_ns(const struct timespec *start,
			   const struct timespec *end)
{
	return timespec_to_ns(end) - timespec_to_ns(start);
}

static double ns_to_us(uint64_t value)
{
	return (double)value / 1000.0;
}

static double ns_to_ms(uint64_t value)
{
	return (double)value / 1000000.0;
}

static double throughput_mib_per_s(uint64_t bytes, uint64_t ns)
{
	double seconds;

	if (!ns)
		return 0.0;

	seconds = (double)ns / 1000000000.0;
	return ((double)bytes / (1024.0 * 1024.0)) / seconds;
}

static double cpu_usage_percent(uint64_t cpu_ns, uint64_t wall_ns)
{
	if (!wall_ns)
		return 0.0;

	return ((double)cpu_ns / (double)wall_ns) * 100.0;
}

static const char *pattern_name(enum input_pattern pattern)
{
	switch (pattern) {
	case PATTERN_ZERO:
		return "zero";
	case PATTERN_FF:
		return "ff";
	case PATTERN_INCREMENT:
		return "increment";
	case PATTERN_AFFINE:
		return "affine";
	case PATTERN_ALTERNATING:
		return "alternating";
	default:
		return "unknown";
	}
}

static const char *benchmark_mode_name(enum benchmark_mode mode)
{
	switch (mode) {
	case BENCHMARK_MODE_FPGA:
		return "fpga";
	case BENCHMARK_MODE_CPU:
		return "cpu";
	case BENCHMARK_MODE_COMPARE:
		return "compare";
	default:
		return "unknown";
	}
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

static int parse_benchmark_mode(const char *name, enum benchmark_mode *mode)
{
	if (!strcmp(name, "fpga")) {
		*mode = BENCHMARK_MODE_FPGA;
		return 0;
	}

	if (!strcmp(name, "cpu")) {
		*mode = BENCHMARK_MODE_CPU;
		return 0;
	}

	if (!strcmp(name, "compare")) {
		*mode = BENCHMARK_MODE_COMPARE;
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

static void aes_ctr_software_reference_with_round_keys(
	const uint8_t *input,
	uint8_t *output,
	uint32_t length,
	const uint8_t round_keys[AES_128_ROUND_KEY_BYTES],
	const uint8_t nonce[AES_CTR_NONCE_BYTES],
	uint32_t initial_counter)
{
	uint8_t counter_block[AES_BLOCK_BYTES];
	uint8_t keystream[AES_BLOCK_BYTES];
	uint32_t offset = 0;
	uint32_t counter = initial_counter;

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

static void aes_ctr_software_reference(const uint8_t *input,
				       uint8_t *output,
				       uint32_t length,
				       const uint8_t key[AES_128_KEY_BYTES],
				       const uint8_t nonce[AES_CTR_NONCE_BYTES],
				       uint32_t initial_counter)
{
	uint8_t round_keys[AES_128_ROUND_KEY_BYTES];

	aes_key_expand_128(key, round_keys);
	aes_ctr_software_reference_with_round_keys(input, output, length,
						   round_keys, nonce,
						   initial_counter);
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

static int parse_aes_parameters(const struct cli_options *options,
				struct aes_ctr_parameters *params)
{
	uint8_t counter_bytes[AES_CTR_COUNTER_BYTES];

	memset(params, 0, sizeof(*params));

	if (parse_hex_exact(options->key_hex, params->key,
			    sizeof(params->key)) < 0) {
		fprintf(stderr,
			"error: invalid AES key '%s', expected 32 hex characters\n",
			options->key_hex);
		return -1;
	}

	if (parse_hex_exact(options->nonce_hex, params->nonce,
			    sizeof(params->nonce)) < 0) {
		fprintf(stderr,
			"error: invalid nonce '%s', expected 24 hex characters\n",
			options->nonce_hex);
		return -1;
	}

	if (parse_hex_exact(options->counter_hex, counter_bytes,
			    sizeof(counter_bytes)) < 0) {
		fprintf(stderr,
			"error: invalid counter '%s', expected 8 hex characters\n",
			options->counter_hex);
		return -1;
	}

	params->initial_counter = load_be32(counter_bytes);

	fill_driver_config(&params->driver_config, params->key,
			   params->nonce, params->initial_counter);

	return 0;
}

static void print_hex_bytes(const char *label, const uint8_t *data,
			    size_t length)
{
	size_t i;

	printf("%-18s: ", label);
	for (i = 0; i < length; ++i)
		printf("%02x", data[i]);
	printf("\n");
}

static void print_usage(const char *program)
{
	printf("usage:\n");
	printf("  %s [--mode fpga|cpu|compare] [--sweep] [options]\n", program);
	printf("  %s [--mode fpga|cpu|compare] --size BYTES --count N [options]\n", program);
	printf("\n");
	printf("modes:\n");
	printf("  --mode fpga          benchmark FPGA transaction path only\n");
	printf("  --mode cpu           benchmark software AES-CTR on CPU only\n");
	printf("  --mode compare       run FPGA and CPU benchmarks separately\n");
	printf("                       default compare\n");
	printf("\n");
	printf("size selection:\n");
	printf("  --sweep              run the standard benchmark sweep\n");
	printf("                       this is the default when no size is given\n");
	printf("  --size BYTES         run one selected transfer size\n");
	printf("  --count N            transaction count for single-size mode\n");
	printf("\n");
	printf("AES options:\n");
	printf("  --key HEX32          AES-128 key, default %s\n", DEFAULT_KEY_HEX);
	printf("  --nonce HEX24        96-bit nonce, default %s\n", DEFAULT_NONCE_HEX);
	printf("  --counter HEX8       initial 32-bit counter, default %s\n",
	       DEFAULT_COUNTER_HEX);
	printf("  -p, --pattern NAME   zero, ff, increment, affine, alternating\n");
	printf("                       default affine\n");
	printf("\n");
	printf("benchmark options:\n");
	printf("  -d, --device PATH    device path, default /dev/%s\n",
	       ZYBO_AES_CTR_ACCEL_DEVICE_NAME);
	printf("  -t, --timeout MS     DMA timeout, default 0 for driver default\n");
	printf("                       ignored in --mode cpu\n");
	printf("  -c, --csv PATH       CSV output file, default %s\n",
	       DEFAULT_CSV_PATH);
	printf("  -h, --help           show this help\n");
}

static int parse_options(int argc, char **argv, struct cli_options *options)
{
	static const struct option long_options[] = {
		{ "mode",    required_argument, NULL, 'm' },
		{ "sweep",   no_argument,       NULL, 'S' },
		{ "size",    required_argument, NULL, 's' },
		{ "count",   required_argument, NULL, 'r' },
		{ "device",  required_argument, NULL, 'd' },
		{ "timeout", required_argument, NULL, 't' },
		{ "csv",     required_argument, NULL, 'c' },
		{ "pattern", required_argument, NULL, 'p' },
		{ "key",     required_argument, NULL, 'k' },
		{ "nonce",   required_argument, NULL, 'N' },
		{ "counter", required_argument, NULL, 'C' },
		{ "help",    no_argument,       NULL, 'h' },
		{ NULL,      0,                 NULL,  0  },
	};
	int opt;

	options->device_path = "/dev/" ZYBO_AES_CTR_ACCEL_DEVICE_NAME;
	options->csv_path = DEFAULT_CSV_PATH;
	options->key_hex = DEFAULT_KEY_HEX;
	options->nonce_hex = DEFAULT_NONCE_HEX;
	options->counter_hex = DEFAULT_COUNTER_HEX;
	options->pattern_name = "affine";
	options->pattern = PATTERN_AFFINE;
	options->benchmark_mode = BENCHMARK_MODE_COMPARE;
	options->size_mode = BENCHMARK_SWEEP;
	options->single_length = 0U;
	options->single_iterations = 0U;
	options->timeout_ms = 0U;
	options->sweep_requested = false;
	options->size_was_set = false;
	options->count_was_set = false;

	while ((opt = getopt_long(argc, argv, "m:Ss:r:d:t:c:p:k:N:C:h",
				  long_options, NULL)) != -1) {
		switch (opt) {
		case 'm':
			if (parse_benchmark_mode(optarg,
						 &options->benchmark_mode) < 0) {
				fprintf(stderr,
					"error: invalid mode '%s'\n",
					optarg);
				return -1;
			}
			break;

		case 'S':
			options->sweep_requested = true;
			break;

		case 's':
			if (parse_u32(optarg, &options->single_length) < 0) {
				fprintf(stderr, "error: invalid size '%s'\n", optarg);
				return -1;
			}
			options->size_was_set = true;
			break;

		case 'r':
			if (parse_u32(optarg, &options->single_iterations) < 0 ||
			    !options->single_iterations) {
				fprintf(stderr, "error: invalid count '%s'\n", optarg);
				return -1;
			}
			options->count_was_set = true;
			break;

		case 'd':
			options->device_path = optarg;
			break;

		case 't':
			if (parse_u32(optarg, &options->timeout_ms) < 0) {
				fprintf(stderr, "error: invalid timeout '%s'\n", optarg);
				return -1;
			}
			break;

		case 'c':
			options->csv_path = optarg;
			break;

		case 'p':
			if (parse_pattern(optarg, &options->pattern) < 0) {
				fprintf(stderr,
					"error: invalid pattern '%s'\n",
					optarg);
				return -1;
			}
			options->pattern_name = optarg;
			break;

		case 'k':
			options->key_hex = optarg;
			break;

		case 'N':
			options->nonce_hex = optarg;
			break;

		case 'C':
			options->counter_hex = optarg;
			break;

		case 'h':
			print_usage(argv[0]);
			exit(EXIT_SUCCESS);

		default:
			return -1;
		}
	}

	if (optind != argc) {
		fprintf(stderr, "error: unexpected positional argument '%s'\n",
			argv[optind]);
		return -1;
	}

	if (options->sweep_requested &&
	    (options->size_was_set || options->count_was_set)) {
		fprintf(stderr,
			"error: --sweep cannot be combined with --size or --count\n");
		return -1;
	}

	if (options->size_was_set != options->count_was_set) {
		fprintf(stderr,
			"error: --size and --count must be provided together\n");
		return -1;
	}

	if (options->size_was_set)
		options->size_mode = BENCHMARK_SINGLE;
	else
		options->size_mode = BENCHMARK_SWEEP;

	return 0;
}

static void print_info(const struct zybo_aes_ctr_accel_info *info)
{
	printf("Driver ABI       : %" PRIu32 "\n", info->abi_version);
	printf("Hardware VERSION : 0x%08" PRIx32 "\n", info->hardware_version);
	printf("Register span    : %" PRIu32 " bytes\n", info->register_span);
}

static void print_caps(const struct zybo_aes_ctr_dma_caps *caps)
{
	printf("DMA max transfer : %" PRIu32 " bytes\n", caps->max_transfer_bytes);
	printf("DMA alignment    : %" PRIu32 " bytes\n",
	       caps->transfer_alignment_bytes);
	printf("Default timeout  : %" PRIu32 " ms\n", caps->default_timeout_ms);
	printf("Maximum timeout  : %" PRIu32 " ms\n", caps->max_timeout_ms);
	printf("DMA flags        : 0x%08" PRIx32 "\n", caps->flags);
}

static void print_status(const struct zybo_aes_ctr_status *status)
{
	printf("AES status raw   : 0x%08" PRIx32 "\n", status->status);
	printf("AES idle         : %" PRIu32 "\n", status->idle);
	printf("AES busy         : %" PRIu32 "\n", status->busy);
}

static int validate_fpga_length(uint32_t length,
				const struct zybo_aes_ctr_dma_caps *caps)
{
	if (!length || length > caps->max_transfer_bytes)
		return -1;

	if (caps->transfer_alignment_bytes &&
	    length % caps->transfer_alignment_bytes)
		return -1;

	return 0;
}

static int validate_cpu_length(uint32_t length)
{
	if (!length)
		return -1;

	return 0;
}

static int validate_timeout(uint32_t timeout_ms,
			    const struct zybo_aes_ctr_dma_caps *caps)
{
	if (timeout_ms > caps->max_timeout_ms)
		return -1;

	return 0;
}

static int get_stats(int fd, struct zybo_aes_ctr_stats *stats)
{
	memset(stats, 0, sizeof(*stats));

	if (ioctl(fd, ZYBO_AES_CTR_IOCTL_GET_STATS, stats) < 0)
		return -1;

	return 0;
}

static int submit_once(int fd, uint8_t *input, uint8_t *output,
		       uint32_t length, uint32_t timeout_ms)
{
	struct zybo_aes_ctr_transfer transfer = { 0 };

	transfer.input_ptr = (uintptr_t)input;
	transfer.output_ptr = (uintptr_t)output;
	transfer.length = length;
	transfer.timeout_ms = timeout_ms;
	transfer.flags = 0U;
	transfer.reserved = 0U;

	return ioctl(fd, ZYBO_AES_CTR_IOCTL_SUBMIT, &transfer);
}

static bool verify_output(const uint8_t *expected,
			  const uint8_t *observed,
			  uint32_t length)
{
	int mismatch = first_mismatch(expected, observed, length);

	if (mismatch >= 0) {
		fprintf(stderr,
			"mismatch at byte %d: expected 0x%02x got 0x%02x\n",
			mismatch, expected[mismatch], observed[mismatch]);
		return false;
	}

	return true;
}

static bool run_fpga_correctness_check(
	int fd,
	uint8_t *input,
	uint8_t *expected,
	uint8_t *observed,
	uint32_t length,
	uint32_t timeout_ms,
	enum input_pattern pattern,
	uint32_t seed,
	const struct aes_ctr_parameters *params,
	const char *stage)
{
	fill_input_pattern(input, length, pattern, seed);
	memset(expected, 0, length);
	memset(observed, OUTPUT_SENTINEL, length);

	aes_ctr_software_reference(input, expected, length,
				   params->key, params->nonce,
				   params->initial_counter);

	if (submit_once(fd, input, observed, length, timeout_ms) < 0) {
		fprintf(stderr,
			"[FAIL] %s FPGA correctness submit failed for size=%" PRIu32
			": %s\n",
			stage, length, strerror(errno));
		return false;
	}

	if (!verify_output(expected, observed, length)) {
		fprintf(stderr,
			"[FAIL] %s FPGA correctness output mismatch for size=%" PRIu32 "\n",
			stage, length);
		return false;
	}

	return true;
}

static bool run_cpu_correctness_check(
	uint8_t *input,
	uint8_t *expected,
	uint8_t *observed,
	uint32_t length,
	enum input_pattern pattern,
	uint32_t seed,
	const struct aes_ctr_parameters *params,
	const uint8_t round_keys[AES_128_ROUND_KEY_BYTES],
	const char *stage)
{
	fill_input_pattern(input, length, pattern, seed);
	memset(expected, 0, length);
	memset(observed, OUTPUT_SENTINEL, length);

	aes_ctr_software_reference(input, expected, length,
				   params->key, params->nonce,
				   params->initial_counter);

	aes_ctr_software_reference_with_round_keys(input, observed, length,
						   round_keys, params->nonce,
						   params->initial_counter);

	if (!verify_output(expected, observed, length)) {
		fprintf(stderr,
			"[FAIL] %s CPU correctness output mismatch for size=%" PRIu32 "\n",
			stage, length);
		return false;
	}

	return true;
}

static void initialize_result(struct benchmark_result *result,
			      uint32_t length, uint32_t iterations)
{
	memset(result, 0, sizeof(*result));

	result->length = length;
	result->requested_iterations = iterations;
	result->latency_min_ns = UINT64_MAX;
}

static int run_fpga_benchmark_case(
	int fd,
	const struct zybo_aes_ctr_dma_caps *caps,
	uint32_t length,
	uint32_t iterations,
	uint32_t timeout_ms,
	enum input_pattern pattern,
	const struct aes_ctr_parameters *params,
	struct benchmark_result *result)
{
	struct zybo_aes_ctr_stats before = { 0 };
	struct zybo_aes_ctr_stats after = { 0 };
	struct timespec wall_start = { 0 };
	struct timespec wall_end = { 0 };
	struct timespec cpu_start = { 0 };
	struct timespec cpu_end = { 0 };
	uint8_t *input = NULL;
	uint8_t *expected = NULL;
	uint8_t *output = NULL;
	uint32_t run;
	int ret = -1;

	initialize_result(result, length, iterations);

	if (validate_fpga_length(length, caps) < 0) {
		fprintf(stderr,
			"error: FPGA benchmark size %" PRIu32
			" violates current DMA limits\n",
			length);
		return -1;
	}

	input = malloc(length);
	expected = malloc(length);
	output = malloc(length);
	if (!input || !expected || !output) {
		fprintf(stderr,
			"error: failed to allocate %" PRIu32 "-byte FPGA benchmark buffers\n",
			length);
		goto out;
	}

	result->precheck_passed =
		run_fpga_correctness_check(fd, input, expected, output, length,
					   timeout_ms, pattern, 1U,
					   params, "pre");

	if (!result->precheck_passed)
		goto out;

	fill_input_pattern(input, length, pattern, 100U);
	memset(output, OUTPUT_SENTINEL, length);

	if (get_stats(fd, &before) < 0) {
		perror("ioctl(GET_STATS before FPGA benchmark)");
		goto out;
	}

	if (clock_gettime(CLOCK_MONOTONIC, &wall_start) < 0) {
		perror("clock_gettime(CLOCK_MONOTONIC)");
		goto out;
	}

	if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu_start) < 0) {
		perror("clock_gettime(CLOCK_PROCESS_CPUTIME_ID)");
		goto out;
	}

	for (run = 0; run < iterations; ++run) {
		struct timespec start = { 0 };
		struct timespec end = { 0 };
		uint64_t latency_ns;

		if (clock_gettime(CLOCK_MONOTONIC, &start) < 0) {
			perror("clock_gettime(CLOCK_MONOTONIC)");
			goto out;
		}

		if (submit_once(fd, input, output, length, timeout_ms) < 0) {
			++result->failed_iterations;
			continue;
		}

		if (clock_gettime(CLOCK_MONOTONIC, &end) < 0) {
			perror("clock_gettime(CLOCK_MONOTONIC)");
			goto out;
		}

		latency_ns = elapsed_ns(&start, &end);

		++result->successful_iterations;
		result->latency_sum_ns += latency_ns;

		if (latency_ns < result->latency_min_ns)
			result->latency_min_ns = latency_ns;

		if (latency_ns > result->latency_max_ns)
			result->latency_max_ns = latency_ns;
	}

	if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu_end) < 0) {
		perror("clock_gettime(CLOCK_PROCESS_CPUTIME_ID)");
		goto out;
	}

	if (clock_gettime(CLOCK_MONOTONIC, &wall_end) < 0) {
		perror("clock_gettime(CLOCK_MONOTONIC)");
		goto out;
	}

	result->wall_time_ns = elapsed_ns(&wall_start, &wall_end);
	result->cpu_time_ns = elapsed_ns(&cpu_start, &cpu_end);
	result->total_payload_bytes =
		(uint64_t)length * (uint64_t)result->successful_iterations;

	if (!result->successful_iterations)
		result->latency_min_ns = 0U;

	if (get_stats(fd, &after) < 0) {
		perror("ioctl(GET_STATS after FPGA benchmark)");
		goto out;
	}

	result->submit_delta = after.submit_count - before.submit_count;
	result->complete_delta = after.complete_count - before.complete_count;
	result->timeout_delta = after.timeout_count - before.timeout_count;
	result->error_delta = after.error_count - before.error_count;

	result->postcheck_passed =
		run_fpga_correctness_check(fd, input, expected, output, length,
					   timeout_ms, pattern, 2U,
					   params, "post");

	result->passed =
		result->precheck_passed &&
		result->postcheck_passed &&
		result->successful_iterations == iterations &&
		result->failed_iterations == 0U &&
		result->submit_delta == iterations &&
		result->complete_delta == iterations &&
		result->timeout_delta == 0U &&
		result->error_delta == 0U;

	ret = result->passed ? 0 : -1;

out:
	free(output);
	free(expected);
	free(input);
	return ret;
}

static int run_cpu_benchmark_case(
	uint32_t length,
	uint32_t iterations,
	enum input_pattern pattern,
	const struct aes_ctr_parameters *params,
	struct benchmark_result *result)
{
	struct timespec wall_start = { 0 };
	struct timespec wall_end = { 0 };
	struct timespec cpu_start = { 0 };
	struct timespec cpu_end = { 0 };
	uint8_t round_keys[AES_128_ROUND_KEY_BYTES];
	uint8_t *input = NULL;
	uint8_t *expected = NULL;
	uint8_t *output = NULL;
	uint32_t run;
	int ret = -1;

	initialize_result(result, length, iterations);

	if (validate_cpu_length(length) < 0) {
		fprintf(stderr,
			"error: CPU benchmark size %" PRIu32 " is invalid\n",
			length);
		return -1;
	}

	input = malloc(length);
	expected = malloc(length);
	output = malloc(length);
	if (!input || !expected || !output) {
		fprintf(stderr,
			"error: failed to allocate %" PRIu32 "-byte CPU benchmark buffers\n",
			length);
		goto out;
	}

	aes_key_expand_128(params->key, round_keys);

	result->precheck_passed =
		run_cpu_correctness_check(input, expected, output, length,
					  pattern, 1U, params,
					  round_keys, "pre");

	if (!result->precheck_passed)
		goto out;

	fill_input_pattern(input, length, pattern, 100U);
	memset(output, OUTPUT_SENTINEL, length);

	if (clock_gettime(CLOCK_MONOTONIC, &wall_start) < 0) {
		perror("clock_gettime(CLOCK_MONOTONIC)");
		goto out;
	}

	if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu_start) < 0) {
		perror("clock_gettime(CLOCK_PROCESS_CPUTIME_ID)");
		goto out;
	}

	for (run = 0; run < iterations; ++run) {
		struct timespec start = { 0 };
		struct timespec end = { 0 };
		uint64_t latency_ns;

		if (clock_gettime(CLOCK_MONOTONIC, &start) < 0) {
			perror("clock_gettime(CLOCK_MONOTONIC)");
			goto out;
		}

		aes_ctr_software_reference_with_round_keys(input, output, length,
							   round_keys,
							   params->nonce,
							   params->initial_counter);

		cpu_output_sink ^= output[run % length];

		if (clock_gettime(CLOCK_MONOTONIC, &end) < 0) {
			perror("clock_gettime(CLOCK_MONOTONIC)");
			goto out;
		}

		latency_ns = elapsed_ns(&start, &end);

		++result->successful_iterations;
		result->latency_sum_ns += latency_ns;

		if (latency_ns < result->latency_min_ns)
			result->latency_min_ns = latency_ns;

		if (latency_ns > result->latency_max_ns)
			result->latency_max_ns = latency_ns;
	}

	if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu_end) < 0) {
		perror("clock_gettime(CLOCK_PROCESS_CPUTIME_ID)");
		goto out;
	}

	if (clock_gettime(CLOCK_MONOTONIC, &wall_end) < 0) {
		perror("clock_gettime(CLOCK_MONOTONIC)");
		goto out;
	}

	result->wall_time_ns = elapsed_ns(&wall_start, &wall_end);
	result->cpu_time_ns = elapsed_ns(&cpu_start, &cpu_end);
	result->total_payload_bytes =
		(uint64_t)length * (uint64_t)result->successful_iterations;

	if (!result->successful_iterations)
		result->latency_min_ns = 0U;

	result->postcheck_passed =
		run_cpu_correctness_check(input, expected, output, length,
					  pattern, 2U, params,
					  round_keys, "post");

	result->passed =
		result->precheck_passed &&
		result->postcheck_passed &&
		result->successful_iterations == iterations &&
		result->failed_iterations == 0U;

	ret = result->passed ? 0 : -1;

out:
	free(output);
	free(expected);
	free(input);
	return ret;
}

static double average_latency_us(const struct benchmark_result *result)
{
	if (!result->successful_iterations)
		return 0.0;

	return ns_to_us(result->latency_sum_ns /
			(uint64_t)result->successful_iterations);
}

static void print_result_header(void)
{
	printf("\n");
	printf("%-8s %-10s %-8s %-12s %-12s %-12s %-12s %-10s %-8s %-8s %-8s %-8s\n",
	       "Mode", "Size", "Runs", "Avg us", "Min us", "Max us",
	       "MiB/s", "CPU %", "Fail", "Tmo", "Err", "Result");
}

static void print_result_row(const char *mode,
			     const struct benchmark_result *result)
{
	printf("%-8s %-10" PRIu32 " %-8" PRIu32 " %-12.3f %-12.3f %-12.3f "
	       "%-12.3f %-10.2f %-8" PRIu32 " %-8" PRIu64 " %-8" PRIu64 " %-8s\n",
	       mode,
	       result->length,
	       result->requested_iterations,
	       average_latency_us(result),
	       ns_to_us(result->latency_min_ns),
	       ns_to_us(result->latency_max_ns),
	       throughput_mib_per_s(result->total_payload_bytes,
				    result->wall_time_ns),
	       cpu_usage_percent(result->cpu_time_ns,
				 result->wall_time_ns),
	       result->failed_iterations,
	       result->timeout_delta,
	       result->error_delta,
	       result->passed ? "PASS" : "FAIL");
}

static int write_csv_header(FILE *csv)
{
	if (fprintf(csv,
		    "mode,pattern,size_bytes,requested_iterations,"
		    "successful_iterations,failed_iterations,total_payload_bytes,"
		    "wall_time_ms,cpu_time_ms,avg_latency_us,min_latency_us,"
		    "max_latency_us,throughput_mib_s,process_cpu_usage_percent,"
		    "submit_delta,complete_delta,timeout_delta,error_delta,"
		    "precheck_passed,postcheck_passed,result\n") < 0)
		return -1;

	return 0;
}

static int write_csv_row(FILE *csv,
			 const char *mode,
			 enum input_pattern pattern,
			 const struct benchmark_result *result)
{
	if (fprintf(csv,
		    "%s,%s,%" PRIu32 ",%" PRIu32 ",%" PRIu32 ",%" PRIu32 ","
		    "%" PRIu64 ",%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,"
		    "%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ","
		    "%s,%s,%s\n",
		    mode,
		    pattern_name(pattern),
		    result->length,
		    result->requested_iterations,
		    result->successful_iterations,
		    result->failed_iterations,
		    result->total_payload_bytes,
		    ns_to_ms(result->wall_time_ns),
		    ns_to_ms(result->cpu_time_ns),
		    average_latency_us(result),
		    ns_to_us(result->latency_min_ns),
		    ns_to_us(result->latency_max_ns),
		    throughput_mib_per_s(result->total_payload_bytes,
					 result->wall_time_ns),
		    cpu_usage_percent(result->cpu_time_ns,
				      result->wall_time_ns),
		    result->submit_delta,
		    result->complete_delta,
		    result->timeout_delta,
		    result->error_delta,
		    result->precheck_passed ? "yes" : "no",
		    result->postcheck_passed ? "yes" : "no",
		    result->passed ? "PASS" : "FAIL") < 0)
		return -1;

	return 0;
}

static int run_one_length(FILE *csv,
			  int fd,
			  const struct zybo_aes_ctr_dma_caps *caps,
			  const struct cli_options *options,
			  const struct aes_ctr_parameters *params,
			  uint32_t length,
			  uint32_t iterations)
{
	struct benchmark_result result;
	int overall_ret = 0;

	if (options->benchmark_mode == BENCHMARK_MODE_FPGA ||
	    options->benchmark_mode == BENCHMARK_MODE_COMPARE) {
		if (run_fpga_benchmark_case(fd, caps, length, iterations,
					    options->timeout_ms,
					    options->pattern, params,
					    &result) < 0)
			overall_ret = -1;

		print_result_row("fpga", &result);

		if (write_csv_row(csv, "fpga", options->pattern, &result) < 0) {
			perror("write CSV FPGA row");
			return -1;
		}
	}

	if (options->benchmark_mode == BENCHMARK_MODE_CPU ||
	    options->benchmark_mode == BENCHMARK_MODE_COMPARE) {
		if (run_cpu_benchmark_case(length, iterations,
					   options->pattern, params,
					   &result) < 0)
			overall_ret = -1;

		print_result_row("cpu", &result);

		if (write_csv_row(csv, "cpu", options->pattern, &result) < 0) {
			perror("write CSV CPU row");
			return -1;
		}
	}

	return overall_ret;
}

static int run_sweep(FILE *csv,
		     int fd,
		     const struct zybo_aes_ctr_dma_caps *caps,
		     const struct cli_options *options,
		     const struct aes_ctr_parameters *params)
{
	size_t i;
	int overall_ret = 0;

	print_result_header();

	for (i = 0; i < sizeof(standard_cases) / sizeof(standard_cases[0]); ++i) {
		const struct benchmark_case *test = &standard_cases[i];

		if (run_one_length(csv, fd, caps, options, params,
				   test->length, test->iterations) < 0)
			overall_ret = -1;
	}

	return overall_ret;
}

static int run_single(FILE *csv,
		      int fd,
		      const struct zybo_aes_ctr_dma_caps *caps,
		      const struct cli_options *options,
		      const struct aes_ctr_parameters *params)
{
	print_result_header();

	return run_one_length(csv, fd, caps, options, params,
			      options->single_length,
			      options->single_iterations);
}

int main(int argc, char **argv)
{
	struct cli_options options;
	struct aes_ctr_parameters aes_params;
	struct zybo_aes_ctr_accel_info info = { 0 };
	struct zybo_aes_ctr_dma_caps caps = { 0 };
	struct zybo_aes_ctr_status status = { 0 };
	FILE *csv = NULL;
	int fd = -1;
	int benchmark_ret;
	int ret = EXIT_FAILURE;
	bool need_fpga = false;

	if (parse_options(argc, argv, &options) < 0) {
		print_usage(argv[0]);
		return EXIT_FAILURE;
	}

	if (parse_aes_parameters(&options, &aes_params) < 0)
		return EXIT_FAILURE;

	need_fpga = options.benchmark_mode == BENCHMARK_MODE_FPGA ||
		    options.benchmark_mode == BENCHMARK_MODE_COMPARE;

	if (need_fpga) {
		fd = open(options.device_path, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			return die_errno("open device");

		if (ioctl(fd, ZYBO_AES_CTR_IOCTL_GET_INFO, &info) < 0) {
			ret = die_errno("ioctl(GET_INFO)");
			goto out;
		}

		if (ioctl(fd, ZYBO_AES_CTR_IOCTL_GET_DMA_CAPS, &caps) < 0) {
			ret = die_errno("ioctl(GET_DMA_CAPS)");
			goto out;
		}

		if (validate_timeout(options.timeout_ms, &caps) < 0) {
			fprintf(stderr,
				"error: timeout %" PRIu32
				" exceeds driver maximum %" PRIu32 "\n",
				options.timeout_ms, caps.max_timeout_ms);
			goto out;
		}

		if (ioctl(fd, ZYBO_AES_CTR_IOCTL_SET_CONFIG,
			  &aes_params.driver_config) < 0) {
			ret = die_errno("ioctl(SET_CONFIG)");
			goto out;
		}

		if (ioctl(fd, ZYBO_AES_CTR_IOCTL_GET_STATUS, &status) < 0) {
			ret = die_errno("ioctl(GET_STATUS)");
			goto out;
		}
	}

	csv = fopen(options.csv_path, "w");
	if (!csv) {
		ret = die_errno("open CSV output");
		goto out;
	}

	if (write_csv_header(csv) < 0) {
		ret = die_errno("write CSV header");
		goto out;
	}

	printf("Benchmark mode   : %s\n", benchmark_mode_name(options.benchmark_mode));
	printf("Size mode        : %s\n",
	       options.size_mode == BENCHMARK_SWEEP ? "standard sweep" : "single size");
	printf("Pattern          : %s\n", options.pattern_name);
	printf("CSV output       : %s\n", options.csv_path);

	if (need_fpga) {
		printf("Device path      : %s\n", options.device_path);
		print_info(&info);
		print_caps(&caps);
		print_status(&status);
		printf("Requested timeout: %" PRIu32 " ms%s\n",
		       options.timeout_ms,
		       options.timeout_ms ? "" : " (driver default)");
	} else {
		printf("Device path      : not used in CPU mode\n");
		printf("Requested timeout: not used in CPU mode\n");
	}

	printf("FPGA timing      : blocking SUBMIT ioctl only\n");
	printf("CPU timing       : software AES-CTR encryption only\n");
	printf("Correctness      : pre-check and post-check per size\n");
	print_hex_bytes("AES key", aes_params.key, sizeof(aes_params.key));
	print_hex_bytes("AES nonce", aes_params.nonce, sizeof(aes_params.nonce));
	printf("%-18s: %08" PRIx32 "\n",
	       "Initial counter", aes_params.initial_counter);

	if (options.size_mode == BENCHMARK_SWEEP) {
		benchmark_ret = run_sweep(csv, fd, &caps, &options, &aes_params);
	} else {
		benchmark_ret = run_single(csv, fd, &caps, &options, &aes_params);
	}

	if (fflush(csv) < 0) {
		ret = die_errno("flush CSV output");
		goto out;
	}

	ret = benchmark_ret == 0 ? EXIT_SUCCESS : EXIT_FAILURE;

out:
	if (csv && fclose(csv) < 0 && ret == EXIT_SUCCESS)
		ret = die_errno("close CSV output");

	if (fd >= 0 && close(fd) < 0 && ret == EXIT_SUCCESS)
		ret = die_errno("close device");

	puts(ret == EXIT_SUCCESS ? "\nOverall result    : PASS" :
					 "\nOverall result    : FAIL");
	return ret;
}