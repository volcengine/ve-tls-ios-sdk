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
#import <VeTLSiOSSDK/VeEndpoint.h>
#import <VeTLSiOSSDK/TLSModel.h>
#import <VeTLSiOSSDK/JSONModelLib.h>
#import <VeTLSiOSSDK/TLSProtobuf.h>

#ifndef TLSRequest_h
#define TLSRequest_h

@interface TLSRequest : JSONModel
+(BOOL)propertyIsOptional:(NSString*)propertyName;
- (NSDictionary *) queryParamsDict;
- (NSDictionary *) headerParamsDict;
- (NSData *) requestBody;
- (NSString *) httpMethod;
- (NSString *) urlPath;
- (NSURL *)urlWithVeEndpoint: (VeEndpoint *)endpoint path: (NSString *)path;
- (bool)checkValidation;
@end

@interface CreateProjectRequest : TLSRequest
@property (nonatomic, copy) NSString *projectName;
@property (nonatomic, copy) NSString *region;
@property (nonatomic, copy) NSString *description;
@end

@interface DeleteProjectRequest : TLSRequest
@property (nonatomic, copy) NSString *projectId;
@end

@interface ModifyProjectRequest : TLSRequest
@property (nonatomic, copy) NSString *projectId;
@property (nonatomic, copy) NSString *projectName;
@property (nonatomic, copy) NSString *description;
@end

@interface DescribeProjectRequest : TLSRequest
@property (nonatomic, copy) NSString *projectId;
@end

@interface DescribeProjectsRequest : TLSRequest
@property (nonatomic, copy) NSNumber *pageNumber;
@property (nonatomic, copy) NSNumber *pageSize;
@property (nonatomic, copy) NSString *projectName;
@property (nonatomic, assign) BOOL isFullName;
@property (nonatomic, copy) NSString *projectId;
@end

@interface CreateTopicRequest : TLSRequest
@property (nonatomic, copy) NSString *topicName;
@property (nonatomic, copy) NSString *projectId;
@property (nonatomic, copy) NSNumber *ttl;
@property (nonatomic, copy) NSNumber *shardCount;
@property (nonatomic, assign) BOOL autoSplit;
@property (nonatomic, copy) NSNumber *maxSplitShard;
@property (nonatomic, assign) BOOL enableTracking;
@property (nonatomic, copy) NSString *timeKey;
@property (nonatomic, copy) NSString *timeFormat;
@property (nonatomic, copy) NSString *description;
@end

@interface DeleteTopicRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@end

@interface ModifyTopicRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *topicName;
@property (nonatomic, copy) NSNumber *ttl;
@property (nonatomic, assign) BOOL autoSplit;
@property (nonatomic, copy) NSNumber *maxSplitShard;
@property (nonatomic, assign) BOOL enableTracking;
@property (nonatomic, copy) NSString *timeKey;
@property (nonatomic, copy) NSString *timeFormat;
@property (nonatomic, copy) NSString *description;
@end

@interface DescribeTopicRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@end

@interface DescribeTopicsRequest : TLSRequest
@property (nonatomic, copy) NSString *projectId;
@property (nonatomic, copy) NSNumber *pageNumber;
@property (nonatomic, copy) NSNumber *pageSize;
@property (nonatomic, copy) NSString *topicName;
@property (nonatomic, assign) BOOL isFullName;
@property (nonatomic, copy) NSString *topicId;
@end

@interface DescribeShardsRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSNumber *pageNumber;
@property (nonatomic, copy) NSNumber *pageSize;
@end

@interface CreateIndexRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) FullTextInfo *fullText;
@property (nonatomic, copy) NSArray<KeyValueInfo*> <KeyValueInfo> *keyValue;
@end

@interface DeleteIndexRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@end

@interface ModifyIndexRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) FullTextInfo *fullText;
@property (nonatomic, copy) NSArray<KeyValueInfo*> <KeyValueInfo> *keyValue;
@end

@interface DescribeIndexRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@end

@interface PutLogsRequest : TLSRequest
@property (nonatomic, copy) NSString *hashKey;
@property (nonatomic, copy) NSString *compressType;
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) LogGroupList *logGroupList;
@end

@interface PutLogsV2Request : TLSRequest
@property (nonatomic, copy) NSString *hashKey;
@property (nonatomic, copy) NSString *compressType;
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, copy) NSArray<PutLogsV2LogItem*> <PutLogsV2LogItem> *logs;
@end

// 由于IOS环境限制, 这两个方法暂时无法提供
//@interface DescribeCursorRequest : TLSRequest
//@property (nonatomic, copy) NSString *topicId;
//@property (nonatomic, copy) NSNumber *shardId;
//@property (nonatomic, copy) NSString *from;
//@end
//
//@interface ConsumeLogsRequest : TLSRequest
//@property (nonatomic, copy) NSString *topicId;
//@property (nonatomic, copy) NSNumber *shardId;
//@property (nonatomic, copy) NSString *cursor;
//@property (nonatomic, copy) NSString *endCursor;
//@property (nonatomic, copy) NSNumber *logGroupCount;
//@property (nonatomic, copy) NSString *compression;
//@end

@interface SearchLogsRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, copy) NSNumber *startTime;
@property (nonatomic, copy) NSNumber *endTime;
@property (nonatomic, copy) NSNumber *limit;
@property (nonatomic, copy) NSString *context;
@property (nonatomic, copy) NSString *sort;
@end

@interface DescribeLogContextRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *contextFlow;
@property (nonatomic, copy) NSNumber *packageOffset;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, copy) NSNumber *prevLogs;
@property (nonatomic, copy) NSNumber *nextLogs;
@end

@interface DescribeHistogramRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, copy) NSNumber *startTime;
@property (nonatomic, copy) NSNumber *endTime;
@property (nonatomic, copy) NSNumber *interval;
@end

@interface WebTracksRequest : TLSRequest
@property (nonatomic, copy) NSString *projectId;
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *compressType;
@property (nonatomic, copy) NSArray<NSDictionary<NSString*, NSString*>*> *logs;
@property (nonatomic, copy) NSString *source;
@end

@interface CreateDownloadTaskRequest : TLSRequest
@property (nonatomic, copy) NSString *taskName;
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, copy) NSNumber *startTime;
@property (nonatomic, copy) NSNumber *endTime;
@property (nonatomic, copy) NSString *dataFormat;
@property (nonatomic, copy) NSString *sort;
@property (nonatomic, copy) NSNumber *limit;
@property (nonatomic, copy) NSString *compression;
@end

@interface DescribeDownloadTasksRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSNumber *pageNumber;
@property (nonatomic, copy) NSNumber *pageSize;
@end

@interface DescribeDownloadUrlRequest : TLSRequest
@property (nonatomic, copy) NSString *taskId;
@end

@interface CreateHostGroupRequest : TLSRequest
@property (nonatomic, copy) NSString *hostGroupName;
@property (nonatomic, copy) NSString *hostGroupType;
@property (nonatomic, copy) NSArray<NSString*> *hostIpList;
@property (nonatomic, copy) NSString *hostIdentifier;
@property (nonatomic, assign) BOOL autoUpdate;
@property (nonatomic, copy) NSString *updateStartTime;
@property (nonatomic, copy) NSString *updateEndTime;
@property (nonatomic, assign) BOOL serviceLogging;
@end

@interface DeleteHostGroupRequest : TLSRequest
@property (nonatomic, copy) NSString *hostGroupId;
@end

@interface ModifyHostGroupRequest : TLSRequest
@property (nonatomic, copy) NSString *hostGroupId;
@property (nonatomic, copy) NSString *hostGroupName;
@property (nonatomic, copy) NSString *hostGroupType;
@property (nonatomic, copy) NSArray<NSString*> *hostIpList;
@property (nonatomic, copy) NSString *hostIdentifier;
@property (nonatomic, assign) BOOL autoUpdate;
@property (nonatomic, copy) NSString *updateStartTime;
@property (nonatomic, copy) NSString *updateEndTime;
@property (nonatomic, assign) BOOL serviceLogging;
@end

@interface DescribeHostGroupRequest : TLSRequest
@property (nonatomic, copy) NSString *hostGroupId;
@end

@interface DescribeHostGroupsRequest : TLSRequest
@property (nonatomic, copy) NSString *hostGroupId;
@property (nonatomic, copy) NSString *hostGroupName;
@property (nonatomic, copy) NSNumber *pageNumber;
@property (nonatomic, copy) NSNumber *pageSize;
@property (nonatomic, assign) BOOL autoUpdate;
@property (nonatomic, copy) NSString *hostIdentifier;
@property (nonatomic, assign) BOOL serviceLogging;
@end

@interface DescribeHostsRequest : TLSRequest
@property (nonatomic, copy) NSString *hostGroupId;
@property (nonatomic, copy) NSString *ip;
@property (nonatomic, copy) NSNumber *heartbeatStatus;
@property (nonatomic, copy) NSNumber *pageNumber;
@property (nonatomic, copy) NSNumber *pageSize;
@end

@interface DeleteHostRequest : TLSRequest
@property (nonatomic, copy) NSString *hostGroupId;
@property (nonatomic, copy) NSString *ip;
@end

@interface DescribeHostGroupRulesRequest : TLSRequest
@property (nonatomic, copy) NSString *hostGroupId;
@property (nonatomic, copy) NSNumber *pageNumber;
@property (nonatomic, copy) NSNumber *pageSize;
@end

@interface ModifyHostGroupsAutoUpdateRequest : TLSRequest
@property (nonatomic, copy) NSArray<NSString*> *hostGroupIds;
@property (nonatomic, assign) BOOL autoUpdate;
@property (nonatomic, copy) NSString *updateStartTime;
@property (nonatomic, copy) NSString *updateEndTime;
@end

@interface CreateRuleRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *ruleName;
@property (nonatomic, copy) NSArray<NSString*> *paths;
@property (nonatomic, copy) NSString *logType;
@property (nonatomic, copy) ExtractRule *extractRule;
@property (nonatomic, copy) NSArray<ExcludePath*> <ExcludePath> *excludePaths;
@property (nonatomic, copy) UserDefineRule *userDefineRule;
@property (nonatomic, copy) NSString *logSample;
@property (nonatomic, copy) NSNumber *inputType;
@property (nonatomic, copy) ContainerRule *containerRule;
@end

@interface DeleteRuleRequest : TLSRequest
@property (nonatomic, copy) NSString *ruleId;
@end

@interface ModifyRuleRequest : TLSRequest
@property (nonatomic, copy) NSString *ruleId;
@property (nonatomic, copy) NSString *ruleName;
@property (nonatomic, copy) NSArray<NSString*> *paths;
@property (nonatomic, copy) NSString *logType;
@property (nonatomic, copy) ExtractRule *extractRule;
@property (nonatomic, copy) NSArray<ExcludePath*> <ExcludePath> *excludePaths;
@property (nonatomic, copy) UserDefineRule *userDefineRule;
@property (nonatomic, copy) NSString *logSample;
@property (nonatomic, copy) NSNumber *inputType;
@property (nonatomic, copy) ContainerRule *containerRule;
@end

@interface DescribeRuleRequest : TLSRequest
@property (nonatomic, copy) NSString *ruleId;
@end

@interface DescribeRulesRequest : TLSRequest
@property (nonatomic, copy) NSString *projectId;
@property (nonatomic, copy) NSString *ruleId;
@property (nonatomic, copy) NSString *ruleName;
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *topicName;
@property (nonatomic, copy) NSNumber *pageNumber;
@property (nonatomic, copy) NSNumber *pageSize;
@end

@interface ApplyRuleToHostGroupsRequest : TLSRequest
@property (nonatomic, copy) NSString *ruleId;
@property (nonatomic, copy) NSArray<NSString*> *hostGroupIds;
@end

@interface DeleteRuleFromHostGroupsRequest : TLSRequest
@property (nonatomic, copy) NSString *ruleId;
@property (nonatomic, copy) NSArray<NSString*> *hostGroupIds;
@end

@interface CreateAlarmNotifyGroupRequest : TLSRequest
@property (nonatomic, copy) NSString *alarmNotifyGroupName;
@property (nonatomic, copy) NSArray<NSString*> *notifyType;
@property (nonatomic, copy) NSArray<Receiver*> <Receiver> *receivers;
@end

@interface DeleteAlarmNotifyGroupRequest : TLSRequest
@property (nonatomic, copy) NSString *alarmNotifyGroupId;
@end

@interface ModifyAlarmNotifyGroupRequest : TLSRequest
@property (nonatomic, copy) NSString *alarmNotifyGroupId;
@property (nonatomic, copy) NSString *alarmNotifyGroupName;
@property (nonatomic, copy) NSArray<NSString*> *notifyType;
@property (nonatomic, copy) NSArray<Receiver*> <Receiver> *receivers;
@end

@interface DescribeAlarmNotifyGroupsRequest : TLSRequest
@property (nonatomic, copy) NSString *alarmNotifyGroupName;
@property (nonatomic, copy) NSString *alarmNotifyGroupId;
@property (nonatomic, copy) NSString *receiverName;
@property (nonatomic, copy) NSNumber *pageNumber;
@property (nonatomic, copy) NSNumber *pageSize;
@end

@interface CreateAlarmRequest : TLSRequest
@property (nonatomic, copy) NSString *alarmName;
@property (nonatomic, copy) NSString *projectId;
@property (nonatomic, assign) BOOL status;
@property (nonatomic, copy) NSArray<QueryRequest*> <QueryRequest> *queryRequest;
@property (nonatomic, copy) RequestCycle *requestCycle;
@property (nonatomic, copy) NSString *condition;
@property (nonatomic, copy) NSNumber *triggerPeriod;
@property (nonatomic, copy) NSNumber *alarmPeriod;
@property (nonatomic, copy) NSArray<NSString*> *alarmNotifyGroup;
@property (nonatomic, copy) NSString *userDefineMsg;
@end

@interface DeleteAlarmRequest : TLSRequest
@property (nonatomic, copy) NSString *alarmId;
@end

@interface ModifyAlarmRequest : TLSRequest
@property (nonatomic, copy) NSString *alarmId;
@property (nonatomic, copy) NSString *alarmName;
@property (nonatomic, assign) BOOL status;
@property (nonatomic, copy) NSArray<QueryRequest*> <QueryRequest> *queryRequest;
@property (nonatomic, copy) RequestCycle *requestCycle;
@property (nonatomic, copy) NSString *condition;
@property (nonatomic, copy) NSNumber *triggerPeriod;
@property (nonatomic, copy) NSNumber *alarmPeriod;
@property (nonatomic, copy) NSArray<NSString*> *alarmNotifyGroup;
@property (nonatomic, copy) NSString *userDefineMsg;
@end

@interface DescribeAlarmsRequest : TLSRequest
@property (nonatomic, copy) NSString *projectId;
@property (nonatomic, copy) NSString *alarmName;
@property (nonatomic, copy) NSString *alarmId;
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *topicName;
@property (nonatomic, assign) BOOL status;
@property (nonatomic, copy) NSNumber *pageNumber;
@property (nonatomic, copy) NSNumber *pageSize;
@end

@interface OpenKafkaConsumerRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@end

@interface CloseKafkaConsumerRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@end

@interface DescribeKafkaConsumerRequest : TLSRequest
@property (nonatomic, copy) NSString *topicId;
@end


#endif /* TLSRequest_h */
