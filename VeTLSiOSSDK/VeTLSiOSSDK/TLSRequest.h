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
+ (BOOL)propertyIsOptional:(NSString *)propertyName;

- (NSDictionary *)queryParamsDict;

- (NSDictionary *)headerParamsDict:(NSString *)apiVersion;

- (NSData *)requestBody;

- (NSString *)httpMethod;

- (NSString *)urlPath;

- (NSURL *)urlWithVeEndpoint:(VeEndpoint *)endpoint path:(NSString *)path;

- (bool)checkValidation;
@end

/**
 * @param projectName 项目名称
 * @param region 地域
 * @param description 项目描述
 */
@interface CreateProjectRequest : TLSRequest
@property(nonatomic, copy) NSString *projectName;
@property(nonatomic, copy) NSString *region;
@property(nonatomic, copy) NSString *description;
@end

/**
 * @param projectId 日志项目id
 */
@interface DeleteProjectRequest : TLSRequest
@property(nonatomic, copy) NSString *projectId;
@end

/**
 * @param projectId 日志项目id
 * @param projectName 日志项目名称
 * @param description 日志项目描述
 */
@interface ModifyProjectRequest : TLSRequest
@property(nonatomic, copy) NSString *projectId;
@property(nonatomic, copy) NSString *projectName;
@property(nonatomic, copy) NSString *description;
@end

/**
 * @param projectId 日志项目id
 */
@interface DescribeProjectRequest : TLSRequest
@property(nonatomic, copy) NSString *projectId;
@end

/**
 * @param pageNumber 页码，从1开始
 * @param pageSize 页大小，最大100，默认20
 * @param projectName 日志项目名称
 * @param isFullName 是否准确搜索
 * @param projectId 日志项目id
 */
@interface DescribeProjectsRequest : TLSRequest
@property(nonatomic, copy) NSNumber *pageNumber;
@property(nonatomic, copy) NSNumber *pageSize;
@property(nonatomic, copy) NSString *projectName;
@property(nonatomic, assign) BOOL isFullName;
@property(nonatomic, copy) NSString *projectId;
@end

/**
 * @param topicName 日志主题名称
 * @param projectId 日志项目id
 * @param ttl 数据保留时间单位天，默认30
 * @param shardCount 日志分区的数量，默认创建 1 个分区，取值范围为 1～10
 * @param autoSplit 是否自动分裂，默认true
 * @param maxSplitShard 最大分裂shard数，取值范围为 1~10，默认为 10。
 * @param enableTracking 是否开启 WebTracking 功能
 * @param timeKey 日志时间字段的字段名称
 * @param timeFormat 时间字段的解析格式
 * @param description 日志主题描述
 */
@interface CreateTopicRequest : TLSRequest
@property(nonatomic, copy) NSString *topicName;
@property(nonatomic, copy) NSString *projectId;
@property(nonatomic, copy) NSNumber *ttl;
@property(nonatomic, copy) NSNumber *shardCount;
@property(nonatomic, assign) BOOL autoSplit;
@property(nonatomic, copy) NSNumber *maxSplitShard;
@property(nonatomic, assign) BOOL enableTracking;
@property(nonatomic, copy) NSString *timeKey;
@property(nonatomic, copy) NSString *timeFormat;
@property(nonatomic, copy) NSString *description;
@end

/**
 * @param topicId 日志主题id
 */
@interface DeleteTopicRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@end

/**
 * @param topicId 日志主题id
 * @param topicName 日志主题名称
 * @param ttl 数据保留时间单位天，默认30
 * @param autoSplit 是否自动分裂，默认true
 * @param maxSplitShard 最大分裂shard数，取值范围为 1~10，默认为 10。
 * @param enableTracking 是否开启 WebTracking 功能
 * @param timeKey 日志时间字段的字段名称
 * @param timeFormat 时间字段的解析格式
 * @param description 日志主题描述
 */
@interface ModifyTopicRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) NSString *topicName;
@property(nonatomic, copy) NSNumber *ttl;
@property(nonatomic, assign) BOOL autoSplit;
@property(nonatomic, copy) NSNumber *maxSplitShard;
@property(nonatomic, assign) BOOL enableTracking;
@property(nonatomic, copy) NSString *timeKey;
@property(nonatomic, copy) NSString *timeFormat;
@property(nonatomic, copy) NSString *description;
@end

/**
 * @param topicId 日志主题id
 */
@interface DescribeTopicRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@end

/**
 * @param projectId 日志项目id
 * @param pageNumber 页码，从1开始
 * @param pageSize 页大小，最大100，默认20
 * @param topicName 日志主题名称
 * @param isFullName 是否准确搜索
 * @param topicId 日志主题id
 */
@interface DescribeTopicsRequest : TLSRequest
@property(nonatomic, copy) NSString *projectId;
@property(nonatomic, copy) NSNumber *pageNumber;
@property(nonatomic, copy) NSNumber *pageSize;
@property(nonatomic, copy) NSString *topicName;
@property(nonatomic, assign) BOOL isFullName;
@property(nonatomic, copy) NSString *topicId;
@end

/**
 * @param topicId 日志主题id
 * @param pageNumber 页码，从1开始
 * @param pageSize 页大小，最大100，默认20
 */
@interface DescribeShardsRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) NSNumber *pageNumber;
@property(nonatomic, copy) NSNumber *pageSize;
@end

/**
 * @param topicId 日志主题id
 * @param fullText 全文索引配置
 * @param keyValue 键值索引配置List
 */
@interface CreateIndexRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) FullTextInfo *fullText;
@property(nonatomic, copy) NSArray<KeyValueInfo *> <KeyValueInfo> *keyValue;
@end

/**
 * @param topicId 日志主题id
 */
@interface DeleteIndexRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@end

/**
 * @param topicId 日志主题id
 * @param fullText 全文索引配置
 * @param keyValue 键值索引配置List
 */
@interface ModifyIndexRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) FullTextInfo *fullText;
@property(nonatomic, copy) NSArray<KeyValueInfo *> <KeyValueInfo> *keyValue;
@end

/**
 * @param topicId 日志主题id
 */
@interface DescribeIndexRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@end

/**
 * @param hashKey 日志服务会将数据写入到包含该 Key 值的 Shard 中
 * @param compressType 压缩格式支持lz4、zlib。默认不压缩
 * @param topicId 日志主题id
 * @param logGroupList 日志数据列表
 */
@interface PutLogsRequest : TLSRequest
@property(nonatomic, copy) NSString *hashKey;
@property(nonatomic, copy) NSString *compressType;
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) LogGroupList *logGroupList;
@end

/**
 * @param hashKey 日志服务会将数据写入到包含该 Key 值的 Shard 中
 * @param compressType 压缩格式支持lz4、zlib。默认不压缩
 * @param topicId 日志主题id
 * @param fileName 日志文件名。
 * @param source 日志来源，一般使用机器 IP 作为标识。
 * @param logs 日志数据列表
 */
@interface PutLogsV2Request : TLSRequest
@property(nonatomic, copy) NSString *hashKey;
@property(nonatomic, copy) NSString *compressType;
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) NSString *fileName;
@property(nonatomic, copy) NSString *source;
@property(nonatomic, copy) NSArray<PutLogsV2LogItem *> <PutLogsV2LogItem> *logs;
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

/**
 * @param topicId 日志主题id
 * @param query 查询分析语句，语句长度最大为 4 KiB。
 * @param startTime 查询开始时间点
 * @param endTime 查询结束时间点
 * @param limit 返回的日志条数，最大值为 1000
 * @param context 翻页加载更多日志时使用
 * @param sort 按日志时间戳顺序返回日志支持ase、desc，默认desc降序
 */
@interface SearchLogsRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) NSString *query;
@property(nonatomic, copy) NSNumber *startTime;
@property(nonatomic, copy) NSNumber *endTime;
@property(nonatomic, copy) NSNumber *limit;
@property(nonatomic, copy) NSString *context;
@property(nonatomic, copy) NSString *sort;
@end

/**
 * @param topicId 日志主题id
 * @param query 查询分析语句，语句长度最大为 4 KiB。
 * @param startTime 查询开始时间点
 * @param endTime 查询结束时间点
 * @param limit 返回的日志条数，最大值为 1000
 * @param context 翻页加载更多日志时使用
 * @param sort 按日志时间戳顺序返回日志支持ase、desc，默认desc降序
 */
@interface SearchLogsV2Request : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) NSString *query;
@property(nonatomic, copy) NSNumber *startTime;
@property(nonatomic, copy) NSNumber *endTime;
@property(nonatomic, copy) NSNumber *limit;
@property(nonatomic, copy) NSString *context;
@property(nonatomic, copy) NSString *sort;
@end

/**
 * @param topicId 日志主题id
 * @param contextFlow 指定日志所在的 LogGroup 的 ID
 * @param packageOffset 指定日志在 LogGroup 的序号
 * @param source 日志来源主机 IP
 * @param prevLogs 指定日志的上文日志条数
 * @param nextLogs 指定日志的下文日志条数
 */
@interface DescribeLogContextRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) NSString *contextFlow;
@property(nonatomic, copy) NSNumber *packageOffset;
@property(nonatomic, copy) NSString *source;
@property(nonatomic, copy) NSNumber *prevLogs;
@property(nonatomic, copy) NSNumber *nextLogs;
@end

/**
 * @param topicId 日志主题id
 * @param query 查询分析语句，语句长度最大为 4 KiB。
 * @param startTime 查询开始时间点
 * @param endTime 查询结束时间点
 * @param interval 直方图的子区间长度
 */
@interface DescribeHistogramRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) NSString *query;
@property(nonatomic, copy) NSNumber *startTime;
@property(nonatomic, copy) NSNumber *endTime;
@property(nonatomic, copy) NSNumber *interval;
@end

/**
 * @param projectId 日志项目id
 * @param topicId 日志主题id
 * @param compressType 压缩格式支持lz4、zlib。默认不压缩
 * @param logs 日志数据
 * @param source 日志来源主机 IP
 */
@interface WebTracksRequest : TLSRequest
@property(nonatomic, copy) NSString *projectId;
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) NSString *compressType;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *logs;
@property(nonatomic, copy) NSString *source;
@end

/**
 * @param taskName 下载任务名称
 * @param topicId 日志主题id
 * @param query 查询分析语句，语句长度最大为 4 KiB。
 * @param startTime 查询开始时间点
 * @param endTime 查询结束时间点
 * @param dataFormat 导出的文件格式，支持csv、json
 * @param sort 按日志时间戳顺序返回日志支持ase、desc，默认desc降序
 * @param limit 返回的日志条数，最大值为 1000
 * @param compression 压缩方式，目前只支持gip
 */
@interface CreateDownloadTaskRequest : TLSRequest
@property(nonatomic, copy) NSString *taskName;
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) NSString *query;
@property(nonatomic, copy) NSNumber *startTime;
@property(nonatomic, copy) NSNumber *endTime;
@property(nonatomic, copy) NSString *dataFormat;
@property(nonatomic, copy) NSString *sort;
@property(nonatomic, copy) NSNumber *limit;
@property(nonatomic, copy) NSString *compression;
@end

/**
 * @param topicId 日志主题id
 * @param pageNumber 页码，从1开始
 * @param pageSize 页大小，最大100，默认20
 */
@interface DescribeDownloadTasksRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) NSNumber *pageNumber;
@property(nonatomic, copy) NSNumber *pageSize;
@end

/**
 * @param taskId 下载任务id
 */
@interface DescribeDownloadUrlRequest : TLSRequest
@property(nonatomic, copy) NSString *taskId;
@end

/**
 * @param hostGroupName 机器组的名称
 * @param hostGroupType 机器组的类型,IP或者Label
 * @param hostIpList 机器IP列表
 * @param hostIdentifier 机器标识
 * @param autoUpdate 机器组服务器中安装的 LogCollector 是否开启自动升级功能
 * @param updateStartTime LogCollector 自动升级的开始时间
 * @param updateEndTime LogCollector 自动升级的结束时间
 * @param serviceLogging 是否开启 LogCollector 服务日志功能
 */
@interface CreateHostGroupRequest : TLSRequest
@property(nonatomic, copy) NSString *hostGroupName;
@property(nonatomic, copy) NSString *hostGroupType;
@property(nonatomic, copy) NSArray<NSString *> *hostIpList;
@property(nonatomic, copy) NSString *hostIdentifier;
@property(nonatomic, assign) BOOL autoUpdate;
@property(nonatomic, copy) NSString *updateStartTime;
@property(nonatomic, copy) NSString *updateEndTime;
@property(nonatomic, assign) BOOL serviceLogging;
@end

/**
 * @param hostGroupId 机器组的id
 */
@interface DeleteHostGroupRequest : TLSRequest
@property(nonatomic, copy) NSString *hostGroupId;
@end

/**
 * @param hostGroupId 机器组的id
 * @param hostGroupName 机器组的名称
 * @param hostGroupType 机器组的类型,IP或者Label
 * @param hostIpList 机器IP列表
 * @param hostIdentifier 机器标识
 * @param autoUpdate 机器组服务器中安装的 LogCollector 是否开启自动升级功能
 * @param updateStartTime LogCollector 自动升级的开始时间
 * @param updateEndTime LogCollector 自动升级的结束时间
 * @param serviceLogging 是否开启 LogCollector 服务日志功能
 */
@interface ModifyHostGroupRequest : TLSRequest
@property(nonatomic, copy) NSString *hostGroupId;
@property(nonatomic, copy) NSString *hostGroupName;
@property(nonatomic, copy) NSString *hostGroupType;
@property(nonatomic, copy) NSArray<NSString *> *hostIpList;
@property(nonatomic, copy) NSString *hostIdentifier;
@property(nonatomic, assign) BOOL autoUpdate;
@property(nonatomic, copy) NSString *updateStartTime;
@property(nonatomic, copy) NSString *updateEndTime;
@property(nonatomic, assign) BOOL serviceLogging;
@end

/**
 * @param hostGroupId 机器组的id
 */
@interface DescribeHostGroupRequest : TLSRequest
@property(nonatomic, copy) NSString *hostGroupId;
@end

/**
 * @param hostGroupId 机器组的id
 * @param hostGroupName 机器组的名称
 * @param pageNumber 页码，从1开始
 * @param pageSize 页大小，最大100，默认20
 * @param autoUpdate 机器组服务器中安装的 LogCollector 是否开启自动升级功能
 * @param hostIdentifier 机器标识
 * @param serviceLogging 是否开启 LogCollector 服务日志功能
 */
@interface DescribeHostGroupsRequest : TLSRequest
@property(nonatomic, copy) NSString *hostGroupId;
@property(nonatomic, copy) NSString *hostGroupName;
@property(nonatomic, copy) NSNumber *pageNumber;
@property(nonatomic, copy) NSNumber *pageSize;
@property(nonatomic, assign) BOOL autoUpdate;
@property(nonatomic, copy) NSString *hostIdentifier;
@property(nonatomic, assign) BOOL serviceLogging;
@end

/**
 * @param hostGroupId 机器组的id
 * @param ip ip地址
 * @param heartbeatStatus 机器心跳状态
 * @param pageNumber 页码，从1开始
 * @param pageSize 页大小，最大100，默认20
 */
@interface DescribeHostsRequest : TLSRequest
@property(nonatomic, copy) NSString *hostGroupId;
@property(nonatomic, copy) NSString *ip;
@property(nonatomic, copy) NSNumber *heartbeatStatus;
@property(nonatomic, copy) NSNumber *pageNumber;
@property(nonatomic, copy) NSNumber *pageSize;
@end

/**
 * @param hostGroupId 机器组的id
 * @param ip ip地址
 */
@interface DeleteHostRequest : TLSRequest
@property(nonatomic, copy) NSString *hostGroupId;
@property(nonatomic, copy) NSString *ip;
@end

/**
 * @param hostGroupId 机器组的id
 * @param pageNumber 页码，从1开始
 * @param pageSize 页大小，最大100，默认20
 */
@interface DescribeHostGroupRulesRequest : TLSRequest
@property(nonatomic, copy) NSString *hostGroupId;
@property(nonatomic, copy) NSNumber *pageNumber;
@property(nonatomic, copy) NSNumber *pageSize;
@end

/**
 * @param hostGroupIds 机器组的id列表
 * @param autoUpdate 是否开启自动升级功能
 * @param updateStartTime LogCollector 自动升级的开始时间
 * @param updateEndTime LogCollector 自动升级的结束时间
 */

@interface ModifyHostGroupsAutoUpdateRequest : TLSRequest
@property(nonatomic, copy) NSArray<NSString *> *hostGroupIds;
@property(nonatomic, assign) BOOL autoUpdate;
@property(nonatomic, copy) NSString *updateStartTime;
@property(nonatomic, copy) NSString *updateEndTime;
@end

/**
 * @param topicId 日志主题id
 * @param ruleName 采集配置的名称
 * @param paths 采集路径列表
 * @param logType 采集模式
 * @param extractRule 日志提取规则
 * @param excludePaths 采集黑名单列表
 * @param userDefineRule 用户自定义的采集规则
 * @param logSample 日志样例
 * @param inputType 采集类型
 * @param containerRule 容器采集规则
 */
@interface CreateRuleRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) NSString *ruleName;
@property(nonatomic, copy) NSArray<NSString *> *paths;
@property(nonatomic, copy) NSString *logType;
@property(nonatomic, copy) ExtractRule *extractRule;
@property(nonatomic, copy) NSArray<ExcludePath *> <ExcludePath> *excludePaths;
@property(nonatomic, copy) UserDefineRule *userDefineRule;
@property(nonatomic, copy) NSString *logSample;
@property(nonatomic, copy) NSNumber *inputType;
@property(nonatomic, copy) ContainerRule *containerRule;
@end

/**
 * @param ruleId 采集配置id
 */
@interface DeleteRuleRequest : TLSRequest
@property(nonatomic, copy) NSString *ruleId;
@end

/**
 * @param ruleId 采集配置id
 * @param ruleName 采集配置的名称
 * @param paths 采集路径列表
 * @param logType 采集模式
 * @param extractRule 日志提取规则
 * @param excludePaths 采集黑名单列表
 * @param userDefineRule 用户自定义的采集规则
 * @param logSample 日志样例
 * @param inputType 采集类型
 * @param containerRule 容器采集规则
 */
@interface ModifyRuleRequest : TLSRequest
@property(nonatomic, copy) NSString *ruleId;
@property(nonatomic, copy) NSString *ruleName;
@property(nonatomic, copy) NSArray<NSString *> *paths;
@property(nonatomic, copy) NSString *logType;
@property(nonatomic, copy) ExtractRule *extractRule;
@property(nonatomic, copy) NSArray<ExcludePath *> <ExcludePath> *excludePaths;
@property(nonatomic, copy) UserDefineRule *userDefineRule;
@property(nonatomic, copy) NSString *logSample;
@property(nonatomic, copy) NSNumber *inputType;
@property(nonatomic, copy) ContainerRule *containerRule;
@end

/**
 * @param ruleId 采集配置id
 */
@interface DescribeRuleRequest : TLSRequest
@property(nonatomic, copy) NSString *ruleId;
@end

/**
 * @param projectId 日志项目id
 * @param ruleId 采集配置id
 * @param ruleName 采集配置的名称
 * @param topicId 日志主题id
 * @param topicName 日志主题名称
 * @param pageNumber 页码，从1开始
 * @param pageSize 页大小，最大100，默认20
 */
@interface DescribeRulesRequest : TLSRequest
@property(nonatomic, copy) NSString *projectId;
@property(nonatomic, copy) NSString *ruleId;
@property(nonatomic, copy) NSString *ruleName;
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) NSString *topicName;
@property(nonatomic, copy) NSNumber *pageNumber;
@property(nonatomic, copy) NSNumber *pageSize;
@end

/**
 * @param ruleId 采集配置id
 * @param hostGroupIds 机器组id列表
 */
@interface ApplyRuleToHostGroupsRequest : TLSRequest
@property(nonatomic, copy) NSString *ruleId;
@property(nonatomic, copy) NSArray<NSString *> *hostGroupIds;
@end

/**
 * @param ruleId 采集配置id
 * @param hostGroupIds 机器组id列表
 */
@interface DeleteRuleFromHostGroupsRequest : TLSRequest
@property(nonatomic, copy) NSString *ruleId;
@property(nonatomic, copy) NSArray<NSString *> *hostGroupIds;
@end

/**
 * @param alarmNotifyGroupName 告警通知组名称
 * @param notifyType 告警通知的类型
 * @param receivers 接收告警的 IAM 用户列表
 */
@interface CreateAlarmNotifyGroupRequest : TLSRequest
@property(nonatomic, copy) NSString *alarmNotifyGroupName;
@property(nonatomic, copy) NSArray<NSString *> *notifyType;
@property(nonatomic, copy) NSArray<Receiver *> <Receiver> *receivers;
@end

/**
 * @param alarmNotifyGroupId 告警通知组id
 */
@interface DeleteAlarmNotifyGroupRequest : TLSRequest
@property(nonatomic, copy) NSString *alarmNotifyGroupId;
@end

/**
 * @param alarmNotifyGroupId 告警通知组id
 * @param alarmNotifyGroupName 告警通知组名称
 * @param notifyType 告警通知的类型
 * @param receivers 接收告警的 IAM 用户列表
 */
@interface ModifyAlarmNotifyGroupRequest : TLSRequest
@property(nonatomic, copy) NSString *alarmNotifyGroupId;
@property(nonatomic, copy) NSString *alarmNotifyGroupName;
@property(nonatomic, copy) NSArray<NSString *> *notifyType;
@property(nonatomic, copy) NSArray<Receiver *> <Receiver> *receivers;
@end

/**
 * @param alarmNotifyGroupName 告警通知组名称
 * @param alarmNotifyGroupId 告警通知组id
 * @param receiverName 接收告警的 IAM 用户名称
 * @param pageNumber 页码，从1开始
 * @param pageSize 页大小，最大100，默认20
 */
@interface DescribeAlarmNotifyGroupsRequest : TLSRequest
@property(nonatomic, copy) NSString *alarmNotifyGroupName;
@property(nonatomic, copy) NSString *alarmNotifyGroupId;
@property(nonatomic, copy) NSString *receiverName;
@property(nonatomic, copy) NSNumber *pageNumber;
@property(nonatomic, copy) NSNumber *pageSize;
@end

/**
 * @param alarmName 告警策略名称
 * @param projectId 日志项目id
 * @param status 是否开启告警策略。默认值为 true，即开启
 * @param queryRequest 检索分析语句，可配置 1~3 条
 * @param requestCycle 查询或分析请求的执行周期
 * @param condition 告警触发条件
 * @param triggerPeriod 持续周期
 * @param alarmPeriod 告警重复的周期。单位是分钟。取值范围是 10~1440。
 * @param alarmNotifyGroup 告警对应的通知组列表
 * @param userDefineMsg 自定义告警通知内容
 */
@interface CreateAlarmRequest : TLSRequest
@property(nonatomic, copy) NSString *alarmName;
@property(nonatomic, copy) NSString *projectId;
@property(nonatomic, assign) BOOL status;
@property(nonatomic, copy) NSArray<QueryRequest *> <QueryRequest> *queryRequest;
@property(nonatomic, copy) RequestCycle *requestCycle;
@property(nonatomic, copy) NSString *condition;
@property(nonatomic, copy) NSNumber *triggerPeriod;
@property(nonatomic, copy) NSNumber *alarmPeriod;
@property(nonatomic, copy) NSArray<NSString *> *alarmNotifyGroup;
@property(nonatomic, copy) NSString *userDefineMsg;
@end

/**
 * @param alarmId 告警策略ID
 */
@interface DeleteAlarmRequest : TLSRequest
@property(nonatomic, copy) NSString *alarmId;
@end

/**
 * @param alarmId 告警策略ID
 * @param alarmName 告警策略名称
 * @param status 是否开启告警策略。默认值为 true，即开启
 * @param queryRequest 检索分析语句，可配置 1~3 条
 * @param requestCycle 查询或分析请求的执行周期
 * @param condition 告警触发条件
 * @param triggerPeriod 持续周期
 * @param alarmPeriod 告警重复的周期。单位是分钟。取值范围是 10~1440。
 * @param alarmNotifyGroup 告警对应的通知组列表
 * @param userDefineMsg 自定义告警通知内容
 */
@interface ModifyAlarmRequest : TLSRequest
@property(nonatomic, copy) NSString *alarmId;
@property(nonatomic, copy) NSString *alarmName;
@property(nonatomic, assign) BOOL status;
@property(nonatomic, copy) NSArray<QueryRequest *> <QueryRequest> *queryRequest;
@property(nonatomic, copy) RequestCycle *requestCycle;
@property(nonatomic, copy) NSString *condition;
@property(nonatomic, copy) NSNumber *triggerPeriod;
@property(nonatomic, copy) NSNumber *alarmPeriod;
@property(nonatomic, copy) NSArray<NSString *> *alarmNotifyGroup;
@property(nonatomic, copy) NSString *userDefineMsg;
@end

/**
 * @param projectId 日志项目id
 * @param alarmName 告警策略名称
 * @param alarmId 告警策略ID
 * @param topicId 日志主题id
 * @param topicName 日志主题名称
 * @param status 是否开启告警策略。默认值为 true，即开启
 * @param pageNumber 页码，从1开始
 * @param pageSize 页大小，最大100，默认20
 */
@interface DescribeAlarmsRequest : TLSRequest
@property(nonatomic, copy) NSString *projectId;
@property(nonatomic, copy) NSString *alarmName;
@property(nonatomic, copy) NSString *alarmId;
@property(nonatomic, copy) NSString *topicId;
@property(nonatomic, copy) NSString *topicName;
@property(nonatomic, assign) BOOL status;
@property(nonatomic, copy) NSNumber *pageNumber;
@property(nonatomic, copy) NSNumber *pageSize;
@end

/**
 * @param topicId 日志主题id
 */
@interface OpenKafkaConsumerRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@end

/**
 * @param topicId 日志主题id
 */
@interface CloseKafkaConsumerRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@end

/**
 * @param topicId 日志主题id
 */
@interface DescribeKafkaConsumerRequest : TLSRequest
@property(nonatomic, copy) NSString *topicId;
@end


#endif /* TLSRequest_h */
