// TLSProducerDirectory.h
// TLSProducerBridge/Storage
//
// App-sandbox storage helper for the TLS Producer SDK.
//
// Responsibilities:
//   - Validate the stable `producerID` used to identify the on-disk directory.
//   - Compute the default sandbox directory URL:
//       ~/Library/Application Support/com.volcengine.tls/producer/<producerID>/
//   - Create the directory and set + RE-VERIFY the two mandatory attributes:
//       * NSURLIsExcludedFromBackupKey = YES (no iCloud/iTunes backup)
//       * NSFileProtectionKey = NSFileProtectionCompleteUntilFirstUserAuthentication
//   - Validate that a caller-supplied custom directory stays inside the App
//     container (home-directory prefix check, injectable base for testing).
//
// Boundaries:
//   - This layer NEVER touches credentials. Credentials must never be written
//     into directory names, extended attributes, WAL/manifest file names or
//     contents. This helper does not accept
//     credential material in any parameter and stores nothing but the
//     producerID-derived path and filesystem attributes above.
//   - The two attributes are set on the DIRECTORY only. They are not inherited
//     by children; the Core/platform adapter must re-verify them on every WAL/
//     checkpoint/manifest create, rotate, rename and recover.
//     The Real Core platform file-open wrapper performs that per-file work;
//     it is intentionally outside this stateless directory helper.
//   - This helper does NOT implement WAL / recover / checkpoint / lease.
//     Those remain Core/adapter responsibilities; do not fake recovery here.
//
// Pure Objective-C; iOS 13.0+ safe APIs only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for TLSProducerDirectory failures.
FOUNDATION_EXPORT NSErrorDomain const TLSProducerDirectoryErrorDomain;

/// Error codes for TLSProducerDirectoryErrorDomain.
typedef NS_ENUM(NSInteger, TLSProducerDirectoryErrorCode) {
    /// producerID is empty, contains characters outside [A-Za-z0-9._-],
    /// exceeds 64 UTF-8 bytes, or is a special path component ("." / "..").
    TLSProducerDirectoryErrorCodeInvalidProducerID = 1,

    /// createDirectoryAtURL:withIntermediateDirectories: failed.
    /// NSUnderlyingErrorKey holds the NSFileManager error.
    TLSProducerDirectoryErrorCodeDirectoryCreationFailed = 2,

    /// Setting NSURLIsExcludedFromBackupKey or NSFileProtectionKey failed.
    /// NSUnderlyingErrorKey holds the NSFileManager/NSURL error.
    TLSProducerDirectoryErrorCodeAttributeSetFailed = 3,

    /// Attributes were set but the mandatory re-read did not confirm them
    /// (defense in depth: never trust a set without verifying).
    TLSProducerDirectoryErrorCodeAttributeVerificationFailed = 4,

    /// A custom directory URL is not a file URL inside the App container.
    TLSProducerDirectoryErrorCodeOutsideAppContainer = 5,
};

/// Maximum producerID length in UTF-8 bytes.
FOUNDATION_EXPORT const NSUInteger TLSProducerDirectoryMaxProducerIDUTF8Length;

/// App-sandbox directory helper. All methods are thread-safe (stateless).
@interface TLSProducerDirectory : NSObject

/// Validates a producerID:
///   - non-empty;
///   - only characters in [A-Za-z0-9._-] (ASCII only; Unicode letters are
///     rejected even though NSString allows them);
///   - at most 64 UTF-8 bytes (note: multibyte characters count as their
///     UTF-8 byte length, not as UTF-16 code units);
///   - not the special path components "." or ".." (they would collapse or
///     escape the producer directory when appended as a path component).
/// Returns NO and sets `error` (TLSProducerDirectoryErrorCodeInvalidProducerID)
/// when validation fails.
+ (BOOL)validateProducerID:(NSString *)producerID
                     error:(NSError * _Nullable * _Nullable)error;

/// Returns the default sandbox directory URL for a producerID:
///   ~/Library/Application Support/com.volcengine.tls/producer/<producerID>/
/// The directory is NOT created by this method; pass the result to
/// `createDirectoryAtURL:error:` to create it and apply the mandatory
/// attributes. Returns nil (with error) if producerID is invalid or the
/// Application Support directory cannot be located.
+ (nullable NSURL *)defaultDirectoryURLForProducerID:(NSString *)producerID
                                               error:(NSError * _Nullable * _Nullable)error;

/// Creates `url` (with intermediate directories) and applies the two
/// mandatory attributes, then RE-READS and verifies them:
///   - NSURLIsExcludedFromBackupKey = YES
///   - NSFileProtectionKey = NSFileProtectionCompleteUntilFirstUserAuthentication
/// Idempotent: succeeds if the directory already exists with the attributes.
/// Returns `url` on success; nil (with error) on any failure. The attributes
/// apply to this directory only — children are not covered (see header note).
///
/// Platform note: Data Protection (NSFileProtectionKey) is iOS-only. On macOS
/// host builds (swift build/test on macOS) that attribute is skipped — only
/// NSURLIsExcludedFromBackupKey is set and verified; on iOS (device,
/// simulator, Mac Catalyst) both attributes are always set and verified.
+ (nullable NSURL *)createDirectoryAtURL:(NSURL *)url
                                   error:(NSError * _Nullable * _Nullable)error;

/// Returns YES if `url` is a file URL whose standardized, symlink-resolved
/// path is equal to or nested inside the App container.
///
/// `baseURL` overrides the container root and is intended for TESTING ONLY;
/// pass nil to use the real process home directory (NSHomeDirectory()). The
/// check is a path-COMPONENT boundary comparison, so a sibling directory
/// sharing a string prefix (e.g. container "abc" vs candidate "abc-evil") is
/// rejected. Symlinks that resolve outside the container are also rejected.
+ (BOOL)isURL:(NSURL *)url insideContainerBaseURL:(nullable NSURL *)baseURL;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
