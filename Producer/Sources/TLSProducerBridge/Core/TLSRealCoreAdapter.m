// TLSRealCoreAdapter.m
// TLSProducerBridge/Core
//
// Real C Core adapter implementation — wraps ve-tls-c-sdk v0.3.1.
//

#import "TLSRealCoreAdapter.h"
#import "CTLSProducerCore.h"
#import "Bridge/TLSRedactingLogger.h"
#import "Bridge/TLSThreadAssertions.h"

NSErrorDomain const TLSRealCoreAdapterErrorDomain = @"com.volcengine.tls.producer.realcore";

// MARK: - Class extension (must be visible before the C callback)

@interface TLSRealCoreAdapter ()
@property (nonatomic, assign) ve_tls_producer *producer;
@property (nonatomic, strong) dispatch_queue_t callbackQueue;
@property (nonatomic, assign) BOOL closed;
@end

// MARK: - HTTP client bridge (NSURLSession → sync C interface)

/// Synchronous HTTP request implementation backed by NSURLSession.
/// The C Core calls this from its sender thread; we block on a semaphore
/// until NSURLSession completes.
static int tls_http_do_request(ve_tls_http_client *client,
                                const ve_tls_http_request *req,
                                ve_tls_http_response *resp) {
    if (!client || !req || !resp || !req->url) {
        return -1;
    }

    NSString *urlString = [NSString stringWithUTF8String:req->url];
    if (!urlString) {
        return -1;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        return -1;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    if (req->method) {
        request.HTTPMethod = [NSString stringWithUTF8String:req->method];
    }
    if (req->body && req->body_size > 0) {
        request.HTTPBody = [NSData dataWithBytes:req->body length:req->body_size];
    }
    if (req->connect_timeout_ms > 0) {
        request.timeoutInterval = (NSTimeInterval)req->connect_timeout_ms / 1000.0;
    }

    // Parse headers (newline-separated "Key: Value" lines)
    if (req->headers) {
        NSString *headers = [NSString stringWithUTF8String:req->headers];
        if (headers) {
            NSArray<NSString *> *lines = [headers componentsSeparatedByString:@"\n"];
            for (NSString *line in lines) {
                NSRange colon = [line rangeOfString:@":"];
                if (colon.location != NSNotFound && colon.location > 0) {
                    NSString *key = [[line substringToIndex:colon.location]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *value = [[line substringFromIndex:colon.location + 1]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (key.length > 0 && value) {
                        [request setValue:value forHTTPHeaderField:key];
                    }
                }
            }
        }
    }

    // Use a dedicated ephemeral session (no cache/cookies)
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = (NSTimeInterval)(req->timeout_ms > 0 ? req->timeout_ms : 30000) / 1000.0;
    config.URLCache = nil;
    config.HTTPCookieStorage = nil;
    config.URLCredentialStorage = nil;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSHTTPURLResponse *httpResponse = nil;
    __block NSData *responseData = nil;
    __block NSError *requestError = nil;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            httpResponse = (NSHTTPURLResponse *)response;
            responseData = data;
            requestError = error;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];

    // Wait with the request timeout (plus margin)
    int64_t waitMs = req->timeout_ms > 0 ? req->timeout_ms + 5000 : 35000;
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, waitMs * NSEC_PER_MSEC));
    [session finishTasksAndInvalidate];

    // Fill the C response
    ve_tls_http_response_init(resp);

    if (requestError) {
        resp->transport_kind = VE_TLS_TRANSPORT_GENERIC;
        resp->transport_code = (int32_t)requestError.code;
        resp->transport_retryable = 1;
        resp->error_message = strdup(requestError.localizedDescription.UTF8String ?: "network error");
        return 0;
    }

    if (httpResponse) {
        resp->status_code = (int32_t)httpResponse.statusCode;
        if (responseData) {
            resp->body_size = responseData.length;
            resp->body = malloc(responseData.length);
            if (resp->body) {
                memcpy(resp->body, responseData.bytes, responseData.length);
            }
        }
        // Extract request ID
        NSString *reqID = httpResponse.allHeaderFields[@"x-tls-request-id"];
        if (!reqID) {
            reqID = httpResponse.allHeaderFields[@"X-Tls-Request-Id"];
        }
        if (reqID) {
            resp->request_id = strdup(reqID.UTF8String);
        }
    }

    return 0;
}

static void tls_http_free_response(ve_tls_http_client *client,
                                   ve_tls_http_response *resp) {
    if (!resp) return;
    ve_tls_http_response_init(resp);
    (void)client;
}

// MARK: - Send callback bridge

static void tls_send_done_v2(ve_tls_result result,
                              size_t log_bytes,
                              size_t compressed_bytes,
                              const ve_tls_error *error,
                              const unsigned char *raw_buffer,
                              void *user_param,
                              int64_t start_id,
                              int64_t end_id) {
    TLSRealCoreAdapter *adapter = (__bridge TLSRealCoreAdapter *)user_param;
    if (!adapter) return;

    void (^onSendResult)(int32_t, NSUInteger, NSUInteger, NSString *, NSString *, int64_t, int64_t) =
        adapter.onSendResult;
    if (!onSendResult) return;

    dispatch_queue_t queue = adapter.callbackQueue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    NSString *requestID = nil;
    NSString *errorMessage = nil;
    if (error) {
        if (error->request_id) {
            requestID = [NSString stringWithUTF8String:error->request_id];
        }
        if (error->error_message) {
            errorMessage = [NSString stringWithUTF8String:error->error_message];
        } else if (error->error_code) {
            errorMessage = [NSString stringWithUTF8String:error->error_code];
        }
    }

    int32_t resultCode = (int32_t)result;
    NSUInteger raw = (NSUInteger)log_bytes;
    NSUInteger compressed = (NSUInteger)compressed_bytes;
    int64_t start = start_id;
    int64_t end = end_id;

    dispatch_async(queue, ^{
        onSendResult(resultCode, raw, compressed, requestID, errorMessage, start, end);
    });
}

// MARK: - Adapter implementation

@implementation TLSRealCoreAdapter

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
                                      error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (!self) return nil;

    _callbackQueue = callbackQueue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    _closed = NO;

    // Initialize C Core config
    ve_tls_config cConfig;
    ve_tls_result rc = ve_tls_config_init_versioned(&cConfig, sizeof(cConfig), VE_TLS_CONFIG_VERSION_CURRENT);
    if (rc != VE_TLS_OK) {
        if (error) {
            *error = [NSError errorWithDomain:TLSRealCoreAdapterErrorDomain
                                         code:TLSRealCoreAdapterErrorCodeCreateFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"C Core config init failed"}];
        }
        return nil;
    }

    // Platform (pthread)
    ve_tls_platform_init_default(&cConfig.platform);

    // HTTP client (NSURLSession bridge)
    static ve_tls_http_client httpClient;
    httpClient.do_request = tls_http_do_request;
    httpClient.free_response = tls_http_free_response;
    httpClient.user_data = NULL;
    cConfig.http_client = httpClient;

    // Endpoint / credentials
    cConfig.endpoint = endpoint.UTF8String;
    cConfig.region = region.UTF8String;
    cConfig.topic_id = topicID.UTF8String;
    cConfig.access_key_id = accessKeyID.UTF8String;
    cConfig.access_key_secret = accessKeySecret.UTF8String;
    cConfig.security_token = securityToken.UTF8String;

    // Source / metadata
    cConfig.source = source.UTF8String;
    cConfig.file_name = fileName.UTF8String;
    if (tags.count > 0) {
        NSUInteger count = tags.count;
        ve_tls_kv *tagKV = calloc(count, sizeof(ve_tls_kv));
        NSUInteger i = 0;
        for (NSString *key in tags) {
            tagKV[i].key = key.UTF8String;
            tagKV[i].value = tags[key].UTF8String;
            i++;
        }
        cConfig.log_tags = tagKV;
        cConfig.log_tag_count = count;
    }

    // Batch
    cConfig.log_count_per_package = (int32_t)maxLogCount;
    cConfig.log_bytes_per_package = (int32_t)maxRawBytes;
    cConfig.flush_interval_ms = (int32_t)(linger * 1000);

    // Buffer
    cConfig.max_buffer_bytes = (int32_t)maxBufferBytes;
    cConfig.buffer_full_policy = VE_TLS_BUFFER_FULL_DROP;

    // Timeouts
    cConfig.connect_timeout_ms = (int32_t)(connectTimeout * 1000);
    cConfig.request_timeout_ms = (int32_t)(requestTimeout * 1000);

    // Compression
    cConfig.compress_type = lz4Enabled ? "lz4" : "none";

    // Persistence
    if (persistenceEnabled && persistentDirectory) {
        cConfig.use_persistent = 1;
        cConfig.persistent_file_path = persistentDirectory.UTF8String;
        cConfig.persistent_durability = VE_TLS_PDURABILITY_BUFFERED_WAL;
        cConfig.persistent_max_log_delay_ms = (int64_t)(maxLogAgeSeconds * 1000);
        cConfig.persistent_expired_log_policy =
            (expiredLogPolicy == 1) ? VE_TLS_PEXPIRED_DROP : VE_TLS_PEXPIRED_REWRITE;
        cConfig.persistent_auth_failure_policy =
            (authFailurePolicy == 1) ? VE_TLS_PAUTH_DROP : VE_TLS_PAUTH_RETAIN;
    }

    // Sender
    cConfig.send_thread_count = 1;
    cConfig.pack_thread_count = 1;
    cConfig.ordered_send = 1;

    // Retry
    cConfig.retry_max_attempts = 3;

    // TLS
    cConfig.tls_verify_peer = 1;
    cConfig.tls_verify_host = 1;

    // Create the producer
    _producer = ve_tls_producer_create_versioned(&cConfig, sizeof(cConfig), VE_TLS_CONFIG_VERSION_CURRENT);
    if (!_producer) {
        if (error) {
            *error = [NSError errorWithDomain:TLSRealCoreAdapterErrorDomain
                                         code:TLSRealCoreAdapterErrorCodeCreateFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"C Core producer create failed"}];
        }
        return nil;
    }

    // Set the send callback
    ve_tls_producer_set_send_done_v2(_producer, tls_send_done_v2, (__bridge void *)self);

    return self;
}

- (void)dealloc {
    if (_producer) {
        ve_tls_producer_destroy(_producer);
        _producer = NULL;
    }
}

- (BOOL)addLogWithTimestamp:(int64_t)timestampMs
                    hashKey:(nullable NSString *)hashKey
                   contents:(NSDictionary<NSString *, NSString *> *)contents
                      flush:(BOOL)flush
                      error:(NSError * _Nullable * _Nullable)error {
    if (self.closed) {
        if (error) {
            *error = [NSError errorWithDomain:TLSRealCoreAdapterErrorDomain
                                         code:TLSRealCoreAdapterErrorCodeClosed
                                     userInfo:@{NSLocalizedDescriptionKey: @"adapter is closed"}];
        }
        return NO;
    }

    NSUInteger count = contents.count;
    if (count == 0) return YES;

    ve_tls_kv *kvs = calloc(count, sizeof(ve_tls_kv));
    if (!kvs) {
        if (error) {
            *error = [NSError errorWithDomain:TLSRealCoreAdapterErrorDomain
                                         code:TLSRealCoreAdapterErrorCodeAddFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"memory allocation failed"}];
        }
        return NO;
    }

    NSUInteger i = 0;
    for (NSString *key in contents) {
        kvs[i].key = key.UTF8String;
        kvs[i].value = contents[key].UTF8String;
        i++;
    }

    ve_tls_result rc;
    if (hashKey) {
        rc = ve_tls_producer_add_log_kv_hashkey(_producer, timestampMs,
                                                 hashKey.UTF8String,
                                                 kvs, count,
                                                 flush ? 1 : 0);
    } else {
        rc = ve_tls_producer_add_log_kv(_producer, timestampMs, kvs, count, flush ? 1 : 0);
    }

    free(kvs);

    if (rc != VE_TLS_OK) {
        if (error) {
            NSString *reason = [NSString stringWithFormat:@"C Core add failed (rc=%d)", (int)rc];
            NSInteger code = TLSRealCoreAdapterErrorCodeAddFailed;
            if (rc == VE_TLS_CLOSED) {
                code = TLSRealCoreAdapterErrorCodeClosed;
            }
            *error = [NSError errorWithDomain:TLSRealCoreAdapterErrorDomain
                                         code:code
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }

    return YES;
}

- (BOOL)updateCredentials:(NSString *)accessKeyID
           accessKeySecret:(NSString *)accessKeySecret
            securityToken:(nullable NSString *)securityToken
                    error:(NSError * _Nullable * _Nullable)error {
    if (self.closed) {
        if (error) {
            *error = [NSError errorWithDomain:TLSRealCoreAdapterErrorDomain
                                         code:TLSRealCoreAdapterErrorCodeClosed
                                     userInfo:@{NSLocalizedDescriptionKey: @"adapter is closed"}];
        }
        return NO;
    }

    ve_tls_result rc = ve_tls_producer_update_static_credentials(
        _producer,
        accessKeyID.UTF8String,
        accessKeySecret.UTF8String,
        securityToken.UTF8String);

    if (rc != VE_TLS_OK) {
        if (error) {
            *error = [NSError errorWithDomain:TLSRealCoreAdapterErrorDomain
                                         code:TLSRealCoreAdapterErrorCodeCredentialsUpdateFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"C Core credentials update failed (rc=%d)", (int)rc]}];
        }
        return NO;
    }
    return YES;
}

- (BOOL)updateDestination:(NSString *)endpoint
                   region:(NSString *)region
                  topicID:(NSString *)topicID
                    error:(NSError * _Nullable * _Nullable)error {
    if (self.closed) {
        if (error) {
            *error = [NSError errorWithDomain:TLSRealCoreAdapterErrorDomain
                                         code:TLSRealCoreAdapterErrorCodeClosed
                                     userInfo:@{NSLocalizedDescriptionKey: @"adapter is closed"}];
        }
        return NO;
    }

    ve_tls_result rc = ve_tls_producer_update_endpoint(
        _producer,
        endpoint.UTF8String,
        region.UTF8String,
        topicID.UTF8String);

    if (rc != VE_TLS_OK) {
        if (error) {
            *error = [NSError errorWithDomain:TLSRealCoreAdapterErrorDomain
                                         code:TLSRealCoreAdapterErrorCodeDestinationUpdateFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"C Core destination update failed (rc=%d)", (int)rc]}];
        }
        return NO;
    }
    return YES;
}

- (void)closeWithTimeout:(NSTimeInterval)timeout {
    if (self.closed) return;
    self.closed = YES;

    int32_t timeoutMs = (int32_t)(timeout * 1000);
    ve_tls_producer_close(_producer, timeoutMs);
}

- (void)flush {
    if (!self.closed) {
        ve_tls_producer_flush(_producer);
    }
}

@end
