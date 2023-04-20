//
//  VeSynchronizedMutableDictionary.m
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/11.
//

#import "VeSynchronizedMutableDictionary.h"

@interface VeSynchronizedMutableDictionary()

@property (nonatomic, strong) NSMutableDictionary *dictionary;
@property (nonatomic, strong) dispatch_queue_t dispatchQueue;
@property (nonatomic, strong) NSUUID *syncKey;
@property (readwrite, nonatomic, strong) NSUUID *instanceKey;

@end

@implementation VeSynchronizedMutableDictionary

- (instancetype)init {
    dispatch_queue_t queue = dispatch_queue_create("com.volcengine.console.atomic.dictionary", DISPATCH_QUEUE_CONCURRENT);
    NSUUID *syncKey = [NSUUID new];
    self = [self initWithDictionary:@{}.mutableCopy queue:queue syncKey:syncKey];
    return self;
}

- (instancetype)initWithDictionary:(NSMutableDictionary *)dictionary queue:(dispatch_queue_t)queue syncKey:(NSUUID *)syncKey {
    self = [super init];
    if (self) {
        self.dictionary = dictionary;
        self.dispatchQueue = queue;
        self.syncKey = syncKey;
        self.instanceKey = [NSUUID new];
    }
    return self;
}

- (instancetype)syncedDictionary {
    VeSynchronizedMutableDictionary *result = [[VeSynchronizedMutableDictionary alloc] initWithDictionary:@{}.mutableCopy queue:self.dispatchQueue syncKey:self.syncKey];
    return result;
}

- (NSArray *)allKeys {
    __block NSArray * result;
    dispatch_sync(self.dispatchQueue, ^{
        result = self.dictionary.allKeys;
    });
    return result;
}

- (NSArray *)allValues {
    __block NSArray * result;
    dispatch_sync(self.dispatchQueue, ^{
        result = self.dictionary.allValues;
    });
    return result;
}

- (id)objectForKey:(id)aKey {
    __block id result;
    dispatch_sync(self.dispatchQueue, ^{
        result = [self.dictionary objectForKey:aKey];
    });
    return result;
}

- (void)setObject:(id)anObject forKey:(id)aKey {
    dispatch_barrier_sync(self.dispatchQueue, ^{
        [self.dictionary setObject:anObject forKey:aKey];
    });
}

- (void)removeObject:(id)object {
    dispatch_barrier_sync(self.dispatchQueue, ^{
        for (NSString *key in self.dictionary) {
            if (object == self.dictionary[key]) {
                [self.dictionary removeObjectForKey:key];
                break;
            }
        }
    });
}

- (void)removeObjectForKey:(id)aKey {
    dispatch_barrier_sync(self.dispatchQueue, ^{
        [self.dictionary removeObjectForKey:aKey];
    });
}

- (void)removeAllObjects {
    dispatch_barrier_sync(self.dispatchQueue, ^{
        [self.dictionary removeAllObjects];
    });
}

- (void)mutateWithBlock:(void (^)(NSMutableDictionary *))block {
    dispatch_barrier_sync(self.dispatchQueue, ^{
        block(self.dictionary);
    });
}

+ (void)mutateSyncedDictionaries:(NSArray<VeSynchronizedMutableDictionary *> *)dictionaries withBlock:(void (^)(NSUUID *, NSMutableDictionary *))block {
    VeSynchronizedMutableDictionary *first = [dictionaries firstObject];
    if (!first) { return; }

    dispatch_barrier_sync(first.dispatchQueue, ^{
        [dictionaries enumerateObjectsUsingBlock:^(VeSynchronizedMutableDictionary * _Nonnull atomicDictionary, NSUInteger index, BOOL * _Nonnull stop) {
            NSCAssert([first.syncKey isEqual:atomicDictionary.syncKey], @"Sync keys much match");
            block(atomicDictionary.instanceKey, atomicDictionary.dictionary);
        }];
    });
}

- (BOOL)isEqual:(id)object {
    return self == object;
}

- (BOOL)isEqualToVeSynchronizedMutableDictionary:(VeSynchronizedMutableDictionary *)other {
    return [self.instanceKey isEqual:other.instanceKey] &&
        [self.dictionary isEqualToDictionary:other.dictionary];
}


@end
