#import "BallpadControllerPressFilter.h"

#import "BallpadControllerPressPolicy.h"
#import "BallpadLog.h"
#import "BallpadPhysicalControllers.h"
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <objc/runtime.h>

@interface BallpadControllerPressFilter : UIGestureRecognizer <UIGestureRecognizerDelegate>
@property(nonatomic, copy) BOOL (^presentingInterface)(void);
@property(nonatomic, strong) NSMutableSet<UIPress *> *activePresses;
@property(nonatomic) NSUInteger loggedPresses;
@end

@implementation BallpadControllerPressFilter

- (instancetype)init {
    self = [super initWithTarget:nil action:nil];
    if (self != nil) {
        self.delegate = self;
        self.name = @"BallpadControllerPressFilter";
        self.cancelsTouchesInView = YES;
        self.delaysTouchesBegan = YES;
        self.delaysTouchesEnded = NO;
        self.allowedPressTypes = @[@(UIPressTypeUpArrow), @(UIPressTypeDownArrow),
            @(UIPressTypeLeftArrow), @(UIPressTypeRightArrow), @(UIPressTypeSelect),
            @(UIPressTypeMenu), @(UIPressTypePlayPause)];
        self.activePresses = [NSMutableSet set];
    }
    return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceivePress:(UIPress *)press {
    return BallpadShouldSuppressControllerPress(
        press.key != nil,
        [[BallpadPhysicalControllers sharedControllers] connectedControllerCount] > 0,
        self.presentingInterface != nil && self.presentingInterface());
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.activePresses unionSet:presses];
    self.state = self.state == UIGestureRecognizerStatePossible
        ? UIGestureRecognizerStateBegan : UIGestureRecognizerStateChanged;
    for (UIPress *press in presses) {
        if (self.loggedPresses++ < 64)
            BallpadLog(@"controller: suppressed UIKit press type %ld key none before SDL keyboard conversion",
                       (long)press.type);
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.activePresses minusSet:presses];
    self.state = self.activePresses.count == 0
        ? UIGestureRecognizerStateEnded : UIGestureRecognizerStateChanged;
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.activePresses minusSet:presses];
    self.state = self.activePresses.count == 0
        ? UIGestureRecognizerStateCancelled : UIGestureRecognizerStateChanged;
}

- (void)reset {
    [super reset];
    [self.activePresses removeAllObjects];
}

@end

void BallpadInstallControllerPressFilter(UIView *view, BOOL (^presentingInterface)(void)) {
    static char associationKey;
    BallpadControllerPressFilter *filter = objc_getAssociatedObject(view, &associationKey);
    if (filter == nil) {
        filter = [BallpadControllerPressFilter new];
        objc_setAssociatedObject(view, &associationKey, filter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [view addGestureRecognizer:filter];
        BallpadLog(@"controller: UIKit press filter installed on %@", NSStringFromClass(view.class));
    }
    filter.presentingInterface = presentingInterface;
}
