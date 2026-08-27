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

#import "TLSRedactingLogger.h"
#import "TLSThreadAssertions.h"
#import "TLSSerialQueueFactory.h"
#import "TLSRealCoreAdapter.h"
