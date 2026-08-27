// TLSRealCoreAdapter.h
// TLSProducerBridge/Core
//
// Real C Core adapter — wraps ve-tls-c-sdk v0.3.1.
//
// This is the ObjC bridge between the Swift CoreAdapter protocol and the C
// Core ABI. It owns the ve_tls_producer lifecycle, the NSURLSession HTTP
// client bridge, and the send-done callback → Swift SendResult mapping.
//
// Threading: the C Core creates its own sender/packer threads via the
// platform abstraction. All public methods are safe to call from any thread;
// the C Core serializes internally.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for TLSRealCoreAdapter errors.
FOUNDATION_EXPORT NSErrorDomain const TLSRealCoreAdapterErrorDomain;

/// Error codes for TLSRealCoreAdapter.
typedef NS_ENUM(NSInteger, TLSRealCoreAdapterErrorCode) {
    /// The C Core producer could not be created.
    TLSRealCoreAdapterErrorCodeCreateFailed = 3001,
    /// A log could not be added (queue full / buffer full / invalid).
    TLSRealCoreAdapterErrorCodeAddFailed = 3002,
    /// Credentials update failed.
    TLSRealCoreAdapterErrorCodeCredentialsUpdateFailed = 3003,
    /// Destination update failed.
    TLSRealCoreAdapterErrorCodeDestinationUpdateFailed = 3004,
    /// The adapter is closed.
    TLSRealCoreAdapterErrorCodeClosed = 3005,
};

/// Real C Core adapter.
///
/// One instance per Producer. Wraps a ve_tls_producer from the C Core.
/// Configuration is passed as individual parameters to avoid ObjC class
/// linking issues across SwiftPM target boundaries.
@interface TLSRealCoreAdapter : NSObject

/// Optional session configuration override for testing. When set, the HTTP
/// bridge uses this configuration instead of the default ephemeral one.
/// This allows tests to inject custom NSURLProtocol stubs.
@property (class, nonatomic, strong, nullable) NSURLSessionConfiguration *testSessionConfiguration;

/// Creates a real core adapter.
/// Returns nil and sets `error` if the C Core producer could not be created.
- (nullable instancetype)initWithEndpoint:(NSString *)endpoint
                                    region:(NSString *)region
                                  projectID:(NSString *)projectID
                                    topicID:(NSString *)topicID
                                accessKeyID:(NSString *)accessKeyID
                            accessKeySecret:(NSString *)accessKeySecret
                             securityToken:(nullable NSString *)securityToken
                                    source:(NSString *)source
                                  fileName:(nullable NSString *)fileName
                                      tags:(nullable NSDictionary<NSString *, NSString *> *)tags
                               maxLogCount:(NSInteger)maxLogCount
                               maxRawBytes:(NSInteger)maxRawBytes
                                    linger:(NSTimeInterval)linger
                            maxBufferBytes:(NSInteger)maxBufferBytes
                            connectTimeout:(NSTimeInterval)connectTimeout
                            requestTimeout:(NSTimeInterval)requestTimeout
                                lz4Enabled:(BOOL)lz4Enabled
                         persistenceEnabled:(BOOL)persistenceEnabled
                       persistentDirectory:(nullable NSString *)persistentDirectory
                           maxLogAgeSeconds:(NSInteger)maxLogAgeSeconds
                          expiredLogPolicy:(NSInteger)expiredLogPolicy
                         authFailurePolicy:(NSInteger)authFailurePolicy
                             callbackQueue:(dispatch_queue_t)callbackQueue
                                      error:(NSError * _Nullable * _Nullable)error
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Adds a log event. The event is converted to C key-value pairs and
/// passed to the C Core. `flush` corresponds to AddMode.immediate.
/// Returns YES on success, NO and sets `error` on failure.
- (BOOL)addLogWithTimestamp:(int64_t)timestampMs
                    hashKey:(nullable NSString *)hashKey
                   contents:(NSDictionary<NSString *, NSString *> *)contents
                      flush:(BOOL)flush
                      error:(NSError * _Nullable * _Nullable)error;

/// Updates credentials (whole-group atomic replacement).
- (BOOL)updateCredentials:(NSString *)accessKeyID
           accessKeySecret:(NSString *)accessKeySecret
            securityToken:(nullable NSString *)securityToken
                    error:(NSError * _Nullable * _Nullable)error;

/// Updates the destination (endpoint/region/topicID).
- (BOOL)updateDestination:(NSString *)endpoint
                   region:(NSString *)region
                  topicID:(NSString *)topicID
                    error:(NSError * _Nullable * _Nullable)error;

/// Closes the producer. Bounded local shutdown; does not promise remote
/// delivery of accepted logs.
- (void)closeWithTimeout:(NSTimeInterval)timeout;

/// Flushes pending batches (best-effort).
- (void)flush;

/// The send-result callback. Set by the Swift layer before open.
/// Delivered on the configured callback queue.
@property (nonatomic, copy, nullable) void (^onSendResult)(
    int32_t result,
    NSUInteger rawBytes,
    NSUInteger compressedBytes,
    NSString * _Nullable requestID,
    NSString * _Nullable errorMessage,
    int64_t startID,
    int64_t endID);

/// YES until close is called.
@property (nonatomic, readonly) BOOL isClosed;

@end

NS_ASSUME_NONNULL_END
