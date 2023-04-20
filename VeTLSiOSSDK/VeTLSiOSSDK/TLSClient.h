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
#import "TLSClientConfig.h"
#import "TLSRequest.h"
#import "TLSResponse.h"
#import "VeCore.h"

#ifndef TLSClient_h
#define TLSClient_h

#define TLS_CLIENT_INTERFACE_DECLARE(method) \
- (method##Response*) method:(method##Request*)request;


@interface TLSClient : NSObject
@property (nonatomic, copy) TLSClientConfig *config;
// HttpRequest
- (VeTask *)invokeRequest: (TLSRequest *)request;
- (instancetype)initWithConfig: (TLSClientConfig *)config;

// Project below
TLS_CLIENT_INTERFACE_DECLARE(CreateProject);
TLS_CLIENT_INTERFACE_DECLARE(DeleteProject);
TLS_CLIENT_INTERFACE_DECLARE(ModifyProject);
TLS_CLIENT_INTERFACE_DECLARE(DescribeProject);
TLS_CLIENT_INTERFACE_DECLARE(DescribeProjects);
// Topic below
TLS_CLIENT_INTERFACE_DECLARE(CreateTopic);
TLS_CLIENT_INTERFACE_DECLARE(DeleteTopic);
TLS_CLIENT_INTERFACE_DECLARE(ModifyTopic);
TLS_CLIENT_INTERFACE_DECLARE(DescribeTopic);
TLS_CLIENT_INTERFACE_DECLARE(DescribeTopics);
// Shard below
TLS_CLIENT_INTERFACE_DECLARE(DescribeShards);
// Index below
TLS_CLIENT_INTERFACE_DECLARE(CreateIndex);
TLS_CLIENT_INTERFACE_DECLARE(DeleteIndex);
TLS_CLIENT_INTERFACE_DECLARE(ModifyIndex);
TLS_CLIENT_INTERFACE_DECLARE(DescribeIndex);
// Log below
TLS_CLIENT_INTERFACE_DECLARE(PutLogs);
TLS_CLIENT_INTERFACE_DECLARE(PutLogsV2);
- (VeTask*) PutLogsAsync:(PutLogsRequest*)request;
- (VeTask*) PutLogsV2Async:(PutLogsV2Request*)request;
// 因为IOS环境限制, 这两个方法暂时无法提供
//TLS_CLIENT_INTERFACE_DECLARE(DescribeCursor);
//TLS_CLIENT_INTERFACE_DECLARE(ConsumeLogs);
TLS_CLIENT_INTERFACE_DECLARE(SearchLogs);
TLS_CLIENT_INTERFACE_DECLARE(DescribeLogContext);
TLS_CLIENT_INTERFACE_DECLARE(DescribeHistogram);
TLS_CLIENT_INTERFACE_DECLARE(WebTracks);
TLS_CLIENT_INTERFACE_DECLARE(CreateDownloadTask);
TLS_CLIENT_INTERFACE_DECLARE(DescribeDownloadTasks);
TLS_CLIENT_INTERFACE_DECLARE(DescribeDownloadUrl);
// HostGroup below
TLS_CLIENT_INTERFACE_DECLARE(CreateHostGroup);
TLS_CLIENT_INTERFACE_DECLARE(DeleteHostGroup);
TLS_CLIENT_INTERFACE_DECLARE(ModifyHostGroup);
TLS_CLIENT_INTERFACE_DECLARE(DescribeHostGroup);
TLS_CLIENT_INTERFACE_DECLARE(DescribeHostGroups);
TLS_CLIENT_INTERFACE_DECLARE(DescribeHosts);
TLS_CLIENT_INTERFACE_DECLARE(DeleteHost);
TLS_CLIENT_INTERFACE_DECLARE(DescribeHostGroupRules);
TLS_CLIENT_INTERFACE_DECLARE(ModifyHostGroupsAutoUpdate);
// Rule below
TLS_CLIENT_INTERFACE_DECLARE(CreateRule);
TLS_CLIENT_INTERFACE_DECLARE(DeleteRule);
TLS_CLIENT_INTERFACE_DECLARE(ModifyRule);
TLS_CLIENT_INTERFACE_DECLARE(DescribeRule);
TLS_CLIENT_INTERFACE_DECLARE(DescribeRules);
TLS_CLIENT_INTERFACE_DECLARE(ApplyRuleToHostGroups);
TLS_CLIENT_INTERFACE_DECLARE(DeleteRuleFromHostGroups);
// Alarm below
TLS_CLIENT_INTERFACE_DECLARE(CreateAlarmNotifyGroup);
TLS_CLIENT_INTERFACE_DECLARE(DeleteAlarmNotifyGroup);
TLS_CLIENT_INTERFACE_DECLARE(ModifyAlarmNotifyGroup);
TLS_CLIENT_INTERFACE_DECLARE(DescribeAlarmNotifyGroups);
TLS_CLIENT_INTERFACE_DECLARE(CreateAlarm);
TLS_CLIENT_INTERFACE_DECLARE(DeleteAlarm);
TLS_CLIENT_INTERFACE_DECLARE(ModifyAlarm);
TLS_CLIENT_INTERFACE_DECLARE(DescribeAlarms);
// Kafka consumer below
TLS_CLIENT_INTERFACE_DECLARE(OpenKafkaConsumer);
TLS_CLIENT_INTERFACE_DECLARE(CloseKafkaConsumer);
TLS_CLIENT_INTERFACE_DECLARE(DescribeKafkaConsumer);
@end

#endif /* TLSClient_h */
