//
//  NSDate+Ve.h
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/11.
//

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const VeDateRFC822DateFormat1;
FOUNDATION_EXPORT NSString *const VeDateISO8601DateFormat1;
FOUNDATION_EXPORT NSString *const VeDateISO8601DateFormat2;
FOUNDATION_EXPORT NSString *const VeDateISO8601DateFormat3;
FOUNDATION_EXPORT NSString *const VeDateShortDateFormat1;
FOUNDATION_EXPORT NSString *const VeDateShortDateFormat2;

NS_ASSUME_NONNULL_BEGIN

@interface NSDate (Ve)

+ (NSDate *)ve_clockSkewFixedDate;

+ (NSDate *)ve_dateFromString:(NSString *)string;
+ (NSDate *)ve_dateFromString:(NSString *)string format:(NSString *)dateFormat;
- (NSString *)ve_stringValue:(NSString *)dateFormat;

/**
 * Set the clock skew for the current device.  This clock skew will be used for calculating
 * signatures to Ve signatures and for parsing/converting date values from responses.
 *
 * @param clockskew the skew (in seconds) for this device.  If the clock on the device is fast, pass positive skew to correct.  If the clock on the device is slow, pass negative skew to correct.
 */
+ (void)ve_setRuntimeClockSkew:(NSTimeInterval)clockskew;

/**
 * Get the clock skew for the current device.
 *
 * @return the skew (in seconds) currently set for this device.  Positive clock skew implies the device is fast, negative implies the device is slow.
 */
+ (NSTimeInterval)ve_getRuntimeClockSkew;

@end

NS_ASSUME_NONNULL_END
