# SPDX-License-Identifier: MIT
# Build rules for the AES-CTR validation and benchmark applications.

CC ?= gcc
CPPFLAGS ?=
CPPFLAGS += -I../driver
CFLAGS ?= -O2 -Wall -Wextra -Werror -std=c11
LDFLAGS ?=

TARGETS := zybo_aes_ctr_test zybo_aes_ctr_bench

.PHONY: all clean

all: $(TARGETS)

zybo_aes_ctr_test: zybo_aes_ctr_test.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $< $(LDFLAGS)

zybo_aes_ctr_bench: zybo_aes_ctr_bench.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGETS)
