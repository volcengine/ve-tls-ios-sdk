//
// EntryBenchmarkProtocol.h
// Per-session offline URLProtocol.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns HTTP 200 immediately and never reads or stores the request body.
/// Only a bounded request count is retained for the final artifact.
@interface EBImmediateURLProtocol : NSURLProtocol

+ (void)reset;
+ (NSUInteger)requestCount;

@end

NS_ASSUME_NONNULL_END
