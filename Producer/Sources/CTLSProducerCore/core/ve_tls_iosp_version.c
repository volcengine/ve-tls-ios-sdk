// ve_tls_iosp_version.c
// CTLSProducerCore
//
// Version probe for the vendored C Core. Returns the C Core version string.
// The real version comes from ve_tls_version.h; this wraps it for the
// iOS SDK's symbol namespace check.
//

#include "ve_tls_version.h"

const char *ve_tls_iosp_core_version(void) {
    return VE_TLS_C_SDK_VERSION;
}
