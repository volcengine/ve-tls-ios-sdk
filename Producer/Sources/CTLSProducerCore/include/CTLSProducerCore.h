//
//  CTLSProducerCore.h
//  CTLSProducerCore
//
//  PLACEHOLDER — the real C Core has NOT passed the release gate (see
//  Producer/CORE_VERSION). This header exists only so the SwiftPM/CocoaPods
//  skeleton has a complete C target. It implements NO queue/retry/WAL/signing/
//  compression. Remove when the real Core is vendored.
//

#ifndef CTLSProducerCore_h
#define CTLSProducerCore_h

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Placeholder version probe.
 *
 * Returns a static placeholder string. The real Core provides its own
 * versioned ABI; this symbol exists only to validate the C target toolchain
 * and the symbol namespace (ve_tls_iosp_* prefix).
 */
const char *ve_tls_iosp_core_version(void);

#ifdef __cplusplus
}
#endif

#endif /* CTLSProducerCore_h */
