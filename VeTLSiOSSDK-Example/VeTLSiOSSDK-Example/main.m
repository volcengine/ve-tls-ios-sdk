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
#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import <VeTLSiOSSDK/VeTLSiOSSDK.h>

#define CHECK_NEED_TEST(CASE_NAME) [[TestCases objectForKey:@CASE_NAME] isEqualToString:@"YES"]
#define DO_TEST(API_NAME)

int main(int argc, char * argv[]) {
    NSString * appDelegateClassName;
    @autoreleasepool {
        NSDictionary<NSString*, NSString*> *TestCases = @{
            @"DescribeProject": @"NO",
            @"DescribeProjects": @"NO",
            @"DeleteProject": @"NO",
            @"ModifyTopic": @"NO",
            @"DescribeTopic": @"NO",
            @"DeleteTopic": @"NO",
            @"DescribeTopics": @"NO",
            @"PutLogsV2": @"NO",
            @"DescribeIndex": @"NO",
            @"SearchLogs": @"NO",
            @"PutLogsV2Async": @"NO",
            @"PutLogsAsync": @"NO"
        };
        
        // Make client
        TLSClientConfig *config = [TLSClientConfig alloc]; {
            config.endpoint = @"XXX";
            config.region = @"XXX";
            config.accessKeyId = @"XXX";
            config.accessKeySecret = @"XXX";
        }
        TLSClient *client = [[TLSClient alloc] initWithConfig:config];
        
        // Project interfaces
        // CreateProject
        if (CHECK_NEED_TEST("CreateProject")) {
            CreateProjectRequest *request = [CreateProjectRequest alloc]; {
                request.description = @"my project";
                request.region = @"XXX";
                request.projectName = @"ios-sdk-test-project";
            }
            CreateProjectResponse *response = [client CreateProject:request];
            NSLog(@"Response: %@", [response toJSONString]);
        }
        // ModifyProject
        if (CHECK_NEED_TEST("ModifyProject")) {
            ModifyProjectRequest *request = [ModifyProjectRequest alloc]; {
                request.projectId = @"XXX";
                request.projectName = @"erentestmodify";
            }
            ModifyProjectResponse *response = [client ModifyProject:request];
            NSLog(@"Response: %@", [response toJSONString]);
        }
        // DescribeProjects
        if (CHECK_NEED_TEST("DescribeProjects")) {
            DescribeProjectsRequest *request = [DescribeProjectsRequest alloc]; {
                request.isFullName = false;
                request.projectName = @"testlabel1";
            }
            DescribeProjectsResponse *response = [client DescribeProjects:request];
            NSLog(@"Response: %@", [response toJSONString]);
        }
        // DescribeProject
        if (CHECK_NEED_TEST("DescribeProject")) {
            DescribeProjectRequest *request = [DescribeProjectRequest alloc]; {
                request.projectId = @"XXX";
            }
            NSLog(@"Response: %@", [[client DescribeProject:request] toJSONString]);
        }
        // DeleteProject
        if (CHECK_NEED_TEST("DeleteProject")) {
            DeleteProjectRequest *request = [DeleteProjectRequest alloc]; {
                request.projectId = @"XXX";
            }
            DeleteProjectResponse *response = [client DeleteProject:request];
            NSLog(@"Response: %@", [response toJSONString]);
        }
        
        // Topic interfaces
        // CreateTopic
        if (CHECK_NEED_TEST("CreateTopic")) {
            CreateTopicRequest *request = [CreateTopicRequest alloc]; {
                request.projectId = @"XXX";
                request.topicName = @"XXX";
                request.ttl = [[NSNumber alloc] initWithInt:1];
                request.shardCount = [[NSNumber alloc] initWithInt:1];
            }
            CreateTopicResponse *response = [client CreateTopic:request];
            NSLog(@"Response: %@", [response toJSONString]);
        }
        // ModifyTopic
        if (CHECK_NEED_TEST("ModifyTopic")) {
            ModifyTopicRequest *request = [ModifyTopicRequest alloc]; {
                request.topicId = @"XXX";
                request.topicName = @"XXX";
            }
            NSLog(@"Response: %@", [[client ModifyTopic:request] toJSONString]);
        }
        // DescribeTopic
        if (CHECK_NEED_TEST("DescribeTopic")) {
            DescribeTopicRequest *request = [DescribeTopicRequest alloc]; {
                request.topicId = @"XXX";
            }
            NSLog(@"Response: %@", [[client DescribeTopic:request] toJSONString]);
        }
        // DescribeTopics
        if (CHECK_NEED_TEST("DescribeTopics")) {
            DescribeTopicsRequest *request = [DescribeTopicsRequest alloc]; {
                request.projectId = @"XXX";
            }
            NSLog(@"Response: %@", [[client DescribeTopics:request] toJSONString]);
        }
        // DeleteTopic
        if (CHECK_NEED_TEST("DeleteTopic")) {
            DeleteTopicRequest *request = [DeleteTopicRequest alloc]; {
                request.topicId = @"XXX";
            }
            NSLog(@"Response: %@", [[client DeleteTopic:request] toJSONString]);
        }
        
        // Shard interfaces
        // DescribeShards
        if (CHECK_NEED_TEST("DescribeShards")) {
            DescribeShardsRequest *request = [DescribeShardsRequest alloc]; {
                request.topicId = @"XXX";
            }
            NSLog(@"Response: %@", [[client DescribeShards:request] toJSONString]);
        }
        
        // Index interfaces
        // CreateIndex
        if (CHECK_NEED_TEST("CreateIndex")) {
            CreateIndexRequest *request = [CreateIndexRequest alloc]; {
                request.topicId = @"XXX";
            }
            NSLog(@"Response: %@", [[client CreateIndex:request] toJSONString]);
        }
        // DescribeIndex
        if (CHECK_NEED_TEST("DescribeIndex")) {
            DescribeIndexRequest *request = [DescribeIndexRequest alloc]; {
                request.topicId = @"XXX";
            }
            NSLog(@"Response: %@", [[client DescribeIndex:request] toJSONString]);
        }
        // ModifyIndex
        if (CHECK_NEED_TEST("ModifyIndex")) {
            ModifyIndexRequest *request = [ModifyIndexRequest alloc]; {
                request.topicId = @"XXX";
            }
            NSLog(@"Response: %@", [[client ModifyIndex:request] toJSONString]);
        }
        // DeleteIndex
        if (CHECK_NEED_TEST("DeleteIndex")) {
            DeleteIndexRequest *request = [DeleteIndexRequest alloc]; {
                request.topicId = @"XXX";
            }
            NSLog(@"Response: %@", [[client DeleteIndex:request] toJSONString]);
        }
        
        // Log interfaces
        // PutLogs
        if (CHECK_NEED_TEST("PutLogs")) {
            LogContent *logContent = [[LogContent alloc] init]; {
                logContent.key = @"testKey";
                logContent.value = @"testValue";
            }
            Log *log = [[Log alloc] init]; {
                log.time = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
                [log.contentsArray addObject:logContent];
            }
            LogGroup * logGroup = [[LogGroup alloc] init]; {
                logGroup.source = @"ios-sdk-test";
                logGroup.fileName = @"ios-sdk-test";
                [logGroup.logsArray addObject:log];
            }
            PutLogsRequest *request = [[PutLogsRequest alloc] init]; {
                request.topicId = @"XXX"; // ios-sdk-test-topic
                request.logGroupList = [[LogGroupList alloc] init];
                [request.logGroupList.logGroupsArray addObject:logGroup];
            }
            NSLog(@"Response: %@", [[client PutLogs:request] toJSONString]);
        }
        // PutLogs request with lz4
        if (CHECK_NEED_TEST("PutLogsLz4")) {
            LogContent *logContent = [[LogContent alloc] init]; {
                logContent.key = @"testKey";
                logContent.value = @"testValueeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
            }
            Log *log = [[Log alloc] init]; {
                log.time = (int64_t)([[NSDate date] timeIntervalSince1970]);
                [log.contentsArray addObject:logContent];
            }
            LogGroup * logGroup = [[LogGroup alloc] init]; {
                logGroup.source = @"ios-sdk-test";
                logGroup.fileName = @"ios-sdk-test";
                [logGroup.logsArray addObject:log];
            }
            PutLogsRequest *request = [[PutLogsRequest alloc] init]; {
                request.compressType = @"lz4";
                request.topicId = @"XXX"; // ios-sdk-test-topic
                request.logGroupList = [[LogGroupList alloc] init];
                [request.logGroupList.logGroupsArray addObject:logGroup];
            }
            NSLog(@"Response: %@", [[client PutLogs:request] toJSONString]);
        }
        // PutLogsV2
        if (CHECK_NEED_TEST("PutLogsV2")) {
            PutLogsV2Request *request = [[PutLogsV2Request alloc] init]; {
                request.source = @"My source";
                request.fileName = @"My filename";
                request.topicId = @"XXX";
                request.logs = @[
                    [[PutLogsV2LogItem alloc] initWithKeyValueAndTime:@{@"TestKey": @"TestValue"} timeStamp:0]
                ];
            }
            NSLog(@"Response: %@", [[client PutLogsV2:request] toJSONString]);
        }
        // PutLogsAsync
        if (CHECK_NEED_TEST("PutLogsAsync")) {
            LogContent *logContent = [[LogContent alloc] init]; {
                logContent.key = @"testKey";
                logContent.value = @"testValue";
            }
            Log *log = [[Log alloc] init]; {
                // log.time = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000);
                [log.contentsArray addObject:logContent];
            }
            LogGroup * logGroup = [[LogGroup alloc] init]; {
                logGroup.source = @"ios-sdk-test";
                logGroup.fileName = @"ios-sdk-test";
                [logGroup.logsArray addObject:log];
            }
            PutLogsRequest *request = [[PutLogsRequest alloc] init]; {
                request.topicId = @"XXX"; // ios-sdk-test-topic
                request.logGroupList = [[LogGroupList alloc] init];
                [request.logGroupList.logGroupsArray addObject:logGroup];
            }
            VeTask* task = [client PutLogsAsync:request];
            [task continueWithBlock:^id _Nullable(VeTask * _Nonnull t) {
                if (t.error == nil) {
                    if (t.result != nil) {
                        GeneralHttpResponse* response = t.result;
                        NSLog(@"RequestId: %@, HttpStatus: %@, ResponseBody: %@", response.requestId, response.httpStatusCode, [[NSString alloc] initWithData:response.responseBody encoding:NSUTF8StringEncoding]);
                    }
                } else NSLog(@"Encountered error: %@", t.error);
                return nil;
            }];
        }
        // PutLogsV2Async
        if (CHECK_NEED_TEST("PutLogsV2Async")) {
            PutLogsV2Request *request = [[PutLogsV2Request alloc] init]; {
                request.source = @"My source";
                request.fileName = @"My filename";
                request.topicId = @"XXX";
                request.logs = @[
                    [[PutLogsV2LogItem alloc] initWithKeyValueAndTime:@{@"TestKey": @"TestValue"} timeStamp:0]
                ];
            }
            VeTask* task = [client PutLogsV2Async:request];
            [task continueWithBlock:^id _Nullable(VeTask * _Nonnull t) {
                if (t.error == nil) {
                    if (t.result != nil) {
                        GeneralHttpResponse* response = t.result;
                        NSLog(@"RequestId: %@, HttpStatus: %@, ResponseBody: %@", response.requestId, response.httpStatusCode, [[NSString alloc] initWithData:response.responseBody encoding:NSUTF8StringEncoding]);
                    }
                } else NSLog(@"Encountered error: %@", t.error);
                return nil;
            }];
        }
        // WebTracks
        if (CHECK_NEED_TEST("WebTracks")) {
            WebTracksRequest *request = [WebTracksRequest alloc]; {
                request.topicId = @"XXX";
                request.projectId = @"XXX";
                request.source = @"ios-sdk";
                // requst.logs =
                NSMutableArray<NSDictionary<NSString*, NSString*>*> *logs = [[NSMutableArray<NSDictionary<NSString*, NSString*>*> alloc] init];
                NSMutableDictionary *testLog = [[NSMutableDictionary<NSString*, NSString*> alloc] init];
                testLog[@"testKey"] = @"testWebtackkk";
                [logs addObject:testLog];
                request.logs = logs;
            }
            NSLog(@"Response: %@", [[client WebTracks:request] toJSONString]);
        }
        // WebTracks using lz4
        if (CHECK_NEED_TEST("WebTracksLz4")) {
            WebTracksRequest *request = [WebTracksRequest alloc]; {
                request.topicId = @"XXX";
                request.projectId = @"XXX";
                request.source = @"ios-sdk";
                request.compressType = @"lz4";
                // requst.logs =
                NSMutableArray<NSDictionary<NSString*, NSString*>*> *logs = [[NSMutableArray<NSDictionary<NSString*, NSString*>*> alloc] init];
                NSMutableDictionary *testLog = [[NSMutableDictionary<NSString*, NSString*> alloc] init];
                testLog[@"testKey"] = @"testWebtackkk";
                [logs addObject:testLog];
                request.logs = logs;
            }
            NSLog(@"Response: %@", [[client WebTracks:request] toJSONString]);
        }
        // SearchLogs
        if (CHECK_NEED_TEST("SearchLogs")) {
            SearchLogsRequest *request = [SearchLogsRequest alloc]; {
                request.topicId = @"XXX";
                request.query = @"cpptestvalue";
                request.startTime = [[NSNumber alloc] initWithLong:1678080000];
                request.endTime = [[NSNumber alloc] initWithLong:1678085187];
                request.limit = [[NSNumber alloc] initWithLong:30];
            }
            NSLog(@"Response: %@", [[client SearchLogs:request] toJSONString]);
        }
        
        // Hostgroup interfaces
        NSString *hostGroupId = @"";
        // CreateHostGroup
        if (CHECK_NEED_TEST("CreateHostGroup")) {
            CreateHostGroupRequest *request = [CreateHostGroupRequest alloc]; {
                request.hostGroupName = @"erentestname";
                request.hostGroupType = @"Label";
                request.hostIdentifier = @"erenhostgroup";
            }
            CreateHostGroupResponse *response = [client CreateHostGroup:request];
            hostGroupId = response.hostGroupId;
            NSLog(@"Response: %@", [response toJSONString]);
        }
        // ModifyHostGroup
        if (CHECK_NEED_TEST("ModifyHostGroup")) {
            ModifyHostGroupRequest *request = [ModifyHostGroupRequest alloc]; {
                request.hostGroupId = hostGroupId;
            }
            NSLog(@"Response: %@", [[client ModifyHostGroup:request] toJSONString]);
        }
        // DescribeHostGroup
        if (CHECK_NEED_TEST("DescribeHostGroup")) {
            DescribeHostGroupRequest *request = [DescribeHostGroupRequest alloc]; {
                request.hostGroupId = @"";
            }
            NSLog(@"Response: %@", [[client DescribeHostGroup:request] toJSONString]);
        }
        // DescribeHostGroups
        if (CHECK_NEED_TEST("DescribeHostGroups")) {
            DescribeHostGroupsRequest *request = [DescribeHostGroupsRequest alloc]; {
                // Pass
            }
            NSLog(@"Response: %@", [[client DescribeHostGroups:request] toJSONString]);
        }
        // DeleteHostGroup
        if (CHECK_NEED_TEST("DeleteHostGroup")) {
            DeleteHostGroupRequest *request = [DeleteHostGroupRequest alloc]; {
                request.hostGroupId = @"";
            }
            NSLog(@"Response: %@", [[client DeleteHostGroup:request] toJSONString]);
        }
        // DescribeHosts
        if (CHECK_NEED_TEST("DescribeHosts")) {
            DescribeHostsRequest *request = [DescribeHostsRequest alloc]; {
                request.hostGroupId = @"";
            }
            NSLog(@"Response: %@", [[client DescribeHosts:request] toJSONString]);
        }
        
        // Rule interfaces
        // CreateRule
        if (CHECK_NEED_TEST("CreateRule")) {
            CreateRuleRequest *request = [CreateRuleRequest alloc]; {
                request.topicId = @"XXX";
                request.ruleName = @"erentestrule";
            }
            NSLog(@"Response: %@", [[client CreateRule:request] toJSONString]);
        }
        // DescribeRule
        if (CHECK_NEED_TEST("DescribeRule")) {
            DescribeRuleRequest *request = [DescribeRuleRequest alloc]; {
                request.ruleId = @"";
            }
            NSLog(@"Response: %@", [[client DescribeRule:request] toJSONString]);
        }
        // DescribeRule
        if (CHECK_NEED_TEST("DescribeRules")) {
            DescribeRulesRequest *request = [DescribeRulesRequest alloc]; {
                request.topicId = @"XXX";
            }
            NSLog(@"Response: %@", [[client DescribeRules:request] toJSONString]);
        }
        
        // Alarm interfaces
        // CreateAlarm
        if (CHECK_NEED_TEST("CreateAlarm")) {
            CreateAlarmRequest *request = [CreateAlarmRequest alloc]; {
                request.projectId = @"XXX";
                request.alarmName = @"erentestalarm";
            }
            NSLog(@"Response: %@", [[client CreateAlarm:request] toJSONString]);
        }
        // DescribeAlarm
        if (CHECK_NEED_TEST("DescribeAlarm")) {
            DescribeAlarmsRequest *request = [DescribeAlarmsRequest alloc]; {
                // Pass
            }
            NSLog(@"Response: %@", [client DescribeAlarms:request]);
        }
        // ModifyAlarm
        if (CHECK_NEED_TEST("ModifyAlarm")) {
            ModifyAlarmRequest *request = [ModifyAlarmRequest alloc]; {
                request.alarmId = @"";
            }
            NSLog(@"Response: %@", [client ModifyAlarm:request]);
        }
        // DeleteAlarm
        if (CHECK_NEED_TEST("DeleteAlarm")) {
            DeleteAlarmRequest *request = [DeleteAlarmRequest alloc]; {
                request.alarmId = @"";
            }
            NSLog(@"Response: %@", [client DeleteAlarm:request]);
        }
        
        // Kafka protocol interfaces
        // OpenKafkaConsumer
        if (CHECK_NEED_TEST("OpenKafkaConsumer")) {
            OpenKafkaConsumerRequest *request = [OpenKafkaConsumerRequest alloc]; {
                request.topicId = @"";
            }
            NSLog(@"Response: %@", [client OpenKafkaConsumer:request]);
        }
        // DescribeKafkaConsumer
        if (CHECK_NEED_TEST("DescribeKafkaConsumer")) {
            DescribeKafkaConsumerRequest *request = [DescribeKafkaConsumerRequest alloc]; {
                request.topicId = @"";
            }
            NSLog(@"Response: %@", [client DescribeKafkaConsumer:request]);
        }
        // CloseKafkaConsumer
        if (CHECK_NEED_TEST("CloseKafkaConsumer")) {
            CloseKafkaConsumerRequest *request = [CloseKafkaConsumerRequest alloc]; {
                request.topicId = @"";
            }
            NSLog(@"Response: %@", [client CloseKafkaConsumer:request]);
        }
        
        // Setup code that might create autoreleased objects goes here.
        appDelegateClassName = NSStringFromClass([AppDelegate class]);
    }
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
