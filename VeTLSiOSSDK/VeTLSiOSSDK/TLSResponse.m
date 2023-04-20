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
#import "TLSResponse.h"

#define GENERAL_RESPONSE_IMPLEMENTION \
+ (JSONKeyMapper *) keyMapper { return [JSONKeyMapper mapperForTitleCase]; }

@implementation CommonResponse
+(BOOL)propertyIsOptional:(NSString*)propertyName {
  return YES;
}
@end

// Project below

@implementation CreateProjectResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DeleteProjectResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation ModifyProjectResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeProjectResponse
@synthesize description = _description;
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeProjectsResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

// Topic below

@implementation CreateTopicResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DeleteTopicResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation ModifyTopicResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeTopicResponse
@synthesize description = _description;
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeTopicsResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

// Shard below

@implementation DescribeShardsResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

// Index below

@implementation CreateIndexResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DeleteIndexResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation ModifyIndexResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeIndexResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

// Log below

@implementation PutLogsResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation PutLogsV2Response
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeCursorResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation ConsumeLogsResponse
+ (JSONKeyMapper *) keyMapper { return [JSONKeyMapper mapperForTitleCase]; }
@end

@implementation SearchLogsResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeLogContextResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeHistogramResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation WebTracksResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation CreateDownloadTaskResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeDownloadTasksResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeDownloadUrlResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

// Hostgroup below

@implementation CreateHostGroupResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DeleteHostGroupResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation ModifyHostGroupResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeHostGroupsResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeHostGroupResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeHostsResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DeleteHostResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeHostGroupRulesResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation ModifyHostGroupsAutoUpdateResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

// Rule below

@implementation CreateRuleResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DeleteRuleResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation ModifyRuleResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeRuleResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeRulesResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation ApplyRuleToHostGroupsResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DeleteRuleFromHostGroupsResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

// Alarm below

@implementation CreateAlarmNotifyGroupResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DeleteAlarmNotifyGroupResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation ModifyAlarmNotifyGroupResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeAlarmNotifyGroupsResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation CreateAlarmResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DeleteAlarmResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation ModifyAlarmResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeAlarmsResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

// Kafka consumer below

@implementation OpenKafkaConsumerResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation CloseKafkaConsumerResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

@implementation DescribeKafkaConsumerResponse
GENERAL_RESPONSE_IMPLEMENTION
@end

