//
// EntryBenchmarkMain.m
// One mixed-language app: UIApplicationMain on iOS, a waiting CLI on macOS.
//

#import "EntryBenchmarkObjCEntry.h"
#import "EntryBenchmarkRunner.h"

#include <TargetConditionals.h>
#include <stdio.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <Foundation/Foundation.h>
#endif

static id<EBBenchmarkEntry> EBMakeEntry(EBBenchmarkPayload *payload,
                                         EBBenchmarkOptions *options) {
    if ([options.entry isEqualToString:@"objc"]) {
        return [[EBObjCEntry alloc] initWithPayload:payload options:options];
    }

    // The Swift class is deliberately selected by runtime name so this file
    // remains the same ObjC UIApplicationMain/CLI entry for both choices.
    Class swiftClass = NSClassFromString(@"EBSwiftEntry");
    if (!swiftClass) {
        return nil;
    }
    id allocated = [swiftClass alloc];
    SEL initializer = NSSelectorFromString(@"initWithPayload:options:");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id entry = [allocated performSelector:initializer
                              withObject:payload
                              withObject:options];
#pragma clang diagnostic pop
    return entry;
}

static EBBenchmarkOptions *EBParseOptions(NSArray<NSString *> *arguments) {
    NSError *error = nil;
    EBBenchmarkOptions *options =
        [EBBenchmarkOptions optionsWithArguments:arguments error:&error];
    if (!options) {
        BOOL help = [error.userInfo[@"help"] boolValue];
        FILE *stream = help ? stdout : stderr;
        fprintf(stream, "%s\n", error.localizedDescription.UTF8String ?: "invalid arguments");
    }
    return options;
}

#if TARGET_OS_IPHONE

@interface EBAppDelegate : UIResponder <UIApplicationDelegate>

@property(nonatomic, strong) EBBenchmarkRunner *runner;
@property(nonatomic, strong) UIWindow *window;

@end

@implementation EBAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    (void)application;
    (void)launchOptions;
    EBBenchmarkOptions *options = EBParseOptions(NSProcessInfo.processInfo.arguments);
    if (!options) {
        // A valid invocation keeps UIApplicationMain alive. Invalid arguments
        // are printed and leave the app idle for inspection from the console.
        return YES;
    }
    EBBenchmarkPayload *payload = [[EBBenchmarkPayload alloc] init];
    id<EBBenchmarkEntry> entry = EBMakeEntry(payload, options);
    if (!entry) {
        fprintf(stderr, "EntryBenchmark: Swift entry class is unavailable\n");
        return YES;
    }
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *viewController = [[UIViewController alloc] init];
    viewController.view.backgroundColor = UIColor.systemBackgroundColor;
    self.window.rootViewController = viewController;
    [self.window makeKeyAndVisible];
    // Keep this test-only app active for the whole run. Restore the app-level
    // setting when the bounded runner has written its result.
    application.idleTimerDisabled = YES;
    __weak UIApplication *weakApplication = application;
    self.runner = [[EBBenchmarkRunner alloc]
        initWithOptions:options
                 payload:payload
                  entry:entry
             completion:^(NSURL * _Nullable artifactURL, NSError * _Nullable error) {
        (void)artifactURL;
        weakApplication.idleTimerDisabled = NO;
        if (error) {
            fprintf(stderr, "ENTRY_BENCHMARK_ERROR run_id=%s domain=%s code=%ld\n",
                    options.runID.UTF8String,
                    error.domain.UTF8String ?: "",
                    (long)error.code);
        }
    }];
    [self.runner start];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([EBAppDelegate class]));
    }
}

#else

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithCapacity:(NSUInteger)argc];
        for (int index = 0; index < argc; index++) {
            [arguments addObject:[NSString stringWithUTF8String:argv[index]] ?: @""];
        }
        EBBenchmarkOptions *options = EBParseOptions(arguments);
        if (!options) {
            NSError *parseError = nil;
            (void)[EBBenchmarkOptions optionsWithArguments:arguments error:&parseError];
            return [parseError.userInfo[@"help"] boolValue] ? 0 : 2;
        }

        EBBenchmarkPayload *payload = [[EBBenchmarkPayload alloc] init];
        id<EBBenchmarkEntry> entry = EBMakeEntry(payload, options);
        if (!entry) {
            fprintf(stderr, "EntryBenchmark: Swift entry class is unavailable\n");
            return 2;
        }

        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        __block NSError *runError = nil;
        EBBenchmarkRunner *runner = [[EBBenchmarkRunner alloc]
            initWithOptions:options
                     payload:payload
                      entry:entry
                 completion:^(NSURL * _Nullable artifactURL, NSError * _Nullable error) {
            (void)artifactURL;
            runError = error;
            dispatch_semaphore_signal(finished);
        }];
        [runner start];
        dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
        return runError ? 1 : 0;
    }
}

#endif
