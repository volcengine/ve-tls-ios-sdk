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
#import "TLSModel.h"
#import <VeTLSiOSSDK/JSONModelLib.h>
#import "TLSProtobuf.h"

#ifndef TLSResponse_h
#define TLSResponse_h

@interface CommonResponse : JSONModel
+(BOOL)propertyIsOptional:(NSString*)propertyName;
@property (nonatomic, copy) NSString *errorCode;
@property (nonatomic, copy) NSString *errorMessage;
@property (nonatomic, copy) NSString *requestId;
@property (nonatomic, copy) NSNumber *statusCode;
@end

@interface CreateProjectResponse : CommonResponse
@property (nonatomic, copy) NSString *projectId;
@end

@interface DeleteProjectResponse : CommonResponse
@end

@interface ModifyProjectResponse : CommonResponse
@end

@interface DescribeProjectResponse : CommonResponse
@property (nonatomic, copy) NSString *projectName;
@property (nonatomic, copy) NSString *projectId;
@property (nonatomic, copy) NSString *description;
@property (nonatomic, copy) NSString *createTime;
@property (nonatomic, copy) NSString *innerNetDomain;
@property (nonatomic, copy) NSNumber *topicCount;
@end

@interface DescribeProjectsResponse : CommonResponse
@property (nonatomic, copy) NSArray<ProjectInfo*> <ProjectInfo> *projects;
@property (nonatomic, copy) NSNumber *total;
@end

@interface CreateTopicResponse : CommonResponse
@property (nonatomic, copy) NSString *topicId;
@end

@interface DeleteTopicResponse : CommonResponse
@end

@interface ModifyTopicResponse : CommonResponse
@end

@interface DescribeTopicResponse : CommonResponse
@property (nonatomic, copy) NSString *topicName;
@property (nonatomic, copy) NSString *projectId;
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSNumber *ttl;
@property (nonatomic, copy) NSString *createTime;
@property (nonatomic, copy) NSString *modifyTime;
@property (nonatomic, copy) NSNumber *shardCount;
@property (nonatomic, copy) NSString *description;
@property (nonatomic, assign) BOOL autoSplit;
@property (nonatomic, copy) NSNumber *maxSplitShard;
@property (nonatomic, assign) BOOL enableTracking;
@property (nonatomic, copy) NSString *timeKey;
@property (nonatomic, copy) NSString *timeFormat;
@end

@interface DescribeTopicsResponse : CommonResponse
@property (nonatomic, copy) NSArray<TopicInfo*> <TopicInfo> *topics;
@property (nonatomic, copy) NSNumber *total;
@end

@interface DescribeShardsResponse : CommonResponse
@property (nonatomic, copy) NSArray<QueryResp*> <QueryResp> *shards;
@property (nonatomic, copy) NSNumber *total;
@end

@interface CreateIndexResponse : CommonResponse
@property (nonatomic, copy) NSString *topicId;
@end

@interface DeleteIndexResponse : CommonResponse
@end

@interface ModifyIndexResponse : CommonResponse
@end

@interface DescribeIndexResponse : CommonResponse
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) FullTextInfo *fullText;
@property (nonatomic, copy) NSArray<KeyValueInfo*> <KeyValueInfo> *keyValue;
@property (nonatomic, copy) NSString *createTime;
@property (nonatomic, copy) NSString *modifyTime;
@end

@interface PutLogsResponse : CommonResponse
@end

@interface PutLogsV2Response : PutLogsResponse
@end

@interface DescribeCursorResponse : CommonResponse
@property (nonatomic, copy) NSString *cursor;
@end

@interface ConsumeLogsResponse : CommonResponse
@property (nonatomic, copy) NSString *cursor;
@property (nonatomic, copy) NSString *count;
@property (nonatomic, copy) LogGroupList *logs;
@end

@interface SearchLogsResponse : CommonResponse
@property (nonatomic, copy) NSString *resultStatus;
@property (nonatomic, copy) NSNumber *hitCount;
@property (nonatomic, assign) BOOL listOver;
@property (nonatomic, assign) BOOL analysis;
@property (nonatomic, copy) NSNumber *count;
@property (nonatomic, copy) NSNumber *limit;
@property (nonatomic, copy) NSString *context;
@property (nonatomic, copy) NSArray<NSDictionary<NSString*, NSObject*>*> *logs;
@property (nonatomic, copy) AnalysisResult *analysisResult;
@end

@interface SearchLogsV2Response : CommonResponse
@property (nonatomic, copy) NSString *resultStatus;
@property (nonatomic, copy) NSNumber *hitCount;
@property (nonatomic, assign) BOOL listOver;
@property (nonatomic, assign) BOOL analysis;
@property (nonatomic, copy) NSNumber *count;
@property (nonatomic, copy) NSNumber *limit;
@property (nonatomic, copy) NSString *context;
@property (nonatomic, copy) NSArray<NSDictionary<NSString*, NSObject*>*> *logs;
@property (nonatomic, copy) AnalysisResult *analysisResult;
@end

@interface DescribeLogContextResponse : CommonResponse
@property (nonatomic, copy) NSArray<NSDictionary<NSString*, NSObject*>*> *logContextInfos;
@end

@interface DescribeHistogramResponse : CommonResponse
@property (nonatomic, copy) NSString *resultStatus;
@property (nonatomic, copy) NSNumber *interval;
@property (nonatomic, copy) NSNumber *totalCount;
@property (nonatomic, copy) NSArray<HistogramInfo*> <HistogramInfo> *histogramInfos;
@end

@interface WebTracksResponse : CommonResponse
@end

@interface CreateDownloadTaskResponse : CommonResponse
@property (nonatomic, copy) NSString *taskId;
@end

@interface DescribeDownloadTasksResponse : CommonResponse
@property (nonatomic, copy) NSNumber *total;
@property (nonatomic, copy) NSArray<TaskInfo*> <TaskInfo> *tasks;
@end

@interface DescribeDownloadUrlResponse : CommonResponse
@property (nonatomic, copy) NSString *downloadUrl;
@end

@interface CreateHostGroupResponse : CommonResponse
@property (nonatomic, copy) NSString *hostGroupId;
@end

@interface DeleteHostGroupResponse : CommonResponse
@end

@interface ModifyHostGroupResponse : CommonResponse
@end

@interface DescribeHostGroupResponse : CommonResponse
@property (nonatomic, copy) HostGroupHostsRulesInfo *hostGroupHostsRulesInfo;
@end

@interface DescribeHostGroupsResponse : CommonResponse
@property (nonatomic, copy) NSNumber *total;
@property (nonatomic, copy) NSArray<HostGroupHostsRulesInfo*> <HostGroupHostsRulesInfo> *hostGroupHostsRulesInfos;
@end

@interface DescribeHostsResponse : CommonResponse
@property (nonatomic, copy) NSNumber *total;
@property (nonatomic, copy) NSArray<HostInfo*> <HostInfo> *hostInfos;
@end

@interface DeleteHostResponse : CommonResponse
@end

@interface DescribeHostGroupRulesResponse : CommonResponse
@property (nonatomic, copy) NSNumber *total;
@property (nonatomic, copy) NSArray<RuleInfo*> <RuleInfo> *ruleInfos;
@end

@interface ModifyHostGroupsAutoUpdateResponse : CommonResponse
@end

@interface CreateRuleResponse: CommonResponse
@property (nonatomic, copy) NSString *ruleId;
@end

@interface DeleteRuleResponse : CommonResponse
@end

@interface ModifyRuleResponse : CommonResponse
@end

@interface DescribeRuleResponse : CommonResponse
@property (nonatomic, copy) NSString *projectId;
@property (nonatomic, copy) NSString *projectName;
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *topicName;
@property (nonatomic, copy) RuleInfo *ruleInfo;
@property (nonatomic, copy) NSArray<HostGroupInfo*> <HostGroupInfo> *hostGroupInfos;
@end

@interface DescribeRulesResponse : CommonResponse
@property (nonatomic, copy) NSNumber *total;
@property (nonatomic, copy) NSArray<RuleInfo*> <RuleInfo> *ruleInfos;
@end

@interface ApplyRuleToHostGroupsResponse : CommonResponse
@end

@interface DeleteRuleFromHostGroupsResponse : CommonResponse
@end

@interface CreateAlarmNotifyGroupResponse : CommonResponse
@property (nonatomic, copy) NSString *alarmNotifyGroupId;
@end

@interface ModifyAlarmNotifyGroupResponse : CommonResponse
@end

@interface DeleteAlarmNotifyGroupResponse : CommonResponse
@end

@interface DescribeAlarmNotifyGroupsResponse : CommonResponse
@property (nonatomic, copy) NSNumber *total;
@property (nonatomic, copy) NSArray<AlarmNotifyGroupInfo*> <AlarmNotifyGroupInfo> *alarmNotifyGroups;
@end

@interface CreateAlarmResponse : CommonResponse
@property (nonatomic, copy) NSString *alarmId;
@end

@interface DeleteAlarmResponse : CommonResponse
@end

@interface ModifyAlarmResponse : CommonResponse
@end

@interface DescribeAlarmsResponse : CommonResponse
@property (nonatomic, copy) NSNumber *total;
@property (nonatomic, copy) NSArray<AlarmInfo*> <AlarmInfo> *alarms;
@end

@interface OpenKafkaConsumerResponse : CommonResponse
@property (nonatomic, copy) NSString *topicId;
@end

@interface CloseKafkaConsumerResponse : CommonResponse
@end

@interface DescribeKafkaConsumerResponse : CommonResponse
@property (nonatomic, copy) NSString *consumeTopic;
@property (nonatomic, assign) BOOL allowConsume;
@end


#endif /* TLSResponse_h */
