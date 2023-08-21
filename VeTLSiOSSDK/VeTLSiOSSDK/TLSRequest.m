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
#import "TLSRequest.h"
#import "TLSProtobuf.h"
#import <VeTLSiOSSDK/NSData+lz4.h>

#define TYPICAL_BODY_REQUEST(api, http_method) \
+ (JSONKeyMapper *) keyMapper { return [JSONKeyMapper mapperForTitleCase]; } \
- (NSString *) httpMethod { return @http_method; } \
- (NSDictionary *) queryParamsDict { return nil; } \
- (NSData *) requestBody { \
NSDictionary *bodyDict = [[self toDictionary] mutableCopy]; \
return [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil]; \
} \
- (NSString *) urlPath { \
return @api; \
}

#define TYPICAL_URI_REQUEST(api, http_method) \
+ (JSONKeyMapper *) keyMapper { return [JSONKeyMapper mapperForTitleCase]; } \
- (NSString *) httpMethod { return @http_method; } \
- (NSDictionary *) queryParamsDict { \
return [self toDictionary]; \
} \
- (NSData *) requestBody { \
return [NSJSONSerialization dataWithJSONObject:[NSDictionary dictionary] options:0 error:nil]; \
} \
- (NSString *) urlPath { \
return @api; \
}

@implementation TLSRequest
+ (BOOL)propertyIsOptional:(NSString *)propertyName {
    return YES;
}

- (NSString *)urlPath {
    return @"";
}

- (NSDictionary *)queryParamsDict {
    return nil;
}

- (NSDictionary *)headerParamsDict:(NSString *)apiVersion {
    NSMutableDictionary *headerParams = [NSMutableDictionary dictionary];
    if (apiVersion != nil) {
        [headerParams setValue:apiVersion forKey:@"x-tls-apiversion"];
    } else {
        [headerParams setValue:@"0.2.0" forKey:@"x-tls-apiversion"];
    }
    return headerParams;
}

- (NSData *)requestBody {
    return nil;
}

- (NSString *)httpMethod {
    return @"";
}

- (NSURL *)urlWithVeEndpoint:(VeEndpoint *)endpoint path:(NSString *)path {
    NSURLComponents *urlComponents = [[NSURLComponents alloc] initWithString:endpoint.endpoint];
    [urlComponents setPath:path];
    
    NSMutableArray *querys = [[NSMutableArray alloc] init];
    [[self queryParamsDict] enumerateKeysAndObjectsUsingBlock:^(NSString *_Nonnull key, id _Nonnull obj, BOOL *_Nonnull stop) {
        NSURLQueryItem *item = [[NSURLQueryItem alloc] initWithName:key value:[NSString stringWithFormat:@"%@", obj]];
        [querys addObject:item];
    }];
    
    [urlComponents setQueryItems:querys];
    
    NSString *urlString = [NSString stringWithString:endpoint.endpoint];
    if (path) {
        if ([urlString hasSuffix:@"/"]) {
            urlString = [NSString stringWithFormat:@"%@%@", urlString, path];
        } else {
            urlString = [NSString stringWithFormat:@"%@/%@", urlString, path];
        }
    }
    if (urlComponents.query && urlComponents.query.length >= 0) {
        urlString = [NSString stringWithFormat:@"%@?%@", urlString, urlComponents.query];
    }
    return [NSURL URLWithString:urlString];
}
@end

// Project requests below

@implementation CreateProjectRequest
@synthesize description = _description;

TYPICAL_BODY_REQUEST("CreateProject", "POST")

- (bool)checkValidation {
    return
    _region == nil ? false :
    _projectName == nil ? false :
    true;
}
@end

@implementation DeleteProjectRequest
TYPICAL_BODY_REQUEST("DeleteProject", "DELETE")

- (bool)checkValidation {
    return
    _projectId == nil ? false :
    true;
}
@end

@implementation ModifyProjectRequest
@synthesize description = _description;

TYPICAL_BODY_REQUEST("ModifyProject", "PUT")

- (bool)checkValidation {
    return
    _projectId == nil ? false :
    true;
}
@end

@implementation DescribeProjectRequest
TYPICAL_URI_REQUEST("DescribeProject", "GET")

- (bool)checkValidation {
    return
    _projectId == nil ? false :
    true;
}
@end

@implementation DescribeProjectsRequest
TYPICAL_URI_REQUEST("DescribeProjects", "GET")

- (bool)checkValidation {
    return true;
}
@end

// Topic requests below

@implementation CreateTopicRequest
@synthesize description = _description;

TYPICAL_BODY_REQUEST("CreateTopic", "POST")

- (bool)checkValidation {
    return
    _topicName == nil ? false :
    _projectId == nil ? false :
    _ttl == nil ? false :
    _shardCount == nil ? false :
    true;
}
@end

@implementation DeleteTopicRequest
TYPICAL_BODY_REQUEST("DeleteTopic", "DELETE")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    true;
}
@end

@implementation ModifyTopicRequest
@synthesize description = _description;

TYPICAL_BODY_REQUEST("ModifyTopic", "PUT")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    true;
}
@end

@implementation DescribeTopicRequest
TYPICAL_URI_REQUEST("DescribeTopic", "GET")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    true;
}
@end

@implementation DescribeTopicsRequest
TYPICAL_URI_REQUEST("DescribeTopics", "GET")

- (bool)checkValidation {
    return
    _projectId == nil ? false :
    true;
}
@end

@implementation DescribeShardsRequest
TYPICAL_URI_REQUEST("DescribeShards", "GET")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    true;
}
@end

// Index requests below

@implementation CreateIndexRequest
TYPICAL_BODY_REQUEST("CreateIndex", "POST")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    true;
}
@end

@implementation DeleteIndexRequest
TYPICAL_BODY_REQUEST("DeleteIndex", "DELETE")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    true;
}
@end

@implementation ModifyIndexRequest
TYPICAL_BODY_REQUEST("ModifyIndex", "PUT")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    true;
}
@end

@implementation DescribeIndexRequest
TYPICAL_URI_REQUEST("DescribeIndex", "GET")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    true;
}
@end

// Log request below

@implementation PutLogsRequest
+ (JSONKeyMapper *)keyMapper {
    return [JSONKeyMapper mapperForTitleCase];
}

- (NSString *)httpMethod {
    return @"POST";
}

- (NSDictionary *)headerParamsDict:(NSString *)apiVersion {
    NSMutableDictionary *headerParams = [NSMutableDictionary dictionary];
    [headerParams setValue:@"application/x-protobuf" forKey:@"Content-Type"];
    if (apiVersion != nil) {
        [headerParams setValue:apiVersion forKey:@"x-tls-apiversion"];
    } else {
        [headerParams setValue:@"0.2.0" forKey:@"x-tls-apiversion"];
    }
    if (self.hashKey != nil)
        [headerParams setValue:self.hashKey forKey:@"x-tls-hashkey"];
    if (self.compressType != nil && [[self.compressType lowercaseString] isEqualToString:@"lz4"]) {
        // Only support lz4 now
        [headerParams setValue:self.compressType forKey:@"x-tls-compresstype"];
    }
    
    if (self.logGroupList != nil) {
        [headerParams setValue:[NSString stringWithFormat:@"%lu", self.logGroupList.data.length] forKey:@"x-tls-bodyrawsize"];
    }
    return headerParams;
}

- (NSDictionary *)queryParamsDict {
    NSMutableDictionary *queryParams = [NSMutableDictionary dictionary];
    if (self.topicId != nil)
        [queryParams setValue:self.topicId forKey:@"TopicId"];
    return queryParams;
}

- (NSData *)requestBody {
    if (self.logGroupList == nil) {
        return nil;
    }
    for (int i = 0; i < self.logGroupList.logGroupsArray_Count; i++) {
        for (int j = 0; j < self.logGroupList.logGroupsArray[i].logsArray_Count; j++) {
            if (self.logGroupList.logGroupsArray[i].logsArray[j].time == 0) {
                self.logGroupList.logGroupsArray[i].logsArray[j].time = (long long) ([[NSDate date] timeIntervalSince1970] * 1000);
            }
        }
    }
    if ([[self.compressType lowercaseString] isEqualToString:@"lz4"]) {
        NSData *compressedBody = [self.logGroupList.data compressLZ4:LZ4CompressionFast];
        return compressedBody;
    }
    return self.logGroupList.data;
}

- (NSString *)urlPath {
    return @"PutLogs";
}

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    _logGroupList == nil ? false :
    true;
}
@end

// 由于IOS环境限制, 这两个方法暂时无法提供
//@implementation DescribeCursorRequest
//+ (JSONKeyMapper *) keyMapper { return [JSONKeyMapper mapperForTitleCase]; } \
//- (NSString *) httpMethod { return @"GET"; }
//- (NSDictionary *) queryParamsDict {
//    NSMutableDictionary *result = [[NSMutableDictionary alloc] init]; {
//        result[@"TopicId"] = self.topicId;
//        result[@"ShardId"] = self.shardId;
//    }
//    return result;
//    // return [self toDictionary];
//}
//- (NSData *) requestBody {
//    NSMutableDictionary *result = [[NSMutableDictionary alloc] init]; {
//        result[@"From"] = self.from;
//    }
//    return [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
//}
//- (NSString *) urlPath { \
//    return @"DescribeCursor"; \
//}
//@end
//
//@implementation ConsumeLogsRequest
//+ (JSONKeyMapper *) keyMapper { return [JSONKeyMapper mapperForTitleCase]; }
//- (NSString *) httpMethod { return @"GET"; }
//- (NSDictionary *) queryParamsDict {
//    NSMutableDictionary *queryParams = [NSMutableDictionary dictionary];
//    if (self.topicId != nil)
//        [queryParams setValue:self.topicId forKey:@"TopicId"];
//    if (self.shardId != nil)
//        [queryParams setValue:[NSString stringWithFormat:@"%@", self.shardId] forKey:@"ShardId"];
//    return queryParams;
//}
//- (NSString *) urlPath {
//    return @"ConsumeLogs";
//}
//@end

@implementation SearchLogsRequest
TYPICAL_BODY_REQUEST("SearchLogs", "POST")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    _query == nil ? false :
    _startTime == nil ? false :
    _endTime == nil ? false :
    true;
}
@end

@implementation SearchLogsV2Request
TYPICAL_BODY_REQUEST("SearchLogsV2", "POST")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    _query == nil ? false :
    _startTime == nil ? false :
    _endTime == nil ? false :
    true;
}
@end

@implementation DescribeLogContextRequest
TYPICAL_BODY_REQUEST("DescribeLogContext", "POST")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    _contextFlow == nil ? false :
    _packageOffset == nil ? false :
    _source == nil ? false :
    true;
}
@end

@implementation DescribeHistogramRequest
TYPICAL_BODY_REQUEST("DescribeHistogram", "POST")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    _query == nil ? false :
    _startTime == nil ? false :
    _endTime == nil ? false :
    true;
}
@end

@interface WebTracksBody : JSONModel
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *logs;
@property(nonatomic, copy) NSString *source;
@end

@implementation WebTracksBody
+ (JSONKeyMapper *)keyMapper {
    return [JSONKeyMapper mapperForTitleCase];
}
@end

@implementation WebTracksRequest
+ (JSONKeyMapper *)keyMapper {
    return [JSONKeyMapper mapperForTitleCase];
}

- (NSString *)httpMethod {
    return @"POST";
}

- (NSDictionary *)headerParamsDict:(NSString *)apiVersion {
    NSMutableDictionary *headerParams = [NSMutableDictionary dictionary];
    [headerParams setValue:@"application/json" forKey:@"Content-Type"];
    if (apiVersion != nil) {
        [headerParams setValue:apiVersion forKey:@"x-tls-apiversion"];
    } else {
        [headerParams setValue:@"0.2.0" forKey:@"x-tls-apiversion"];
    }
    if (self.compressType != nil && [[self.compressType lowercaseString] isEqualToString:@"lz4"]) {
        // 暂时只支持 lz4
        [headerParams setValue:self.compressType forKey:@"x-tls-compresstype"];
    }
    // TODO: 优化这块逻辑, 省一次 JSON
    WebTracksBody *body = [WebTracksBody alloc];
    body.source = self.source;
    body.logs = self.logs;
    NSData *jsonByte = [body toJSONData];
    [headerParams setValue:[NSString stringWithFormat:@"%lu", jsonByte.length] forKey:@"x-tls-bodyrawsize"];
    return headerParams;
}

- (NSDictionary *)queryParamsDict {
    NSMutableDictionary *queryParams = [NSMutableDictionary dictionary];
    if (self.topicId != nil)
        [queryParams setValue:self.topicId forKey:@"TopicId"];
    if (self.projectId != nil)
        [queryParams setValue:self.projectId forKey:@"ProjectId"];
    return queryParams;
}

- (NSData *)requestBody {
    WebTracksBody *body = [WebTracksBody alloc];
    body.source = self.source;
    body.logs = self.logs;
    NSData *jsonByte = [body toJSONData];
    if ([[self.compressType lowercaseString] isEqualToString:@"lz4"]) {
        return [jsonByte compressLZ4:LZ4CompressionFast];
    }
    return jsonByte;
}

- (NSString *)urlPath {
    return @"WebTracks";
}

- (bool)checkValidation {
    return
    _projectId == nil ? false :
    _topicId == nil ? false :
    _logs == nil ? false :
    true;
}
@end

@implementation CreateDownloadTaskRequest
TYPICAL_BODY_REQUEST("CreateDownloadTask", "POST")

- (bool)checkValidation {
    return
    _taskName == nil ? false :
    _topicId == nil ? false :
    _query == nil ? false :
    _startTime == nil ? false :
    _endTime == nil ? false :
    _dataFormat == nil ? false :
    _sort == nil ? false :
    _limit == nil ? false :
    _compression == nil ? false :
    true;
}
@end

@implementation DescribeDownloadTasksRequest
TYPICAL_URI_REQUEST("DescribeDownloadTasks", "GET")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    true;
}
@end

@implementation DescribeDownloadUrlRequest
TYPICAL_URI_REQUEST("DescribeDownloadUrl", "GET")

- (bool)checkValidation {
    return
    _taskId == nil ? false :
    true;
}
@end

// Host group below

@implementation CreateHostGroupRequest
TYPICAL_BODY_REQUEST("CreateHostGroup", "POST")

- (bool)checkValidation {
    return
    _hostGroupName == nil ? false :
    _hostGroupType == nil ? false :
    true;
}
@end

@implementation DeleteHostGroupRequest
TYPICAL_BODY_REQUEST("DeleteHostGroup", "DELETE")

- (bool)checkValidation {
    return
    _hostGroupId == nil ? false :
    true;
}
@end

@implementation ModifyHostGroupRequest
TYPICAL_BODY_REQUEST("ModifyHostGroup", "PUT")

- (bool)checkValidation {
    return
    _hostGroupId == nil ? false :
    true;
}
@end

@implementation DescribeHostGroupRequest
TYPICAL_URI_REQUEST("DescribeHostGroup", "GET")

- (bool)checkValidation {
    return
    _hostGroupId == nil ? false :
    true;
}
@end

@implementation DescribeHostGroupsRequest
TYPICAL_URI_REQUEST("DescribeHostGroups", "GET")

- (bool)checkValidation {
    return true;
}
@end

@implementation DescribeHostsRequest
TYPICAL_URI_REQUEST("DescribeHosts", "GET")

- (bool)checkValidation {
    return
    _hostGroupId == nil ? false :
    true;
}
@end

@implementation DeleteHostRequest
TYPICAL_BODY_REQUEST("DeleteHost", "DELETE")

- (bool)checkValidation {
    return
    _hostGroupId == nil ? false :
    _ip == nil ? false :
    true;
}
@end

@implementation DescribeHostGroupRulesRequest
TYPICAL_URI_REQUEST("DescribeHostGroupRules", "GET")

- (bool)checkValidation {
    return
    _hostGroupId == nil ? false :
    true;
}
@end

@implementation ModifyHostGroupsAutoUpdateRequest
TYPICAL_BODY_REQUEST("ModifyHostGroupsAutoUpdate", "PUT")

- (bool)checkValidation {
    return
    _hostGroupIds == nil ? false :
    true;
}
@end

// Rule request below

@implementation CreateRuleRequest
TYPICAL_BODY_REQUEST("CreateRule", "POST")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    _ruleName == nil ? false :
    true;
}
@end

@implementation DeleteRuleRequest
TYPICAL_BODY_REQUEST("DeleteRule", "DELETE")

- (bool)checkValidation {
    return
    _ruleId == nil ? false :
    true;
}
@end

@implementation ModifyRuleRequest
TYPICAL_BODY_REQUEST("ModifyRule", "PUT")

- (bool)checkValidation {
    return
    _ruleId == nil ? false :
    true;
}
@end

@implementation DescribeRuleRequest
TYPICAL_URI_REQUEST("DescribeRule", "GET")

- (bool)checkValidation {
    return
    _ruleId == nil ? false :
    true;
}
@end

@implementation DescribeRulesRequest
TYPICAL_URI_REQUEST("DescribeRules", "GET")

- (bool)checkValidation {
    return
    _projectId == nil ? false :
    true;
}
@end

@implementation ApplyRuleToHostGroupsRequest
TYPICAL_BODY_REQUEST("ApplyRuleToHostGroups", "PUT")

- (bool)checkValidation {
    return
    _ruleId == nil ? false :
    _hostGroupIds == nil ? false :
    true;
}
@end

@implementation DeleteRuleFromHostGroupsRequest
TYPICAL_BODY_REQUEST("DeleteRuleFromHostGroups", "PUT")

- (bool)checkValidation {
    return
    _ruleId == nil ? false :
    _hostGroupIds == nil ? false :
    true;
}
@end

// Alarm request below

@implementation CreateAlarmNotifyGroupRequest
TYPICAL_BODY_REQUEST("CreateAlarmNotifyGroup", "POST")

- (bool)checkValidation {
    return
    _alarmNotifyGroupName == nil ? false :
    _notifyType == nil ? false :
    _receivers == nil ? false :
    true;
}
@end

@implementation DeleteAlarmNotifyGroupRequest
TYPICAL_BODY_REQUEST("DeleteAlarmNotifyGroup", "DELETE")

- (bool)checkValidation {
    return
    _alarmNotifyGroupId == nil ? false :
    true;
}
@end

@implementation ModifyAlarmNotifyGroupRequest
TYPICAL_BODY_REQUEST("ModifyAlarmNotifyGroup", "PUT")

- (bool)checkValidation {
    return
    _alarmNotifyGroupId == nil ? false :
    true;
}
@end

@implementation DescribeAlarmNotifyGroupsRequest
TYPICAL_URI_REQUEST("DescribeAlarmNotifyGroups", "GET")

- (bool)checkValidation {
    return true;
}
@end

@implementation CreateAlarmRequest
TYPICAL_BODY_REQUEST("CreateAlarm", "POST")

- (bool)checkValidation {
    return
    _alarmName == nil ? false :
    _projectId == nil ? false :
    _queryRequest == nil ? false :
    _requestCycle == nil ? false :
    _condition == nil ? false :
    _alarmPeriod == nil ? false :
    _alarmNotifyGroup == nil ? false :
    true;
}
@end

@implementation DeleteAlarmRequest
TYPICAL_BODY_REQUEST("DeleteAlarm", "DELETE")

- (bool)checkValidation {
    return
    _alarmId == nil ? false :
    true;
}
@end

@implementation ModifyAlarmRequest
TYPICAL_BODY_REQUEST("ModifyAlarm", "PUT")

- (bool)checkValidation {
    return
    _alarmId == nil ? false :
    true;
}
@end

@implementation DescribeAlarmsRequest
TYPICAL_URI_REQUEST("DescribeAlarms", "GET")

- (bool)checkValidation {
    return
    _projectId == nil ? false :
    true;
}
@end

// Kafka protocol request below

@implementation OpenKafkaConsumerRequest
TYPICAL_BODY_REQUEST("OpenKafkaConsumer", "PUT")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    true;
}
@end

@implementation CloseKafkaConsumerRequest
TYPICAL_BODY_REQUEST("CloseKafkaConsumer", "PUT")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    true;
}
@end

@implementation DescribeKafkaConsumerRequest
TYPICAL_URI_REQUEST("DescribeKafkaConsumer", "GET")

- (bool)checkValidation {
    return
    _topicId == nil ? false :
    true;
}
@end

@implementation PutLogsV2Request
- (bool)checkValidation {
    return
    _topicId == nil ? false :
    _logs == nil ? false :
    true;
}
@end

// 
