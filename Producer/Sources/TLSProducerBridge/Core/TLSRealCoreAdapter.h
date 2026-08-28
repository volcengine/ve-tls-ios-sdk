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

/// Safe, structured fields attached to bridge errors and send-result
/// callbacks. Values are numeric or sanitized strings only; URL, credentials,
/// authorization headers, and response bodies are never included.
FOUNDATION_EXPORT NSString *const TLSRealCoreAdapterErrorResultKey;
FOUNDATION_EXPORT NSString *const TLSRealCoreAdapterErrorHTTPCodeKey;
FOUNDATION_EXPORT NSString *const TLSRealCoreAdapterErrorCodeKey;
FOUNDATION_EXPORT NSString *const TLSRealCoreAdapterErrorRequestIDKey;
FOUNDATION_EXPORT NSString *const TLSRealCoreAdapterErrorTransportKindKey;
FOUNDATION_EXPORT NSString *const TLSRealCoreAdapterErrorTransportCodeKey;
FOUNDATION_EXPORT NSString *const TLSRealCoreAdapterErrorRetryableKey;

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
    /// Persistent WAL recovery failed.
    TLSRealCoreAdapterErrorCodeRecoveryFailed = 3006,
    /// Core shutdown failed or exceeded its timeout.
    TLSRealCoreAdapterErrorCodeCloseFailed = 3007,
    /// An adapter argument was out of range or otherwise invalid.
    TLSRealCoreAdapterErrorCodeInvalidArgument = 3008,
};

/// Persistence mode values accepted by the bridge initializer. `memory` is
/// intentionally represented by 0, the same as disabled: the C Core only has
/// a disk-backed persistence switch and must not create a WAL for memory mode.
typedef NS_ENUM(NSInteger, TLSRealCoreAdapterPersistenceMode) {
    TLSRealCoreAdapterPersistenceModeDisabled = 0,
    TLSRealCoreAdapterPersistenceModeBuffered = 1,
    TLSRealCoreAdapterPersistenceModeSync = 2,
};

/// Callback payload. The message is always a stable, sanitized summary; the
/// structured fields carry the information needed for classification.
typedef void (^TLSRealCoreAdapterSendResultHandler)(
    int32_t result,
    NSUInteger rawBytes,
    NSUInteger compressedBytes,
    NSInteger httpCode,
    NSString * _Nullable errorCode,
    NSString * _Nullable errorMessage,
    NSString * _Nullable requestID,
    NSInteger transportKind,
    NSInteger transportCode,
    BOOL retryable,
    int64_t startID,
    int64_t endID);

/// Real C Core adapter.
///
/// One instance per Producer. Wraps a ve_tls_producer from the C Core.
/// Configuration is passed as individual parameters to keep the bridge ABI
/// explicit and free of public Swift configuration types.
@interface TLSRealCoreAdapter : NSObject

/// Package-internal build probe. The C symbol remains hidden; tests observe
/// the integrated Core version through the bridge boundary.
@property (class, nonatomic, readonly, copy) NSString *coreVersion;

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
                              sessionConfiguration:(nullable NSURLSessionConfiguration *)sessionConfiguration
                              bufferFullPolicy:(NSInteger)bufferFullPolicy
                             sendConcurrency:(NSInteger)sendConcurrency
                        bufferFullBlockTimeout:(NSTimeInterval)bufferFullBlockTimeout
                             persistenceMode:(TLSRealCoreAdapterPersistenceMode)persistenceMode
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

/// Updates the destination. The v0.3.1 C API has no independent project-ID
/// wire/update field; project ID is retained as part of the bridge's atomic
/// destination snapshot while the C sender target is determined by
/// endpoint/region/topic. Endpoint/region/topic updates are passed
/// transactionally to the C Core.
- (BOOL)updateDestination:(NSString *)endpoint
                   region:(NSString *)region
                 projectID:(NSString *)projectID
                   topicID:(NSString *)topicID
                    error:(NSError * _Nullable * _Nullable)error;

/// Performs the explicit persistent recovery pass. Must be called after the
/// send-result handler has been installed and before the adapter is exposed to
/// callers.
- (BOOL)openWithError:(NSError * _Nullable * _Nullable)error;

/// Closes the producer. Bounded local shutdown; does not promise remote
/// delivery of accepted logs. Returns NO on timeout/failure; a failed close
/// leaves the adapter in closing state so a later call may retry.
- (BOOL)closeWithTimeout:(NSTimeInterval)timeout
                    error:(NSError * _Nullable * _Nullable)error;

/// Flushes pending batches (best-effort).
- (void)flush;

/// The send-result callback. Set by the Swift layer before open.
/// Delivered on the configured callback queue.
@property (nonatomic, copy, nullable) TLSRealCoreAdapterSendResultHandler onSendResult;

/// YES only after a close has completed successfully.
@property (nonatomic, readonly) BOOL isClosed;

@end

NS_ASSUME_NONNULL_END
