import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INTERFACE = ROOT / "mobile/interface"


class ControllerPressFilterTests(unittest.TestCase):
    def test_filter_policy_and_shipping_button_translation(self):
        source = (INTERFACE / "BallpadPhysicalControllers.mm").read_text()
        start = source.index("SunPadInputState BallpadAdaptPhysicalControllerSample(")
        end = source.index("\n@implementation BallpadPhysicalControllers", start)
        translation = source[start:end]
        harness = '''
#import "BallpadPhysicalControllers.h"
#include "BallpadControllerPressPolicy.h"
#include <algorithm>
#include <cmath>
#include <cassert>
constexpr uint8_t kBallpadTriggerPressThreshold = 30;
''' + translation + '''
int main() {
    for (int key = 0; key < 2; ++key)
        for (int controller = 0; controller < 2; ++controller)
            for (int ui = 0; ui < 2; ++ui)
                assert(BallpadShouldSuppressControllerPress(key, controller, ui)
                       == (!key && controller && !ui));
    const auto mapping = SunPadDefaultControllerButtonMapping();
    BallpadPhysicalControllerSample sample;
    assert(BallpadAdaptPhysicalControllerSample(sample, mapping).buttons == 0);
    sample.faceButtons = SunPadPhysicalControllerButtonA;
    assert(BallpadAdaptPhysicalControllerSample(sample, mapping).buttons == 0x0100);
    sample.menu = true;
    assert(BallpadAdaptPhysicalControllerSample(sample, mapping).buttons == 0x1100);
    sample.faceButtons = static_cast<SunPadPhysicalControllerButton>(0);
    assert(BallpadAdaptPhysicalControllerSample(sample, mapping).buttons == 0x1000);
    sample.menu = false;
    assert(BallpadAdaptPhysicalControllerSample(sample, mapping).buttons == 0);
    const bool block = BallpadShouldSuppressControllerPress(false, true, false);
    const unsigned hostA = 0x0100;
    const unsigned enterStart = block ? 0 : 0x1000;
    assert((hostA | enterStart) == 0x0100);
    assert((hostA | 0x1000) == 0x1100);
}
'''
        with tempfile.TemporaryDirectory(prefix="ballpad-controller-test-") as folder:
            path = pathlib.Path(folder)
            test = path / "controller.mm"
            test.write_text(harness)
            binary = path / "controller-test"
            result = subprocess.run([
                "xcrun", "--sdk", "macosx", "clang++", "-std=c++17", "-fobjc-arc",
                "-I", str(INTERFACE), "-I", str(INTERFACE / "sunpad"),
                str(test), str(INTERFACE / "sunpad/SunPadControllerMapping.mm"),
                "-framework", "Foundation", "-o", str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_recognizer_lifecycle_with_uikit_test_double(self):
        header = '''
#import <Foundation/Foundation.h>
@class UIGestureRecognizer, UITouch, UIPress, UIPressesEvent;
@protocol UIGestureRecognizerDelegate <NSObject>
@end
@protocol UIGestureRecognizerDelegate;
typedef NS_ENUM(NSInteger, UIGestureRecognizerState) {
    UIGestureRecognizerStatePossible, UIGestureRecognizerStateBegan,
    UIGestureRecognizerStateChanged, UIGestureRecognizerStateEnded,
    UIGestureRecognizerStateCancelled, UIGestureRecognizerStateFailed
};
@interface UIView : NSObject
@property(nonatomic, strong) NSMutableArray *gestureRecognizers;
- (void)addGestureRecognizer:(UIGestureRecognizer *)recognizer;
@end
@interface UIGestureRecognizer : NSObject
@property(nonatomic, weak) id<UIGestureRecognizerDelegate> delegate;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) BOOL cancelsTouchesInView, delaysTouchesBegan, delaysTouchesEnded;
@property(nonatomic, copy) NSArray *allowedPressTypes;
@property(nonatomic) UIGestureRecognizerState state;
- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (void)reset;
@end
@interface UIPress : NSObject
@property(nonatomic, strong) id key;
@property(nonatomic) NSInteger type;
@end
@interface UIPressesEvent : NSObject
@end
@interface UITouch : NSObject
@end
typedef NS_ENUM(NSInteger, UIPressType) {
    UIPressTypeUpArrow, UIPressTypeDownArrow, UIPressTypeLeftArrow,
    UIPressTypeRightArrow, UIPressTypeSelect, UIPressTypeMenu, UIPressTypePlayPause
};
'''
        harness = '''
#import "BallpadControllerPressFilter.mm"
#include <cassert>
@implementation UIView
- (instancetype)init {
    self = [super init];
    if (self) self.gestureRecognizers = [NSMutableArray array];
    return self;
}
- (void)addGestureRecognizer:(UIGestureRecognizer *)recognizer {
    [self.gestureRecognizers addObject:recognizer];
}
@end
@implementation UIGestureRecognizer
- (instancetype)initWithTarget:(id)target action:(SEL)action { return [super init]; }
- (void)reset { self.state = UIGestureRecognizerStatePossible; }
@end
@implementation UIPress
@end
@implementation UITouch
@end
static NSUInteger connected = 1;
@implementation BallpadPhysicalControllers
+ (instancetype)sharedControllers {
    static BallpadPhysicalControllers *instance = [BallpadPhysicalControllers new];
    return instance;
}
- (NSUInteger)connectedControllerCount { return connected; }
@end
void BallpadLog(NSString *format, ...) {}
int main() {
    @autoreleasepool {
        UIView *view = [UIView new];
        BallpadInstallControllerPressFilter(view, ^BOOL { return NO; });
        BallpadControllerPressFilter *filter = view.gestureRecognizers.firstObject;
        assert(filter.cancelsTouchesInView && filter.delaysTouchesBegan);
        assert(!filter.delaysTouchesEnded);
        assert(![filter gestureRecognizer:filter shouldReceiveTouch:[UITouch new]]);
        UIPress *a = [UIPress new];
        a.type = UIPressTypeSelect;
        UIPress *menu = [UIPress new];
        menu.type = UIPressTypeMenu;
        assert([filter gestureRecognizer:filter shouldReceivePress:a]);
        a.key = [NSObject new];
        assert(![filter gestureRecognizer:filter shouldReceivePress:a]);
        a.key = nil;
        connected = 0;
        assert(![filter gestureRecognizer:filter shouldReceivePress:a]);
        connected = 1;
        BallpadInstallControllerPressFilter(view, ^BOOL { return YES; });
        assert(view.gestureRecognizers.count == 1);
        assert(![filter gestureRecognizer:filter shouldReceivePress:a]);
        BallpadInstallControllerPressFilter(view, ^BOOL { return NO; });
        [filter pressesBegan:[NSSet setWithObject:a] withEvent:nil];
        assert(filter.state == UIGestureRecognizerStateBegan);
        [filter pressesBegan:[NSSet setWithObject:menu] withEvent:nil];
        assert(filter.state == UIGestureRecognizerStateChanged);
        [filter pressesEnded:[NSSet setWithObject:a] withEvent:nil];
        assert(filter.state == UIGestureRecognizerStateChanged);
        [filter pressesEnded:[NSSet setWithObject:menu] withEvent:nil];
        assert(filter.state == UIGestureRecognizerStateEnded);
        [filter reset];
        assert(filter.activePresses.count == 0);
        [filter pressesBegan:[NSSet setWithObject:a] withEvent:nil];
        [filter pressesCancelled:[NSSet setWithObject:a] withEvent:nil];
        assert(filter.state == UIGestureRecognizerStateCancelled);
        [filter reset];
        assert(filter.activePresses.count == 0);
    }
}
'''
        with tempfile.TemporaryDirectory(prefix="ballpad-recognizer-test-") as folder:
            path = pathlib.Path(folder)
            uikit = path / "UIKit"
            uikit.mkdir()
            (uikit / "UIKit.h").write_text(header)
            (uikit / "UIGestureRecognizerSubclass.h").write_text('#import "UIKit.h"\n')
            test = path / "recognizer.mm"
            test.write_text(harness)
            binary = path / "recognizer-test"
            result = subprocess.run([
                "xcrun", "--sdk", "macosx", "clang++", "-std=c++17", "-fobjc-arc",
                "-Wno-incomplete-implementation", "-I", str(path),
                "-I", str(INTERFACE), "-I", str(INTERFACE / "sunpad"),
                str(test), "-framework", "Foundation", "-o", str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
