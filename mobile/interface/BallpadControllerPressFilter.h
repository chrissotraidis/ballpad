#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void BallpadInstallControllerPressFilter(
    UIView *view, BOOL (^presentingInterface)(void));

NS_ASSUME_NONNULL_END
