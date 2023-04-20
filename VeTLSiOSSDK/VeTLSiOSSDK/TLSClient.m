// Copyright 2023 ByteDance and/or its affiliates.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
#import <Foundation/Foundation.h>
#import <VeTLSiOSSDK/VeNetworking.h>
#import "TLSClient.h"

#define TLS_CLIENT_INTERFACE_IMPLEMENTION(method) \
- (method##Response*) method:(method##Request*)request { \
@try {\
    long long quitTimestamp = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0); \
    if (_config.timeoutMillisecond != nil && [_config.timeoutMillisecond intValue] > 0) { \
        quitTimestamp += [_config.timeoutMillisecond intValue]; \
    } else { \
        quitTimestamp += 10 * 1000; \
    } \
    if ([request checkValidation] == false) { \
        method##Response *response = [method##Response alloc]; { \
            response.errorCode = @"InvalidArguments"; \
            response.errorMessage = @"Lack necessary arguments, please check request"; \
        } \
        return response; \
    } \
    __block method##Response *resp = nil; \
    while(true) { \
        resp = nil; \
        VeTask *innerResponse = [self invokeRequest:request]; \
        __block dispatch_semaphore_t semaphore = dispatch_semaphore_create(0); \
        [innerResponse continueWithBlock:^id _Nullable(VeTask * _Nonnull t) { \
            if (!t.error) { \
                NSError *err = nil; \
                GeneralHttpResponse *innerResp = t.result; \
                resp = [[method##Response alloc] initWithData:innerResp.responseBody error:&err]; \
                resp.statusCode = innerResp.httpStatusCode; \
                resp.requestId = innerResp.requestId; \
            } \
            dispatch_semaphore_signal(semaphore); \
            return nil; \
        }]; \
        if (_config.timeoutMillisecond != nil && [_config.timeoutMillisecond intValue] > 0) { \
            dispatch_semaphore_wait(semaphore, [_config.timeoutMillisecond intValue] * NSEC_PER_MSEC); \
        } else dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER); \
        if (resp == nil || sRetryCodeList == nil) { \
            break; \
        } \
        int needRetry = 0; \
        for (int i=0; i<sRetryCodeList.count; i++) { \
            if ([sRetryCodeList[i] intValue] == [resp.statusCode intValue]) { \
                needRetry = 1; \
            } \
        } \
        if (needRetry == 0 || _config.disableRetry == true) { \
            [self decreaseRetryCounter]; \
            break; \
        } \
        [self increaseRetryCounter]; \
        long long curMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0); \
        long long sleepMs = [self calculateRetrySleepMs:curMs quitTimestamp:quitTimestamp]; \
        if (sleepMs > 0) { \
            [NSThread sleepForTimeInterval:((double)sleepMs)/1000]; \
        } \
        if (curMs >= quitTimestamp) { \
            break; \
        } \
    } \
    return resp; \
} \
@catch (NSException *exception) { \
    method##Response *response = [method##Response alloc]; { \
        response.errorCode = @"CaughtException"; \
        response.errorMessage = [NSString stringWithFormat:@"Exception: %@ Reason: %@", exception.name, exception.reason]; \
    } \
    return response; \
} \
}


@interface TLSClient()
@property (nonatomic, strong) VeNetworkingConfiguration *networkingConfiguration;
@property (nonatomic, strong) VeNetworking *networking;
@end

@implementation TLSClient

static NSArray<NSNumber *> *sRetryCodeList;
static int sRetryCounter;
static NSLock *sCounterMutex;
static int sRetryCounterMaximum;
static int sRetryIntervalMs;

- (void)increaseRetryCounter {
    if (sCounterMutex == nil) {
        return;
    }
    [sCounterMutex lock];
    if (sRetryCounter < sRetryCounterMaximum) {
        sRetryCounter += 1;
    }
    [sCounterMutex unlock];
}

- (void)decreaseRetryCounter {
    if (sCounterMutex == nil) {
        return;
    }
    [sCounterMutex lock];
    if (sRetryCounter > 0) {
        sRetryCounter -= 1;
    }
    [sCounterMutex unlock];
}

- (long long)calculateRetrySleepMs:(long long)currentTimestamp quitTimestamp:(long long)quitTimestamp {
    if (sRetryCounterMaximum <= 0 || sRetryCounter <= 0) {
        return 0;
    }
    long long sleepMs = (rand() % (sRetryCounter + 1)) * sRetryIntervalMs;
    if (currentTimestamp + sleepMs >= quitTimestamp) {
        return quitTimestamp - currentTimestamp;
    }
    return sleepMs;
}

+ (void)initialize {
    if (self == [TLSClient class]) {
        sRetryCodeList = @[@429, @500, @502, @503, @504];
        sRetryCounter = 0;
        sRetryCounterMaximum = 50;
        sRetryIntervalMs = 100;
        sCounterMutex = [[NSLock alloc] init];
    }
}

// For ve http
- (instancetype)initWithConfig:(TLSClientConfig *)config {
    [self calculateRetrySleepMs:1 quitTimestamp:2];
    if (self = [super init]) {
        _config = config;
        VeCredential *credential = [[VeCredential alloc] initWithAccessKey:config.accessKeyId secretKey:config.accessKeySecret];
        VeEndpoint *endpoint = [[VeEndpoint alloc] initWithURLString:config.endpoint region:config.region];
        _networkingConfiguration = [[VeNetworkingConfiguration alloc] initWithEndpoint:endpoint credentail:credential];
        _networking = [[VeNetworking alloc] initWithConfiguration:_networkingConfiguration serviceName:@"TLS"];
    }
    return self;
}

- (VeTask *)invokeRequest: (TLSRequest *)request {
    @autoreleasepool {
        VeNetworkingRequest *networkingRequest = [VeNetworkingRequest alloc]; {
            networkingRequest.requstBody = [request requestBody];
            networkingRequest.headers = [request headerParamsDict];
            NSString *strMethod = [request httpMethod];
            // Set http method
            if ([strMethod isEqualToString:@"GET"]) {
                networkingRequest.HTTPMethod = VeHTTPMethodGET;
            } else if ([strMethod isEqualToString:@"POST"]) {
                networkingRequest.HTTPMethod = VeHTTPMethodPOST;
            } else if ([strMethod isEqualToString:@"PUT"]) {
                networkingRequest.HTTPMethod = VeHTTPMethodPUT;
            } else if ([strMethod isEqualToString:@"DELETE"]) {
                networkingRequest.HTTPMethod = VeHTTPMethodDELETE;
            } else if ([strMethod isEqualToString:@"PATCH"]) {
                networkingRequest.HTTPMethod = VeHTTPMethodPATCH;
            } else if ([strMethod isEqualToString:@"HEAD"]) {
                networkingRequest.HTTPMethod = VeHTTPMethodHEAD;
            }
            
            networkingRequest.requestSerializer = nil;
            networkingRequest.responseSerializer = nil;
            
            networkingRequest.url = [request urlWithVeEndpoint:_networkingConfiguration.endpoint path:[request urlPath]];
        }
        return [self.networking sendRequest: networkingRequest];
    }
}

// Project below
TLS_CLIENT_INTERFACE_IMPLEMENTION(CreateProject)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DeleteProject)
TLS_CLIENT_INTERFACE_IMPLEMENTION(ModifyProject)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeProject)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeProjects)

// Topic below
TLS_CLIENT_INTERFACE_IMPLEMENTION(CreateTopic)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DeleteTopic)
TLS_CLIENT_INTERFACE_IMPLEMENTION(ModifyTopic)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeTopic)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeTopics)
// Shard below
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeShards)
// Index below
TLS_CLIENT_INTERFACE_IMPLEMENTION(CreateIndex)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DeleteIndex)
TLS_CLIENT_INTERFACE_IMPLEMENTION(ModifyIndex)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeIndex)
// Log below
TLS_CLIENT_INTERFACE_IMPLEMENTION(PutLogs)
// 因为IOS环境限制, 这两个方法暂时无法提供
//TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeCursor)
//TLS_CLIENT_INTERFACE_IMPLEMENTION(ConsumeLogs)
TLS_CLIENT_INTERFACE_IMPLEMENTION(SearchLogs)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeLogContext)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeHistogram)
TLS_CLIENT_INTERFACE_IMPLEMENTION(WebTracks)
TLS_CLIENT_INTERFACE_IMPLEMENTION(CreateDownloadTask)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeDownloadTasks)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeDownloadUrl)
// Hostgroup below
TLS_CLIENT_INTERFACE_IMPLEMENTION(CreateHostGroup)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DeleteHostGroup)
TLS_CLIENT_INTERFACE_IMPLEMENTION(ModifyHostGroup)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeHostGroup)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeHostGroups)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeHosts)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DeleteHost)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeHostGroupRules)
TLS_CLIENT_INTERFACE_IMPLEMENTION(ModifyHostGroupsAutoUpdate)
// Rule below
TLS_CLIENT_INTERFACE_IMPLEMENTION(CreateRule)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DeleteRule)
TLS_CLIENT_INTERFACE_IMPLEMENTION(ModifyRule)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeRule)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeRules)
TLS_CLIENT_INTERFACE_IMPLEMENTION(ApplyRuleToHostGroups)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DeleteRuleFromHostGroups)
// Alarm below
TLS_CLIENT_INTERFACE_IMPLEMENTION(CreateAlarmNotifyGroup)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DeleteAlarmNotifyGroup)
TLS_CLIENT_INTERFACE_IMPLEMENTION(ModifyAlarmNotifyGroup)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeAlarmNotifyGroups)
TLS_CLIENT_INTERFACE_IMPLEMENTION(CreateAlarm)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DeleteAlarm)
TLS_CLIENT_INTERFACE_IMPLEMENTION(ModifyAlarm)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeAlarms)
TLS_CLIENT_INTERFACE_IMPLEMENTION(OpenKafkaConsumer)
TLS_CLIENT_INTERFACE_IMPLEMENTION(CloseKafkaConsumer)
TLS_CLIENT_INTERFACE_IMPLEMENTION(DescribeKafkaConsumer)

// PutLogsV2
- (PutLogsV2Response*) PutLogsV2: (PutLogsV2Request*)request {
    PutLogsRequest *realRequest = [PutLogsRequest alloc]; {
        realRequest.topicId = request.topicId;
        realRequest.compressType = request.compressType;
        realRequest.hashKey = request.hashKey;
        realRequest.logGroupList = [[LogGroupList alloc] init];
        LogGroup *logGroup = [[LogGroup alloc] init]; {
            logGroup.source = request.source;
            logGroup.fileName = request.fileName;
            for (int i=0; i<[request.logs count]; i++) {
                if ([request.logs[i].time intValue] == 0) {
                    request.logs[i].time = [[NSNumber alloc] initWithLongLong:(long long)([[NSDate date] timeIntervalSince1970] * 1000)];
                }
                Log *log = [[Log alloc] init];
                log.time = [request.logs[i].time longLongValue];
                for (NSString *key in request.logs[i].contents) {
                    LogContent *logContent = [[LogContent alloc] init]; {
                        logContent.key = key;
                        logContent.value = (NSString*)[request.logs[i].contents objectForKey:key];
                    }
                    [log.contentsArray addObject:logContent];
                }
                [logGroup.logsArray addObject:log];
            }
        }
        [realRequest.logGroupList.logGroupsArray addObject:logGroup];
    }
    return (PutLogsV2Response*)[self PutLogs: realRequest];
}

// PutLogsAsync
- (VeTask*) PutLogsAsync: (PutLogsRequest*)request; {
    @try {
        if ([request checkValidation] == false) {
            return [VeTask taskWithError:[NSError errorWithDomain:@"TLSSDK" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"Invalid request, please check"}]];
        }
        VeTask *task = [self invokeRequest:request];
        return task;
    }
    @catch (NSException *exception) {
        return [VeTask taskWithError:[NSError errorWithDomain:@"TLSSDK" code:-1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Exception: %@ Reason: %@", exception.name, exception.reason]}]];
    }
}

// PutLogsV2Async
- (VeTask*) PutLogsV2Async: (PutLogsV2Request*)request; {
    PutLogsRequest *realRequest = [PutLogsRequest alloc]; {
        realRequest.topicId = request.topicId;
        realRequest.compressType = request.compressType;
        realRequest.hashKey = request.hashKey;
        realRequest.logGroupList = [[LogGroupList alloc] init];
        LogGroup *logGroup = [[LogGroup alloc] init]; {
            logGroup.source = request.source;
            logGroup.fileName = request.fileName;
            for (int i=0; i<[request.logs count]; i++) {
                if ([request.logs[i].time intValue] == 0) {
                    request.logs[i].time = [[NSNumber alloc] initWithLongLong:(long long)([[NSDate date] timeIntervalSince1970] * 1000)];
                }
                Log *log = [[Log alloc] init];
                log.time = [request.logs[i].time longLongValue];
                for (NSString *key in request.logs[i].contents) {
                    LogContent *logContent = [[LogContent alloc] init]; {
                        logContent.key = key;
                        logContent.value = (NSString*)[request.logs[i].contents objectForKey:key];
                    }
                    [log.contentsArray addObject:logContent];
                }
                [logGroup.logsArray addObject:log];
            }
        }
        [realRequest.logGroupList.logGroupsArray addObject:logGroup];
    }
    return [self PutLogsAsync: realRequest];
}

@end
