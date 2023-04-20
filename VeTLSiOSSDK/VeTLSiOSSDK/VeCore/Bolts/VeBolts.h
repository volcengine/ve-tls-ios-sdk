/*
 *  Copyright (c) 2014, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the BSD-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 */

#import "VeCancellationToken.h"
#import "VeCancellationTokenRegistration.h"
#import "VeCancellationTokenSource.h"
#import "VeExecutor.h"
#import "VeGeneric.h"
#import "VeTask.h"
#import "VeTaskCompletionSource.h"


NS_ASSUME_NONNULL_BEGIN

/**
 A string containing the version of the Bolts Framework used by the current application.
 */
extern NSString *const VeBoltsFrameworkVersionString;

NS_ASSUME_NONNULL_END
