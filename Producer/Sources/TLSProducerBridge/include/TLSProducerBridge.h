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

// Path-qualified imports: SwiftPM's headerSearchPath(".") makes the
// TLSProducerBridge directory a header search path (not its subdirectories),
// so flat filenames would fail to resolve. The qualified form also resolves
// under CocoaPods (HEADER_SEARCH_PATHS includes the source directory).
#import "Bridge/TLSRedactingLogger.h"
#import "Bridge/TLSThreadAssertions.h"
#import "Bridge/TLSSerialQueueFactory.h"
#import "Core/TLSRealCoreAdapter.h"
#import "Storage/TLSProducerDirectory.h"
#import "Lifecycle/TLSLifecycleManager.h"

// Wave 2 Worker D — NSURLSession transport (package-internal).
#import "Transport/TLSHTTPRequest.h"
#import "Transport/TLSHTTPResponse.h"
#import "Transport/TLSTransport.h"
