SUMMARY = "External Linux kernel module for Zybo AES-CTR accelerator"
SECTION = "PETALINUX/modules"
LICENSE = "GPLv2"
LIC_FILES_CHKSUM = "file://COPYING;md5=12f884d2ae1ff87c09e5b7ccc2c4ca7e"

inherit module

INHIBIT_PACKAGE_STRIP = "1"

SRC_URI = "file://Makefile \
           file://zybo_aes_ctr_accel.c \
           file://zybo_aes_ctr_accel_uapi.h \
           file://COPYING \
"

S = "${WORKDIR}"
