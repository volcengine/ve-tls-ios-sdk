//
//  TLSProducerBridge.h
//  TLSProducerBridge
//
//  Umbrella header for the TLSProducerBridge module.
//
//  SCOPE: TLSProducerBridge is a package-INTERNAL target, not a public
//  product, and VolcengineTLSProducer does not re-export it. SwiftPM does not
//  enforce access control for transitive target modules, so a source-package
//  consumer may still spell `import TLSProducerBridge`; that unsupported
//  implementation surface has no source/ABI compatibility promise. The
//  headers below exist for the Swift wrapper and package tests. CocoaPods
//  keeps them in PrivateHeaders and out of the public module.
//

#import <Foundation/Foundation.h>

// Package tests use a small set of Core probes through this package-internal
// module. The public Swift product never re-exports this umbrella.
#import "../../CTLSProducerCore/include/CTLSProducerCore.h"

// Path-qualified imports relative to this header's directory (include/).
// The module build (umbrella → modulemap, used when test targets `import
// TLSProducerBridge`) only puts include/ on the header search path — the
// cSettings headerSearchPath(".") reaches the .m compilation but NOT the
// explicit-module build. Relative `../` imports resolve regardless of
// search paths, under SwiftPM, xcodebuild, and CocoaPods alike.
#import "../Bridge/TLSRedactingLogger.h"
#import "../Bridge/TLSThreadAssertions.h"
#import "../Bridge/TLSSerialQueueFactory.h"
#import "../Core/TLSRealCoreAdapter.h"
#import "../Storage/TLSProducerDirectory.h"
#import "../Lifecycle/TLSLifecycleManager.h"

// NSURLSession transport (package-internal).
#import "../Transport/TLSHTTPRequest.h"
#import "../Transport/TLSHTTPResponse.h"
#import "../Transport/TLSTransport.h"
