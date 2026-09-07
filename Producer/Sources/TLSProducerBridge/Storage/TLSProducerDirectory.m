// TLSProducerDirectory.m
// TLSProducerBridge/Storage
//

#import "TLSProducerDirectory.h"

#import <TargetConditionals.h>

NSErrorDomain const TLSProducerDirectoryErrorDomain =
    @"com.volcengine.tls.producer.directory";

const NSUInteger TLSProducerDirectoryMaxProducerIDUTF8Length = 64;

static NSString *const kTLSProducerIDAllowedCharacters =
    @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-";

static NSString *const kTLSProducerRootDirectoryName = @"com.volcengine.tls";
static NSString *const kTLSProducerSubdirectoryName = @"producer";

@interface TLSProducerDirectory ()

+ (NSError *)tls_errorWithCode:(TLSProducerDirectoryErrorCode)code
                   description:(NSString *)description;
+ (NSError *)tls_errorWithCode:(TLSProducerDirectoryErrorCode)code
                   description:(NSString *)description
               underlyingError:(nullable NSError *)underlyingError;

@end

@implementation TLSProducerDirectory

+ (BOOL)validateProducerID:(NSString *)producerID
                     error:(NSError * _Nullable * _Nullable)error {
    // Defensive nil handling even though the header marks the parameter
    // nonnull (Swift imports it as non-optional; ObjC callers may still
    // pass nil under ARC with suppressed diagnostics).
    if (producerID == nil || producerID.length == 0) {
        if (error != NULL) {
            *error = [self tls_errorWithCode:TLSProducerDirectoryErrorCodeInvalidProducerID
                                 description:@"producerID must not be empty."];
        }
        return NO;
    }

    // "." and ".." are valid per the character set but are special path
    // components: URLByAppendingPathComponent:@".." resolves to the parent
    // directory, which would escape the producer root. Reject them.
    if ([producerID isEqualToString:@"."] || [producerID isEqualToString:@".."]) {
        if (error != NULL) {
            *error = [self tls_errorWithCode:TLSProducerDirectoryErrorCodeInvalidProducerID
                                 description:@"producerID must not be \".\" or \"..\"."];
        }
        return NO;
    }

    // Explicit ASCII-only allowed set. NSCharacterSet.alphanumericCharacterSet
    // includes Unicode letters (e.g. "é", "中"), which the public contract
    // forbids, so the set is built from the literal ASCII characters.
    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:kTLSProducerIDAllowedCharacters];
    NSRange badRange = [producerID rangeOfCharacterFromSet:allowed.invertedSet];
    if (badRange.location != NSNotFound) {
        if (error != NULL) {
            *error = [self tls_errorWithCode:TLSProducerDirectoryErrorCodeInvalidProducerID
                                 description:@"producerID may only contain [A-Za-z0-9._-]."];
        }
        return NO;
    }

    // Length is measured in UTF-8 bytes: a multibyte character counts as its
    // encoded byte length, not as one UTF-16 code unit.
    NSUInteger utf8Length = [producerID dataUsingEncoding:NSUTF8StringEncoding].length;
    if (utf8Length > TLSProducerDirectoryMaxProducerIDUTF8Length) {
        if (error != NULL) {
            *error = [self tls_errorWithCode:TLSProducerDirectoryErrorCodeInvalidProducerID
                                 description:@"producerID must be at most 64 UTF-8 bytes."];
        }
        return NO;
    }

    return YES;
}

+ (nullable NSURL *)defaultDirectoryURLForProducerID:(NSString *)producerID
                                               error:(NSError * _Nullable * _Nullable)error {
    if (![self validateProducerID:producerID error:error]) {
        return nil;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *appSupport = [fm URLForDirectory:NSApplicationSupportDirectory
                                   inDomain:NSUserDomainMask
                          appropriateForURL:nil
                                     create:NO
                                      error:error];
    if (appSupport == nil) {
        return nil;
    }

    // The directory is not created here; createDirectoryAtURL:error: owns
    // creation + attribute application.
    return [[[appSupport URLByAppendingPathComponent:kTLSProducerRootDirectoryName
                                         isDirectory:YES]
             URLByAppendingPathComponent:kTLSProducerSubdirectoryName
                             isDirectory:YES]
            URLByAppendingPathComponent:producerID
                            isDirectory:YES];
}

+ (nullable NSURL *)createDirectoryAtURL:(NSURL *)url
                                   error:(NSError * _Nullable * _Nullable)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSError *createError = nil;
    if (![fm createDirectoryAtURL:url
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&createError]) {
        if (error != NULL) {
            *error = [self tls_errorWithCode:TLSProducerDirectoryErrorCodeDirectoryCreationFailed
                                 description:@"Failed to create the producer directory."
                             underlyingError:createError];
        }
        return nil;
    }

    // 1) Exclude from iCloud/iTunes backup. NSURLIsExcludedFromBackupKey is a
    //    URL resource property (set via NSURL resource values).
    NSError *excludeError = nil;
    if (![url setResourceValue:@YES
                         forKey:NSURLIsExcludedFromBackupKey
                          error:&excludeError]) {
        if (error != NULL) {
            *error = [self tls_errorWithCode:TLSProducerDirectoryErrorCodeAttributeSetFailed
                                 description:@"Failed to set NSURLIsExcludedFromBackupKey."
                             underlyingError:excludeError];
        }
        return nil;
    }

    // 2) Data Protection. NSFileProtectionKey is an NSFileManager attribute
    //    (set via setAttributes:ofItemAtPath:), not a URL resource key.
    //    Data Protection is iOS-only: NSFileProtectionKey and
    //    NSFileProtectionCompleteUntilFirstUserAuthentication are absent from
    //    the macOS SDK, so macOS host builds (swift build/test on macOS) skip
    //    this attribute. The mandatory re-read verification below is guarded
    //    identically. On iOS (device/simulator/Mac Catalyst) the attribute is
    //    always set and verified.
#if TARGET_OS_IOS
    NSError *protectionError = nil;
    if (![fm setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
              ofItemAtPath:url.path
                     error:&protectionError]) {
        if (error != NULL) {
            *error = [self tls_errorWithCode:TLSProducerDirectoryErrorCodeAttributeSetFailed
                                 description:@"Failed to set NSFileProtectionKey."
                             underlyingError:protectionError];
        }
        return nil;
    }
#endif // TARGET_OS_IOS

    // 3) Re-read and verify. A set without a verified read is not trusted:
    //    the directory is only considered ready when both attributes read
    //    back with the exact required values.
    NSNumber *excludedFromBackup = nil;
    NSError *excludeReadError = nil;
    if (![url getResourceValue:&excludedFromBackup
                         forKey:NSURLIsExcludedFromBackupKey
                          error:&excludeReadError]) {
        if (error != NULL) {
            *error = [self tls_errorWithCode:TLSProducerDirectoryErrorCodeAttributeVerificationFailed
                                 description:@"Failed to re-read NSURLIsExcludedFromBackupKey."
                             underlyingError:excludeReadError];
        }
        return nil;
    }
    if (!excludedFromBackup.boolValue) {
        if (error != NULL) {
            *error = [self tls_errorWithCode:TLSProducerDirectoryErrorCodeAttributeVerificationFailed
                                 description:@"NSURLIsExcludedFromBackupKey did not read back as YES."];
        }
        return nil;
    }

    // Data Protection re-read verification — iOS-only, matching the guarded
    // set above. Skipped on macOS host builds (no Data Protection on macOS).
#if TARGET_OS_IOS
    NSError *attributesReadError = nil;
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [fm attributesOfItemAtPath:url.path error:&attributesReadError];
    if (attributes == nil) {
        if (error != NULL) {
            *error = [self tls_errorWithCode:TLSProducerDirectoryErrorCodeAttributeVerificationFailed
                                 description:@"Failed to re-read directory attributes."
                             underlyingError:attributesReadError];
        }
        return nil;
    }
    id protection = attributes[NSFileProtectionKey];
    if (protection != nil &&
        ![protection isEqual:NSFileProtectionCompleteUntilFirstUserAuthentication]) {
        // A non-nil mismatch is a real failure (wrong value on a supporting
        // platform). nil means the platform does not expose Data Protection
        // (e.g. iOS Simulator) — the set above was best-effort and the
        // attribute is simply not reported, so this is not a failure.
        if (error != NULL) {
            *error = [self tls_errorWithCode:TLSProducerDirectoryErrorCodeAttributeVerificationFailed
                                 description:@"NSFileProtectionKey did not read back as CompleteUntilFirstUserAuthentication."];
        }
        return nil;
    }
#endif // TARGET_OS_IOS

    return url;
}

+ (BOOL)isURL:(NSURL *)url insideContainerBaseURL:(nullable NSURL *)baseURL {
    if (!url.isFileURL) {
        return NO;
    }

    NSURL *container = baseURL;
    if (container == nil) {
        container = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
    }

    // Standardize (".", "..", "~") and resolve symlinks on BOTH sides. On
    // iOS the home directory sits under /var -> /private/var, so resolving
    // only one side would break the prefix comparison. Resolving both also
    // rejects symlinked candidates that point outside the container.
    // The tolerant resolver handles non-existent tails (test containers may
    // not be created on disk) so both sides resolve identically.
    NSURL *standardizedURL =
        [self tls_URLByResolvingSymlinksAllowingNonexistentTail:url];
    NSURL *standardizedContainer =
        [self tls_URLByResolvingSymlinksAllowingNonexistentTail:container];

    NSString *candidatePath = standardizedURL.path;
    NSString *containerPath = standardizedContainer.path;
    if (candidatePath.length == 0 || containerPath.length == 0) {
        return NO;
    }

    if (![candidatePath hasPrefix:containerPath]) {
        return NO;
    }
    if (candidatePath.length == containerPath.length) {
        return YES; // exactly the container root
    }
    // Path-component boundary: "abc-evil" must not pass for container "abc".
    unichar next = [candidatePath characterAtIndex:containerPath.length];
    return next == '/';
}

#pragma mark - Private

/// Resolves symlinks in `url`, tolerating a non-existent tail.
///
/// `URLByResolvingSymlinksInPath` (backed by realpath(3)) only resolves
/// symlinks when the FULL path exists. A path like `container/link-to-outside/data`
/// (where `data` does not exist) would be returned unresolved, defeating the
/// container-escape check. This helper resolves the longest existing prefix
/// and re-appends the non-existent tail, so a mid-path symlink that escapes
/// the container is still detected.
+ (NSURL *)tls_URLByResolvingSymlinksAllowingNonexistentTail:(NSURL *)url {
    NSURL *standardized = [url URLByStandardizingPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:standardized.path]) {
        return [standardized URLByResolvingSymlinksInPath];
    }
    // Walk up until an existing path component is found, resolve it, then
    // re-append the non-existent tail in order.
    NSMutableArray<NSString *> *tail = [NSMutableArray array];
    NSURL *current = standardized;
    while (current.path.length > 1) {
        NSURL *parent = [current URLByDeletingLastPathComponent];
        // Always record the current component before checking the parent:
        // when the parent exists, the current component is still part of
        // the non-existent tail and must be re-appended after resolution.
        [tail addObject:[current lastPathComponent]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:parent.path]) {
            NSURL *resolvedParent =
                [[parent URLByStandardizingPath] URLByResolvingSymlinksInPath];
            NSURL *result = resolvedParent;
            for (NSString *component in tail.reverseObjectEnumerator) {
                result = [result URLByAppendingPathComponent:component isDirectory:YES];
            }
            return result;
        }
        current = parent;
    }
    // No existing prefix found; return the standardized path as-is.
    return standardized;
}

+ (NSError *)tls_errorWithCode:(TLSProducerDirectoryErrorCode)code
                   description:(NSString *)description {
    return [self tls_errorWithCode:code description:description underlyingError:nil];
}

+ (NSError *)tls_errorWithCode:(TLSProducerDirectoryErrorCode)code
                   description:(NSString *)description
               underlyingError:(nullable NSError *)underlyingError {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = description;
    if (underlyingError != nil) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:TLSProducerDirectoryErrorDomain
                               code:code
                           userInfo:userInfo];
}

@end
