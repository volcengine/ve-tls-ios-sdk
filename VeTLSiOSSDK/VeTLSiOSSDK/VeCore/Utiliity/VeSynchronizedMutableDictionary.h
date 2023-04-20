//
//  VeSynchronizedMutableDictionary.h
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/11.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VeSynchronizedMutableDictionary<KeyType, ObjectType> : NSObject

@property (readonly, copy) NSArray<KeyType> *allKeys;
@property (readonly, copy) NSArray<ObjectType> *allValues;
@property (readonly, nonatomic, strong) NSUUID *instanceKey;

/// Create new instance.
- (instancetype)init;

/// Creates another dictionary which syncs on the same queue.
- (instancetype)syncedDictionary;

- (id)objectForKey:(id)aKey;
- (void)setObject:(id)anObject forKey:(id <NSCopying>)aKey;

- (void)removeObject:(id)object;
- (void)removeObjectForKey:(id)aKey;
- (void)removeAllObjects;

- (void)mutateWithBlock:(void (^)(NSMutableDictionary *))block;
+ (void)mutateSyncedDictionaries:(NSArray<VeSynchronizedMutableDictionary *> *)dictionaries
                       withBlock:(void (^)(NSUUID *, NSMutableDictionary *))block;

- (BOOL)isEqualToAWSSynchronizedMutableDictionary:(VeSynchronizedMutableDictionary *)other;

@end

NS_ASSUME_NONNULL_END
