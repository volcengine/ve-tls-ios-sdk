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

/**
 * @param parsePathRule 解析采集路径的规则
 * @param shardHashKey 路由日志分区的规则
 * @param enableRawLog 是否上传原始日志
 * @param fields 为日志添加常量字段
 * @param plugin LogCollector 插件配置
 * @param advanced LogCollector 扩展配置
 * @param tailFiles LogCollector 采集策略
 */
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

/**
 * @param type 采集路径类型
 * @param value 采集路径
 */
@protocol ExcludePath @end
@interface ExcludePath : TLSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *value;
@end

/**
 * @param type 日志模板的类型
 * @param format 日志模板内容
 */
@protocol LogTemplate @end
@interface LogTemplate : TLSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *format;
@end

/**
 * @param key 过滤字段的名称
 * @param regex 过滤字段的日志内容需要匹配的正则表达式
 */
@protocol FilterKeyRegex @end
@interface FilterKeyRegex : TLSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *regex;
@end
/**
 * @param receiverType 接受者类型
 * @param receiverNames 接收者的名字
 * @param receiverChannels 通知接收渠道，支持Email、Sms、Phone
 * @param startTime 可接收信息的时段中，开始的时间
 * @param endTime 可接收信息的时段中，结束的时间
 */
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

/**
 * @param delimiter 日志分隔符
 * @param beginRegex 第一行日志需要匹配的正则表达式
 * @param logRegex 整条日志需要匹配的正则表达式
 * @param keys 日志字段名称（Key）列表
 * @param timeKey 日志时间字段的字段名称
 * @param timeFormat 时间字段的解析格式
 * @param filterKeyRegex 过滤规则列表
 * @param unMatchUpLoadSwitch 是否上传解析失败的日志
 * @param unMatchLogKey 当上传解析失败的日志时，解析失败的日志的 key 名称
 * @param logTemplate 根据指定的日志模板自动提取日志字段
 */
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

/**
 * @param namespaceNameRegex 待采集的 Kubernetes Namespace 名称，不指定 Namespace 名称时表示采集全部容器
 * @param workloadType 通过工作负载的类型指定采集的容器，仅支持选择一种类型
 * @param workloadNameRegex 通过工作负载的名称指定待采集的容器
 * @param includePodLabelRegex Pod Label 白名单用于指定待采集的容器
 * @param excludePodLabelRegex 通过 Pod Label 黑名单指定不采集的容器，不启用表示采集全部容器
 * @param podNameRegex Pod名称用于指定待采集的容器
 * @param labelTag 是否将 Kubernetes Label 作为日志标签
 */
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

/**
 * @param stream 采集模式
 * @param containerNameRegex 待采集的容器名称
 * @param includeContainerLabelRegex 容器 Label 白名单通过容器 Label 指定待采集的容器
 * @param excludeContainerLabelRegex 容器 Label 黑名单用于指定不采集的容器范围
 * @param includeContainerEnvRegex 容器环境变量白名单通过容器环境变量指定待采集的容器
 * @param excludeContainerEnvRegex 容器环境变量黑名单用于指定不采集的容器范围
 * @param envTag 是否将环境变量作为日志标签，添加到原始日志数据中
 * @param kubernetesRule Kubernetes 容器的采集规则
 */
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

/**
 * @param type 执行周期类型
 * @param time 告警任务执行的周期，或者定期执行的时间点
 */
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
/**
 * @param caseSensitive 是否大小写敏感。
 * @param delimiter 全文索引的分词符。
 * @param includeChinese 是否包含中文。默认为 false
 */
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
/**
 * @param key 需要配置键值索引的字段名称。
 * @param value 需要配置键值索引的字段描述信息。
 */
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

/**
 * @param time 时间戳
 * @param contents 日志内容dict
 */
@protocol PutLogsV2LogItem @end
@interface PutLogsV2LogItem : TLSObject
@property (nonatomic, copy) NSNumber *time;
@property (nonatomic, copy) NSMutableDictionary *contents;
- (instancetype)initWithCurrentTime;
- (instancetype)initWithKeyValueAndTime:(NSDictionary *)keyValue timeStamp:(NSNumber*)timeStamp;
- (BOOL) checkValue: (NSString *) value;
- (void) putContent: (NSString *) key value: (NSString *) value;
- (void) putContent: (NSString *) key intValue: (int) value;
- (void) putContent: (NSString *) key longValue: (long) value;
- (void) putContent: (NSString *) key longlongValue: (long long) value;
- (void) putContent: (NSString *) key floatValue: (float) value;
- (void) putContent: (NSString *) key doubleValue: (double) value;
- (void) putContent: (NSString *) key boolValue: (BOOL) value;
- (BOOL) putContent: (NSData *) value;
- (BOOL) putContent: (NSString *) key dataValue: (NSData *) value;
- (BOOL) putContent: (NSString *) key arrayValue: (NSArray *) value;
- (BOOL) putContent: (NSString *) key dictValue: (NSDictionary *) value;
- (BOOL) putContents: (NSDictionary *) dict;
@end


#endif /* TLSModel_h */

