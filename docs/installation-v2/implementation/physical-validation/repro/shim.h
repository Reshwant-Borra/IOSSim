#include <CommonCrypto/CommonDigest.h>
static inline unsigned char *CC_SHA1_shim(const void *data, CC_LONG len, unsigned char *md) {
    return CC_SHA1(data, len, md);
}
