//
//  TLSNetworking.m
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/10.
//

#import "VeNetworking.h"
#import "VeSynchronizedMutableDictionary.h"
#import "VeSign.h"
#import "NSDate+Ve.h"
#import "VeNetworkingDelegate.h"


@interface VeNetworking()

@property (nonatomic) BOOL isSessionValid;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) VeSynchronizedMutableDictionary *networkingDelegates;
@property (nonatomic, strong) VeNetworkingConfiguration *networkingConfiguration;
@property (nonatomic, strong) NSString *serviceName;

@end

@implementation VeNetworking


- (instancetype)initWithConfiguration:(VeNetworkingConfiguration *)configuration serviceName: (NSString *)service {
    if (self = [super init]) {
        _serviceName = service;
        _networkingConfiguration = configuration;
        
        NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
        
        sessionConfiguration.allowsCellularAccess = YES;
        sessionConfiguration.allowsExpensiveNetworkAccess = YES;
        sessionConfiguration.allowsConstrainedNetworkAccess = YES;
        
        NSOperationQueue * sessionQueue = [NSOperationQueue new];
        
        _session = [NSURLSession sessionWithConfiguration:sessionConfiguration
                                                 delegate:self
                                            delegateQueue:sessionQueue];
        
        _networkingDelegates = [VeSynchronizedMutableDictionary new];
        _isSessionValid = YES;
    }
    
    return self;
}

- (VeTask *)sendRequest: (VeNetworkingRequest *)veNetworkingRequest {
    VeNetworkingDelegate *delegate = [VeNetworkingDelegate new];
    
    delegate.request = veNetworkingRequest;
    delegate.taskCompletionSource = [VeTaskCompletionSource taskCompletionSource];
    
    [self taskWithDelegate:delegate];
    
    return delegate.taskCompletionSource.task;
}

- (void)taskWithDelegate:(VeNetworkingDelegate *)delegate {
    if (!self.session || !self.isSessionValid) {
        delegate.taskCompletionSource.error = [NSError errorWithDomain: VeNetworkingErrorDomain
                                                                  code: VeNetworkingErrorSessionInvalid
                                                              userInfo:@{NSLocalizedDescriptionKey: @"URLSession is nil or invalidated"}];
        return;
    }
    
    NSMutableURLRequest *mutableRequest = [NSMutableURLRequest requestWithURL: delegate.request.url];
    mutableRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    VeNetworkingRequest *request = delegate.request;
    
    if (request.isCancelled) {
        delegate.taskCompletionSource.error = [NSError errorWithDomain: VeNetworkingErrorDomain
                                                                  code: VeNetworkingErrorCancelled
                                                              userInfo:nil];
        return;
    }
    
    [mutableRequest setHTTPMethod: [NSString ve_stringWithHTTPMethod: delegate.request.HTTPMethod]];
    [mutableRequest setValue:[[NSDate ve_clockSkewFixedDate] ve_stringValue:VeDateISO8601DateFormat2]
          forHTTPHeaderField:@"X-Date"];
    
    bool contentTypeSet = false;
    for (NSString *key in delegate.request.headers) {
        if ([key isEqualToString:@"Content-Type"]) {
            contentTypeSet = true;
        }
        [mutableRequest setValue:delegate.request.headers[key] forHTTPHeaderField:key];
    }
    if (contentTypeSet == false && delegate.request.HTTPMethod != VeHTTPMethodGET) {
        [mutableRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [mutableRequest setValue:[NSString stringWithFormat:@"%lu", delegate.request.requstBody.length] forHTTPHeaderField:@"Content-Length"];
    }
    
    if (delegate.request.HTTPMethod != VeHTTPMethodGET) {
        [mutableRequest setHTTPBody:delegate.request.requstBody];
    }
    
    VeSign *sign = [[VeSign alloc] initWithCredential:self.networkingConfiguration.credential withService:self.serviceName withRegion:self.networkingConfiguration.endpoint.region];
    
    [sign signRequest:mutableRequest];
    
    VeTask *task = [VeTask taskWithResult:nil];
    
    [task continueWithSuccessBlock:^id _Nullable(VeTask * _Nonnull t) {
        delegate.request.task = [self.session dataTaskWithRequest:mutableRequest];
        
        [self.networkingDelegates setObject:delegate
                                     forKey:@(((NSURLSessionTask *)delegate.request.task).taskIdentifier)];
        
        [delegate.request.task resume];
        
        return nil;
    }];
    
    
}


#pragma mark - NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error {
    if (session == self.session) {
        self.isSessionValid = NO;
        self.session = nil;
    }
}


#pragma mark - NSURLSessionTaskDelegate

/**
 * 请求完成的回调
 * 在这里去拿到完整的响应数据，进行解析等等
 * 处理错误，比如重试机制
 */
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)sessionTask didCompleteWithError:(NSError *)error {
    
    [[[VeTask taskWithResult:nil] continueWithSuccessBlock:^id _Nullable(VeTask * _Nonnull t) {
            VeNetworkingDelegate *delegate = [self.networkingDelegates objectForKey:@(sessionTask.taskIdentifier)];

            if (!delegate.error) {
                delegate.error = error;
            }
            
            if (!delegate.error && [sessionTask.response isKindOfClass:[NSHTTPURLResponse class]]) {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)sessionTask.response;
                delegate.responseObject = delegate.responseData;
                GeneralHttpResponse *resp = [GeneralHttpResponse alloc]; {
                    if (delegate.responseData == nil) {
                        NSString *emptyJson = @"{}";
                        resp.responseBody = [emptyJson dataUsingEncoding:NSUTF8StringEncoding];
                    } else {
                        resp.responseBody = delegate.responseData;
                    }
                    resp.httpStatusCode = [[NSNumber alloc] initWithLong: httpResponse.statusCode];
                    resp.requestId = httpResponse.allHeaderFields[@"X-Tls-Requestid"];
                }
                [delegate.taskCompletionSource setResult:resp];
            }
            
            return nil;
    }] continueWithSuccessBlock:^id _Nullable(VeTask * _Nonnull t) {
        [self.networkingDelegates removeObjectForKey:@(sessionTask.taskIdentifier)];
        return nil;
    }];
}

#pragma mark - NSURLSessionDataDelegate

// 收到请求头时的回调
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    NSHTTPURLResponse * httpResponse = (NSHTTPURLResponse *)response;
    // NSInteger httpcode = httpResponse.statusCode;
    // NSLog(@"http code %ld", (long)httpcode);
    completionHandler(NSURLSessionResponseAllow);
}

/**
 * 拼接返回数据
 * TODO： 也应该在此方法里处理下载进度
 */
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    VeNetworkingDelegate *delegate = [self.networkingDelegates objectForKey:@(dataTask.taskIdentifier)];
    
    if (!delegate.responseData) {
        delegate.responseData = [NSMutableData dataWithData:data];
    } else if ([delegate.responseData isKindOfClass:[NSMutableData class]]) {
        [delegate.responseData appendData:data];
    }
}



- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential * __nullable credential))completionHandler
{
    if (!challenge) {
        return;
    }
    
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    NSURLCredential *credential = nil;
    
    /*
     * Gets the host name
     */
    
    NSString * host = [[task.currentRequest allHTTPHeaderFields] objectForKey:@"Host"];
    if (!host) {
        host = task.currentRequest.URL.host;
    }
    
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        NSURLCredential *crediential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
        if (completionHandler) {
            completionHandler(NSURLSessionAuthChallengeUseCredential, crediential);
        }
    } else {
        disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    }
    // Uses the default evaluation for other challenges.
    completionHandler(disposition,credential);
}

@end
