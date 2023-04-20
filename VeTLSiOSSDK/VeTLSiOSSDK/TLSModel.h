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
#import <VeTLSiOSSDK/JSONModelLib.h>

#ifndef TLSModel_h
#define TLSModel_h

@class KeyValueInfo;

@interface TLSObject : JSONModel
+(BOOL)propertyIsOptional:(NSString*)propertyName;
@end


@protocol Advanced @end
@interface Advanced : TLSObject
@property (nonatomic, copy) NSNumber *closeInactive;
@property (nonatomic, assign) BOOL closeRemoved;
@property (nonatomic, assign) BOOL closeRenamed;
@property (nonatomic, assign) BOOL closeEOF;
@property (nonatomic, copy) NSNumber *closeTimeout;
@end

@protocol Plugin @end
@interface Plugin : TLSObject
@property (nonatomic, copy) NSArray<NSDictionary<NSString*, NSObject*>*> *processors;
@end

@protocol ParsePathRule @end
@interface ParsePathRule : TLSObject
@property (nonatomic, copy) NSString *pathSample;
@property (nonatomic, copy) NSString *regex;
@property (nonatomic, copy) NSArray<NSString*> *keys;
@end

@protocol ShardHashKey @end
@interface ShardHashKey : TLSObject
@property (nonatomic, copy) NSString *hashKey;
@end

@protocol UserDefineRule @end
@interface UserDefineRule : TLSObject
@property (nonatomic, copy) ParsePathRule *parsePathRule;
@property (nonatomic, copy) ShardHashKey *shardHashKey;
@property (nonatomic, assign) BOOL enableRawLog;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*> *fields;
@property (nonatomic, copy) Plugin *plugin;
@property (nonatomic, copy) Advanced *advanced;
@property (nonatomic, assign) BOOL tailFiles;
@end

@protocol ExcludePath @end
@interface ExcludePath : TLSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *value;
@end

@protocol LogTemplate @end
@interface LogTemplate : TLSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *format;
@end

@protocol FilterKeyRegex @end
@interface FilterKeyRegex : TLSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *regex;
@end

@protocol Receiver @end
@interface Receiver : TLSObject
@property (nonatomic, copy) NSString *receiverType;
@property (nonatomic, copy) NSArray<NSString*> *receiverNames;
@property (nonatomic, copy) NSArray<NSString*> *receiverChannels;
@property (nonatomic, copy) NSString *startTime;
@property (nonatomic, copy) NSString *endTime;
@end

@protocol AlarmNotifyGroupInfo @end
@interface AlarmNotifyGroupInfo : TLSObject
@property (nonatomic, copy) NSString *alarmNotifyGroupName;
@property (nonatomic, copy) NSString *alarmNotifyGroupId;
@property (nonatomic, copy) NSArray<NSString*> *notifyType;
@property (nonatomic, copy) NSArray<Receiver*> *receivers;
@property (nonatomic, copy) NSString *createTime;
@property (nonatomic, copy) NSString *modifyTime;
@end

@protocol ExtractRule @end
@interface ExtractRule : TLSObject
@property (nonatomic, copy) NSString *delimiter;
@property (nonatomic, copy) NSString *beginRegex;
@property (nonatomic, copy) NSString *logRegex;
@property (nonatomic, copy) NSArray<NSString*> *keys;
@property (nonatomic, copy) NSString *timeKey;
@property (nonatomic, copy) NSString *timeFormat;
@property (nonatomic, copy) NSArray<FilterKeyRegex*> *filterKeyRegex;
@property (nonatomic, assign) BOOL unMatchUpLoadSwitch;
@property (nonatomic, copy) NSString *unMatchLogKey;
@property (nonatomic, copy) LogTemplate *logTemplate;
@end

@protocol KubernetesRule @end
@interface KubernetesRule : TLSObject
@property (nonatomic, copy) NSString *namespaceNameRegex;
@property (nonatomic, copy) NSString *workloadType;
@property (nonatomic, copy) NSString *workloadNameRegex;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*> *includePodLabelRegex;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*> *excludePodLabelRegex;
@property (nonatomic, copy) NSString *podNameRegex;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*> *labelTag;
@end

@protocol ContainerRule @end
@interface ContainerRule : TLSObject
@property (nonatomic, copy) NSString *stream;
@property (nonatomic, copy) NSString *containerNameRegex;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*> *includeContainerLabelRegex;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*> *excludeContainerLabelRegex;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*> *includeContainerEnvRegex;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*> *excludeContainerEnvRegex;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*> *envTag;
@property (nonatomic, copy) KubernetesRule *kubernetesRule;
@end

@protocol RuleInfo @end
@interface RuleInfo : TLSObject
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *topicName;
@property (nonatomic, copy) NSString *ruleId;
@property (nonatomic, copy) NSString *ruleName;
@property (nonatomic, copy) NSArray<NSString*> *paths;
@property (nonatomic, copy) NSString *logType;
@property (nonatomic, copy) ExtractRule *extractRule;
@property (nonatomic, copy) NSArray<ExcludePath*> *excludePaths;
@property (nonatomic, copy) NSString *logSample;
@property (nonatomic, copy) UserDefineRule *userDefineRule;
@property (nonatomic, copy) NSString *createTime;
@property (nonatomic, copy) NSString *modifyTime;
@property (nonatomic, copy) NSNumber *inputType;
@property (nonatomic, copy) ContainerRule *containerRule;
@end

@protocol QueryRequest @end
@interface QueryRequest : TLSObject
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *topicName;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, copy) NSNumber *number;
@property (nonatomic, copy) NSNumber *startTimeOffset;
@property (nonatomic, copy) NSNumber *endTimeOffset;
@end

@protocol RequestCycle @end
@interface RequestCycle : TLSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSNumber *time;
@end

@protocol AlarmInfo @end
@interface AlarmInfo : TLSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *alarmId;
@property (nonatomic, copy) NSString *projectId;
@property (nonatomic, assign) BOOL status;
@property (nonatomic, copy) NSArray<QueryRequest*> *queryRequest;
@property (nonatomic, copy) RequestCycle *requestCycle;
@property (nonatomic, copy) NSString *condition;
@property (nonatomic, copy) NSNumber *triggerPeriod;
@property (nonatomic, copy) NSNumber *alarmPeriod;
@property (nonatomic, copy) NSArray<AlarmNotifyGroupInfo*> *alarmNotifyGroup;
@property (nonatomic, copy) NSString *userDefineMsg;
@property (nonatomic, copy) NSString *createTime;
@property (nonatomic, copy) NSString *modifyTime;
@end

@protocol AnalysisResult @end
@interface AnalysisResult : TLSObject
@property (nonatomic, copy) NSArray<NSString*> *schema;
@property (nonatomic, copy) NSDictionary<NSString*, NSObject*> *type;
@property (nonatomic, copy) NSArray<NSDictionary<NSString*, NSObject*>*> *data;
@end

@protocol FullTextInfo @end
@interface FullTextInfo : TLSObject
@property (nonatomic, assign) BOOL caseSensitive;
@property (nonatomic, copy) NSString *delimiter;
@property (nonatomic, assign) BOOL includeChinese;
@end

@protocol HistogramInfo @end
@interface HistogramInfo : TLSObject
@property (nonatomic, copy) NSNumber *time;
@property (nonatomic, copy) NSNumber *count;
@end

@protocol HostGroupInfo @end
@interface HostGroupInfo : TLSObject
@property (nonatomic, copy) NSString *hostGroupId;
@property (nonatomic, copy) NSString *hostGroupName;
@property (nonatomic, copy) NSString *hostGroupType;
@property (nonatomic, copy) NSString *hostIdentifier;
@property (nonatomic, copy) NSNumber *hostCount;
@property (nonatomic, copy) NSNumber *normalHeartbeatStatusCount;
@property (nonatomic, copy) NSNumber *abnormalHeartbeatStatusCount;
@property (nonatomic, copy) NSNumber *ruleCount;
@property (nonatomic, assign) BOOL autoUpdate;
@property (nonatomic, copy) NSString *updateStartTime;
@property (nonatomic, copy) NSString *updateEndTime;
@property (nonatomic, copy) NSString *agentLatestVersion;
@property (nonatomic, copy) NSString *createTime;
@property (nonatomic, copy) NSString *modifyTime;
@property (nonatomic, assign) BOOL serviceLogging;
@end

@protocol HostInfo @end
@interface HostInfo : TLSObject
@property (nonatomic, copy) NSString *ip;
@property (nonatomic, copy) NSString *logCollectorVersion;
@property (nonatomic, copy) NSNumber *heartbeatStatus;
@end

@protocol HostGroupHostsRulesInfo @end
@interface HostGroupHostsRulesInfo : TLSObject
@property (nonatomic, copy) HostGroupInfo *hostGroupInfo;
@property (nonatomic, copy) NSArray<HostInfo*> *hostInfos;
@property (nonatomic, copy) NSArray<RuleInfo*> *ruleInfos;
@end

@protocol ValueInfo @end
@interface ValueInfo : TLSObject
@property (nonatomic, copy) NSString* valueType;
@property (nonatomic, copy) NSString* delimiter;
@property (nonatomic, assign) BOOL caseSensitive;
@property (nonatomic, assign) BOOL includeChinese;
@property (nonatomic, assign) BOOL sqlFlag;
@property (nonatomic, copy) NSArray<KeyValueInfo*>* jsonKeys;
@end

@protocol KeyValueInfo @end
@interface KeyValueInfo : TLSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) ValueInfo *value;
@end

@protocol ProjectInfo @end
@interface ProjectInfo : TLSObject
@property (nonatomic, copy) NSString *projectName;
@property (nonatomic, copy) NSString *projectId;
@property (nonatomic, copy) NSString *description;
@property (nonatomic, copy) NSString *createTime;
@property (nonatomic, copy) NSString *innerNetDomain;
@property (nonatomic, copy) NSNumber *topicCount;
@end

@protocol QueryResp @end
@interface QueryResp : TLSObject
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSNumber *shardId;
@property (nonatomic, copy) NSString *inclusiveBeginKey;
@property (nonatomic, copy) NSString *exclusiveEndKey;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy) NSString *modifyTime;
@end

@protocol TaskInfo @end
@interface TaskInfo : TLSObject
@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, copy) NSString *taskName;
@property (nonatomic, copy) NSString *topicId;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, copy) NSString *startTime;
@property (nonatomic, copy) NSString *endTime;
@property (nonatomic, copy) NSString *dataFormat;
@property (nonatomic, copy) NSString *taskStatus;
@property (nonatomic, copy) NSString *compression;
@property (nonatomic, copy) NSString *createTime;
@property (nonatomic, copy) NSNumber *logSize;
@property (nonatomic, copy) NSNumber *logCount;
@end

@protocol TopicInfo @end
@interface TopicInfo : TLSObject
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

@protocol PutLogsV2LogItem @end
@interface PutLogsV2LogItem : TLSObject
@property (nonatomic, copy) NSNumber *time;
@property (nonatomic, copy) NSDictionary *contents;
- (instancetype)initWithKeyValueAndTime:(NSDictionary *)keyValue timeStamp:(NSNumber*)timeStamp;
@end


#endif /* TLSModel_h */

