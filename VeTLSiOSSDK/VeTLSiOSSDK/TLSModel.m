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

- (instancetype)initWithCurrentTime {
    if (self = [super init]) {
        _contents = [NSMutableDictionary dictionary];
        _time = 0;
    }
    return self;
}

- (instancetype)initWithKeyValueAndTime:(NSDictionary *)keyValue timeStamp:(NSNumber*)timeStamp {
    if (self = [super init]) {
        _contents = [NSMutableDictionary dictionary];
        _time = 0;
        [self putContents:keyValue];
    }
    return self;
}

- (BOOL) checkValue:(NSString *)value {
    return value && [value isKindOfClass:[NSString class]];
}

- (void) putContent: (NSString *) key value: (NSString *) value {
    if ([self checkValue:key] && [self checkValue:value]) {
        [_contents setObject:value forKey:key];
    }
}

- (void) putContent: (NSString *) key intValue: (int) value {
    if ([self checkValue:key]) {
        [_contents setObject:[NSString stringWithFormat:@"%d", value] forKey:key];
    }
}

- (void) putContent: (NSString *) key longValue: (long) value {
    if ([self checkValue:key]) {
        [_contents setObject:[NSString stringWithFormat:@"%ld", value] forKey:key];
    }
}

- (void) putContent: (NSString *) key longlongValue: (long long) value {
    if ([self checkValue:key]) {
        [_contents setObject:[NSString stringWithFormat:@"%lld", value] forKey:key];
    }
}

- (void) putContent: (NSString *) key floatValue: (float) value {
    if ([self checkValue:key]) {
        [_contents setObject:[NSString stringWithFormat:@"%f", value] forKey:key];
    }
}

- (void) putContent: (NSString *) key doubleValue: (double) value {
    if ([self checkValue:key]) {
        [_contents setObject:[NSString stringWithFormat:@"%f", value] forKey:key];
    }
}

- (void) putContent: (NSString *) key boolValue: (BOOL) value {
    if ([self checkValue:key]) {
        [NSNumber numberWithBool:YES];
        [_contents setObject:(YES == value ? @"YES" : @"NO") forKey:key];
    }
}

- (BOOL) putContent: (NSData *) value {
    if (!value) {
        return NO;
    }
    
    if ([value isKindOfClass:[NSNull class]]) {
        [self putContent:@"data" value:@"null"];
        return YES;
    }
    
    NSError *error = nil;
    id data = [NSJSONSerialization JSONObjectWithData:value
                                              options:kNilOptions
                                                error:&error
    ];
    
    if (nil != error) {
        NSString *string = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
        [self putContent:@"data" value:string];
        return YES;
    }
    
    if ([data isKindOfClass:[NSDictionary class]]) {
        [self putContents:data];
    } else if ([data isKindOfClass:[NSArray class]]) {
        [self putContent:@"data" arrayValue:data];
    } else {
        return NO;
    }
    
    return YES;
}

- (BOOL) putContent: (NSString *) key dataValue: (NSData *) value {
    if ([self checkValue:key] && value && ![value isKindOfClass:[NSNull class]]) {
        [_contents setObject:[[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding] forKey:key];
        return YES;
    }
    return NO;
}

- (BOOL) putContent: (NSString *) key arrayValue: (NSArray *) value {
    if ([self checkValue:key] && value && [NSJSONSerialization isValidJSONObject:value]) {
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:kNilOptions error:&error];
        if (nil != error) {
            return NO;
        }
        [_contents setObject:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] forKey:key];
        return YES;
    }
    return NO;
}

- (BOOL) putContent: (NSString *) key dictValue: (NSDictionary *) value {
    if ([self checkValue:key] && value && [NSJSONSerialization isValidJSONObject:value]) {
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:kNilOptions error:&error];
        if (nil != error) {
            return NO;
        }
        [_contents setObject:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] forKey:key];
        return YES;
    }
    return NO;
}

- (BOOL) putContents: (NSDictionary *) dict {
    if (!dict) {
        return NO;
    }
    
    NSDictionary *tmp = [NSDictionary dictionaryWithDictionary:dict];
    NSMutableDictionary *newDict = [NSMutableDictionary dictionary];
    
    BOOL error = NO;
    id value = nil;
    for (id key in tmp.allKeys) {
        if (![key isKindOfClass:[NSString class]]) {
            error = YES;
            break;
        }
        
        value = [tmp objectForKey:key];
        if ([value isKindOfClass:[NSString class]]) {
            [newDict setObject:value forKey:key];
        } else if ([value isKindOfClass:[NSNumber class]]) {
            [newDict setObject:[value stringValue] forKey:key];
        } else if ([value isKindOfClass:[NSNull class]]) {
            [newDict setObject:@"null" forKey:key];
        } else if (([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]])
                   && [NSJSONSerialization isValidJSONObject:value]) {
            [newDict setObject:[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:value options:kNilOptions error:nil] encoding:NSUTF8StringEncoding] forKey:key];
        } else {
            error = YES;
            break;
        }
    }
    
    if (!error) {
        [_contents addEntriesFromDictionary:newDict];
    }
    
    return error;
}


@end
