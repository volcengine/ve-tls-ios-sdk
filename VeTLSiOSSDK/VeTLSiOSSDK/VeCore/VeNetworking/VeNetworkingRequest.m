//
//  VeNetworkingRequest.m
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/12.
//

#import "VeNetworkingRequest.h"

@implementation GeneralHttpResponse
@end

@implementation VeNetworkingRequest

- (void)setTask:(NSURLSessionTask *)task {
    @synchronized(self) {
        if (!_cancelled) {
            _task = task;
        } else {
            _task = nil;
        }
    }
}

- (BOOL)isCancelled {
    @synchronized(self) {
        return _cancelled;
    }
}

- (void)cancel {
    @synchronized(self) {
        if (!_cancelled) {
            _cancelled = YES;
            [self.task cancel];
        }
    }
}

- (void)pause {
    @synchronized(self) {
        [self.task cancel];
    }
}

@end
