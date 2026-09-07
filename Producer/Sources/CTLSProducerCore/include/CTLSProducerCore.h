//
//  CTLSProducerCore.h
//  CTLSProducerCore
//
//  Umbrella header for the vendored C Core (base release v0.3.1).
//
//  The C Core is a pure C library providing the persistent producer engine
//  (WAL, retry, batching, signing, compression). This umbrella re-exports
//  the public C headers so the ObjC Bridge layer (TLSRealCoreAdapter) can
//  consume them.
//
//  Synchronized C Core commit: a172dfbb548cbf1aaae9efea02889dd57570271d
//  See Producer/CORE_VERSION for the frozen release record.
//

#ifndef CTLSProducerCore_h
#define CTLSProducerCore_h

// C Core public headers (vendored from the synchronized core/include/ tree)
#include "ve_tls_version.h"
#include "ve_tls_export.h"
#include "ve_tls_error.h"
#include "ve_tls_http.h"
#include "ve_tls_retry.h"
#include "ve_tls_platform.h"
#include "ve_tls_producer.h"
#include "ve_tls_alloc.h"
#include "ve_tls_compress.h"
#include "ve_tls_env.h"
#include "ve_tls_hash.h"
#include "ve_tls_proto.h"
#include "ve_tls_sign.h"

#ifdef __cplusplus
extern "C" {
#endif

// Version probe — returns the C Core version string.
const char *ve_tls_iosp_core_version(void);

#ifdef __cplusplus
}
#endif

// ve_tls_export.h starts a translation-unit-wide hidden-visibility scope for
// embedded Core sources. Consumers of this umbrella (the Objective-C bridge
// and package tests) restore their surrounding visibility after importing the
// Core declarations.
#if defined(VE_TLS_PACKAGE_INTERNAL) && (defined(__GNUC__) || defined(__clang__))
#  pragma GCC visibility pop
#endif

#endif /* CTLSProducerCore_h */
