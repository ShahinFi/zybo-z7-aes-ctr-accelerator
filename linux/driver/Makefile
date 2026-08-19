# SPDX-License-Identifier: MIT

obj-m += zybo-aes-ctr-accel.o
zybo-aes-ctr-accel-y := zybo_aes_ctr_accel.o

# PetaLinux provides KERNEL_SRC. For standalone builds, use the host kernel tree.
MODULE_KERNEL_DIR := $(KERNEL_SRC)

ifeq ($(strip $(MODULE_KERNEL_DIR)),)
MODULE_KERNEL_DIR := /lib/modules/$(shell uname -r)/build
endif

MODULE_SRC_DIR := $(shell pwd)

all:
	$(MAKE) -C $(MODULE_KERNEL_DIR) M=$(MODULE_SRC_DIR) modules

modules_install:
	$(MAKE) -C $(MODULE_KERNEL_DIR) M=$(MODULE_SRC_DIR) modules_install

clean:
	$(MAKE) -C $(MODULE_KERNEL_DIR) M=$(MODULE_SRC_DIR) clean
