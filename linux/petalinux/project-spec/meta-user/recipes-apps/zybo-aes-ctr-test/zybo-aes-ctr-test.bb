SUMMARY = "User-space validation application for Zybo AES-CTR accelerator"
SECTION = "PETALINUX/apps"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://zybo_aes_ctr_test.c \
           file://zybo_aes_ctr_accel_uapi.h \
"

S = "${WORKDIR}"

do_compile() {
	${CC} ${CFLAGS} ${LDFLAGS} \
		-I${S} \
		-o zybo-aes-ctr-test \
		zybo_aes_ctr_test.c
}

do_install() {
	install -d ${D}${bindir}
	install -m 0755 zybo-aes-ctr-test ${D}${bindir}
}
