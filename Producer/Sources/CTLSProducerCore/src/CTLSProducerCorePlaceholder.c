//
//  CTLSProducerCorePlaceholder.c
//  CTLSProducerCore
//
//  PLACEHOLDER — remove when real sources land.
//
//  Implements nothing except a namespaced version probe symbol so the C target
//  has at least one translation unit. It does NOT implement any queue/retry/
//  WAL/signing/compression behavior.
//

#include "CTLSProducerCore.h"

const char *ve_tls_iosp_core_version(void) {
    return "0.0.0-placeholder";
}
