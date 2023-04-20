//
//  NSDate+Ve.m
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/11.
//

#import "NSDate+Ve.h"

NSString *const VeDateRFC822DateFormat1 = @"EEE, dd MMM yyyy HH:mm:ss z";
NSString *const VeDateISO8601DateFormat1 = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
NSString *const VeDateISO8601DateFormat2 = @"yyyyMMdd'T'HHmmss'Z'";
NSString *const VeDateISO8601DateFormat3 = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
NSString *const VeDateShortDateFormat1 = @"yyyyMMdd";
NSString *const VeDateShortDateFormat2 = @"yyyy-MM-dd";


@implementation NSDate (Ve)

static NSTimeInterval _clockskew = 0.0;

+ (NSDate *)ve_clockSkewFixedDate {
    return [[NSDate date] dateByAddingTimeInterval:-1 * _clockskew];
}

+ (NSDate *)ve_dateFromString:(NSString *)string {
    NSDate *parsedDate = nil;
    NSArray *arrayOfDateFormat = @[VeDateRFC822DateFormat1,
                                   VeDateISO8601DateFormat1,
                                   VeDateISO8601DateFormat2,
                                   VeDateISO8601DateFormat3];

    for (NSString *dateFormat in arrayOfDateFormat) {
        if (!parsedDate) {
            parsedDate = [NSDate ve_dateFromString:string format:dateFormat];
        } else {
            break;
        }
    }

    return parsedDate;
}

+ (NSDate *)ve_dateFromString:(NSString *)string format:(NSString *)dateFormat {
    if ([dateFormat isEqualToString:VeDateRFC822DateFormat1]) {
        return [[NSDate ve_RFC822Date1Formatter] dateFromString:string];
    }
    if ([dateFormat isEqualToString:VeDateISO8601DateFormat1]) {
        return [[NSDate ve_ISO8601Date1Formatter] dateFromString:string];
    }
    if ([dateFormat isEqualToString:VeDateISO8601DateFormat2]) {
        return [[NSDate ve_ISO8601Date2Formatter] dateFromString:string];
    }
    if ([dateFormat isEqualToString:VeDateISO8601DateFormat3]) {
        return [[NSDate ve_ISO8601Date3Formatter] dateFromString:string];
    }
    if ([dateFormat isEqualToString:VeDateShortDateFormat1]) {
        return [[NSDate ve_ShortDateFormat1Formatter] dateFromString:string];
    }
    if ([dateFormat isEqualToString:VeDateShortDateFormat2]) {
        return [[NSDate ve_ShortDateFormat2Formatter] dateFromString:string];
    }

    NSDateFormatter *dateFormatter = [NSDateFormatter new];
    dateFormatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
    dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dateFormatter.dateFormat = dateFormat;

    return [dateFormatter dateFromString:string];
}

- (NSString *)ve_stringValue:(NSString *)dateFormat {
    if ([dateFormat isEqualToString:VeDateRFC822DateFormat1]) {
        return [[NSDate ve_RFC822Date1Formatter] stringFromDate:self];
    }
    if ([dateFormat isEqualToString:VeDateISO8601DateFormat1]) {
        return [[NSDate ve_ISO8601Date1Formatter] stringFromDate:self];
    }
    if ([dateFormat isEqualToString:VeDateISO8601DateFormat2]) {
        return [[NSDate ve_ISO8601Date2Formatter] stringFromDate:self];
    }
    if ([dateFormat isEqualToString:VeDateISO8601DateFormat3]) {
        return [[NSDate ve_ISO8601Date3Formatter] stringFromDate:self];
    }
    if ([dateFormat isEqualToString:VeDateShortDateFormat1]) {
        return [[NSDate ve_ShortDateFormat1Formatter] stringFromDate:self];
    }
    if ([dateFormat isEqualToString:VeDateShortDateFormat2]) {
        return [[NSDate ve_ShortDateFormat2Formatter] stringFromDate:self];
    }

    NSDateFormatter *dateFormatter = [NSDateFormatter new];
    dateFormatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
    dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dateFormatter.dateFormat = dateFormat;

    return [dateFormatter stringFromDate:self];
}

+ (NSDateFormatter *)ve_RFC822Date1Formatter {
    static NSDateFormatter *_dateFormatter = nil;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _dateFormatter = [NSDateFormatter new];
        _dateFormatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
        _dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _dateFormatter.dateFormat = VeDateRFC822DateFormat1;
    });

    return _dateFormatter;
}

+ (NSDateFormatter *)ve_ISO8601Date1Formatter {
    static NSDateFormatter *_dateFormatter = nil;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _dateFormatter = [NSDateFormatter new];
        _dateFormatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
        _dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _dateFormatter.dateFormat = VeDateISO8601DateFormat1;
    });

    return _dateFormatter;
}

+ (NSDateFormatter *)ve_ISO8601Date2Formatter {
    static NSDateFormatter *_dateFormatter = nil;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _dateFormatter = [NSDateFormatter new];
        _dateFormatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
        _dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _dateFormatter.dateFormat = VeDateISO8601DateFormat2;
    });

    return _dateFormatter;
}

+ (NSDateFormatter *)ve_ISO8601Date3Formatter {
    static NSDateFormatter *_dateFormatter = nil;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _dateFormatter = [NSDateFormatter new];
        _dateFormatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
        _dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _dateFormatter.dateFormat = VeDateISO8601DateFormat3;
    });

    return _dateFormatter;
}

+ (NSDateFormatter *)ve_ShortDateFormat1Formatter {
    static NSDateFormatter *_dateFormatter = nil;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _dateFormatter = [NSDateFormatter new];
        _dateFormatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
        _dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _dateFormatter.dateFormat = VeDateShortDateFormat1;
    });

    return _dateFormatter;
}

+ (NSDateFormatter *)ve_ShortDateFormat2Formatter {
    static NSDateFormatter *_dateFormatter = nil;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _dateFormatter = [NSDateFormatter new];
        _dateFormatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
        _dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _dateFormatter.dateFormat = VeDateShortDateFormat2;
    });

    return _dateFormatter;
}

+ (void)ve_setRuntimeClockSkew:(NSTimeInterval)clockskew {
    @synchronized(self) {
        _clockskew = clockskew;
    }
}

+ (NSTimeInterval)ve_getRuntimeClockSkew {
    @synchronized(self) {
        return _clockskew;
    }
}


@end
