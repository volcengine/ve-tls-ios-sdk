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
#import "JSONModel/JSONModelLib.h"
#import "TLSModel.h"

#define GENERAL_KEY_MAPPER \
+ (JSONKeyMapper *)keyMapper { \
    return [JSONKeyMapper mapperForTitleCase]; \
}

@implementation TLSObject
+(BOOL)propertyIsOptional:(NSString*)propertyName {
  return YES;
}
@end

@implementation Advanced
GENERAL_KEY_MAPPER
@end

// 注意: 这里没有 Plugin, Plugin 使用默认的 Mapper, 不需要 TitleCase

@implementation Plugin
@end

@implementation ParsePathRule
GENERAL_KEY_MAPPER
@end

@implementation ShardHashKey
GENERAL_KEY_MAPPER
@end

@implementation UserDefineRule
GENERAL_KEY_MAPPER
@end

@implementation ExcludePath
GENERAL_KEY_MAPPER
@end

@implementation LogTemplate
GENERAL_KEY_MAPPER
@end

@implementation FilterKeyRegex
GENERAL_KEY_MAPPER
@end

@implementation Receiver
GENERAL_KEY_MAPPER
@end

@implementation AlarmNotifyGroupInfo
GENERAL_KEY_MAPPER
@end

@implementation ExtractRule
GENERAL_KEY_MAPPER
@end

@implementation KubernetesRule
GENERAL_KEY_MAPPER
@end

@implementation ContainerRule
GENERAL_KEY_MAPPER
@end

@implementation RuleInfo
GENERAL_KEY_MAPPER
@end

@implementation QueryRequest
GENERAL_KEY_MAPPER
@end

@implementation RequestCycle
GENERAL_KEY_MAPPER
@end

@implementation AlarmInfo
GENERAL_KEY_MAPPER
@end

@implementation AnalysisResult
GENERAL_KEY_MAPPER
@end

@implementation FullTextInfo
GENERAL_KEY_MAPPER
@end

@implementation HistogramInfo
GENERAL_KEY_MAPPER
@end

@implementation HostGroupInfo
GENERAL_KEY_MAPPER
@end

@implementation HostInfo
GENERAL_KEY_MAPPER
@end

@implementation HostGroupHostsRulesInfo
GENERAL_KEY_MAPPER
@end

@implementation ValueInfo
GENERAL_KEY_MAPPER
@end

@implementation KeyValueInfo
GENERAL_KEY_MAPPER
@end

@implementation ProjectInfo
@synthesize description = _description;
GENERAL_KEY_MAPPER
@end

@implementation QueryResp
GENERAL_KEY_MAPPER
@end

@implementation TaskInfo
GENERAL_KEY_MAPPER
@end

@implementation TopicInfo
@synthesize description = _description;
GENERAL_KEY_MAPPER
@end

@implementation PutLogsV2LogItem
- (instancetype)initWithKeyValueAndTime:(NSDictionary *)keyValue timeStamp:(NSNumber*)timeStamp {
    if (self = [super init]) {
        _contents = keyValue;
        _time = timeStamp;
    }
    return self;
}
@end
