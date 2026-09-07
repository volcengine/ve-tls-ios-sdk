//
// EntryBenchmarkRunner.h
// Shared scheduler, measurement boundary, and JSON artifact writer.
//

#import <Foundation/Foundation.h>
#import "EntryBenchmarkEntry.h"
#import "EntryBenchmarkOptions.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^EBBenchmarkCompletion)(NSURL * _Nullable artifactURL,
                                      NSError * _Nullable error);

@interface EBBenchmarkRunner : NSObject

- (instancetype)initWithOptions:(EBBenchmarkOptions *)options
                         payload:(EBBenchmarkPayload *)payload
                           entry:(id<EBBenchmarkEntry>)entry
                      completion:(EBBenchmarkCompletion)completion;

- (void)start;

@end

NS_ASSUME_NONNULL_END
