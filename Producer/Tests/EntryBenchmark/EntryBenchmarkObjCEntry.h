//
// EntryBenchmarkObjCEntry.h
//

#import "EntryBenchmarkEntry.h"
#import "EntryBenchmarkOptions.h"

NS_ASSUME_NONNULL_BEGIN

@interface EBObjCEntry : NSObject <EBBenchmarkEntry>

@property(nonatomic, copy, nullable) EBTerminalResultHandler terminalResultHandler;

- (instancetype)initWithPayload:(EBBenchmarkPayload *)payload
                         options:(EBBenchmarkOptions *)options;

@end

NS_ASSUME_NONNULL_END
