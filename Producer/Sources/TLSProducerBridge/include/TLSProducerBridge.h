//
//  TLSProducerBridge.h
//  TLSProducerBridge
//
//  Umbrella header for the TLSProducerBridge module.
//
//  SCOPE: TLSProducerBridge is a package-INTERNAL target, not a public
//  product. External consumers only see the VolcengineTLSProducer Swift
//  module (which does not re-export this Clang module). The headers below
//  are exported so that package test targets (BridgeTests/TransportTests/
//  PersistenceTests) can exercise the Bridge helpers; they are not public
//  API of the SDK. The CocoaPods podspec keeps them as private headers.
//

#import <Foundation/Foundation.h>

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

// Wave 2 Worker D — NSURLSession transport (package-internal).
#import "../Transport/TLSHTTPRequest.h"
#import "../Transport/TLSHTTPResponse.h"
#import "../Transport/TLSTransport.h"
