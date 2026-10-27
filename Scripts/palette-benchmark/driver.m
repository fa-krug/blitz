// Injected into Blitz Dev by run.sh: drives the palette and times the main run loop per action.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <os/signpost.h>

static os_log_t pointsOfInterest;
// A windowless accessory app naps, and napping would stretch the driver's own timers.
static id napGuard;
static BOOL invalid = NO;
static double busyStart = -1, busyTotal = 0, actionStart = 0;
static NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *results;
static NSMutableArray<void (^)(void)> *steps;
// Long enough for every pass an action schedules, short enough that a run stays under two minutes.
static const double windowMs = 500;

static double nowMs(void) { return CACurrentMediaTime() * 1000.0; }

static NSString *env(NSString *name) { return NSProcessInfo.processInfo.environment[name]; }

// Busy is every stretch between waking and going back to sleep, so idle waits never count.
static void installObservers(void) {
    CFRunLoopObserverRef after = CFRunLoopObserverCreateWithHandler(
        NULL, kCFRunLoopAfterWaiting, true, LONG_MIN,
        ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) { busyStart = nowMs(); });
    CFRunLoopObserverRef before = CFRunLoopObserverCreateWithHandler(
        NULL, kCFRunLoopBeforeWaiting, true, LONG_MAX,
        ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
            if (busyStart < 0) return;
            busyTotal += nowMs() - busyStart;
            busyStart = -1;
        });
    CFRunLoopAddObserver(CFRunLoopGetMain(), after, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(CFRunLoopGetMain(), before, kCFRunLoopCommonModes);
}

static void runNext(void);

static void measureFor(NSString *name, double window, void (^action)(void)) {
    [steps addObject:^{
        invalid = NO;
        os_signpost_id_t signpost = os_signpost_id_generate(pointsOfInterest);
        os_signpost_interval_begin(pointsOfInterest, signpost, "action", "%{public}s", name.UTF8String);
        // Already inside a busy stretch: the timer that ran this step woke the loop.
        actionStart = nowMs();
        busyTotal = 0;
        busyStart = actionStart;
        action();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(window * NSEC_PER_MSEC)),
            dispatch_get_main_queue(), ^{
                os_signpost_interval_end(pointsOfInterest, signpost, "action");
                if (invalid) {
                    NSLog(@"[palette-benchmark] dropped %@: no palette window", name);
                } else {
                    if (!results[name]) results[name] = [NSMutableArray array];
                    [results[name] addObject:@(busyTotal)];
                }
                runNext();
            });
    }];
}

static void measure(NSString *name, void (^action)(void)) { measureFor(name, windowMs, action); }

static void idle(double ms) {
    [steps addObject:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
            dispatch_get_main_queue(), ^{ runNext(); });
    }];
}

static void finish(void) {
    NSString *out = env(@"BLITZ_BENCH_OUT") ?: @"/tmp/palette-benchmark.json";
    NSData *data = [NSJSONSerialization dataWithJSONObject:results
                                                   options:NSJSONWritingSortedKeys
                                                     error:nil];
    [data writeToFile:out atomically:YES];
    exit(0);
}

static void runNext(void) {
    if (steps.count == 0) return finish();
    void (^step)(void) = steps.firstObject;
    [steps removeObjectAtIndex:0];
    step();
}

static NSWindow *paletteWindow(void) {
    if (NSApp.keyWindow) return NSApp.keyWindow;
    for (NSWindow *window in NSApp.windows)
        if (window.isVisible && [window.className containsString:@"PalettePanel"]) return window;
    return nil;
}

// Straight to the panel when nothing is key: a locked screen grants no key window at all.
static void postKey(NSString *chars, unsigned short keyCode, NSEventModifierFlags flags) {
    NSWindow *window = paletteWindow();
    if (!window) {
        invalid = YES;
        return;
    }
    NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
    NSEventType types[2] = { NSEventTypeKeyDown, NSEventTypeKeyUp };
    for (int i = 0; i < 2; i++) {
        NSEvent *event = [NSEvent keyEventWithType:types[i] location:NSZeroPoint modifierFlags:flags
                                         timestamp:timestamp windowNumber:window.windowNumber
                                           context:nil characters:chars
                                charactersIgnoringModifiers:chars isARepeat:NO keyCode:keyCode];
        if (NSApp.keyWindow) [NSApp postEvent:event atStart:NO];
        else [window sendEvent:event];
    }
}

// The app delegate's own entry point, so a summon takes the path a deep link or hotkey does.
static void openLink(NSString *link) {
    [(id)NSApp.delegate application:NSApp openURLs:@[ [NSURL URLWithString:link] ]];
}

static unsigned short letterCode(unichar c) {
    static const unsigned short codes[26] = {
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6
    };
    return codes[c - 'a'];
}

static void letter(NSString *name, unichar c) {
    measure(name, ^{ postKey([NSString stringWithCharacters:&c length:1], letterCode(c), 0); });
}

static void backspace(NSString *name) { measure(name, ^{ postKey(@"\x7f", 51, 0); }); }

static void arrow(NSString *name, unichar function, unsigned short keyCode, int count) {
    for (int i = 0; i < count; i++) {
        measure(name, ^{
            postKey([NSString stringWithCharacters:&function length:1], keyCode,
                NSEventModifierFlagNumericPad | NSEventModifierFlagFunction);
        });
    }
}

static void escape(NSString *name) { measure(name, ^{ postKey(@"\x1b", 53, 0); }); }

static void summon(NSString *name, NSString *link) { measure(name, ^{ openLink(link); }); }

// An extension answers on its own thread, after `throttle`'s 300 ms, so its keys need a longer look.
static const double extensionWindowMs = 1500;

static void extensionKey(NSString *name, unichar c) {
    measureFor(name, extensionWindowMs,
        ^{ postKey([NSString stringWithCharacters:&c length:1], letterCode(c), 0); });
}

static void extensionBackspace(NSString *name) {
    measureFor(name, extensionWindowMs, ^{ postKey(@"\x7f", 51, 0); });
}

static void commandK(NSString *name) {
    measure(name, ^{ postKey(@"k", 40, NSEventModifierFlagCommand); });
}

static NSString *const launcher = @"blitz://run/togglePalette";
static NSString *const clipboard = @"blitz://run/command:clipboard-history";
static NSString *const emoji = @"blitz://run/command:search-emoji";

// ↑ on the first row recalls search history, and Escape over a query clears it rather than hiding.
static void launcherRound(void) {
    summon(@"summon.launcher", launcher);
    idle(200);
    letter(@"key.first_letter", 's');
    letter(@"key.more_letters", 'a');
    letter(@"key.more_letters", 'f');
    backspace(@"key.backspace");
    backspace(@"key.backspace");
    backspace(@"key.backspace_to_empty");
    arrow(@"arrow.launcher", NSDownArrowFunctionKey, 125, 4);
    arrow(@"arrow.launcher", NSUpArrowFunctionKey, 126, 3);
    letter(@"key.first_letter", 't');
    letter(@"key.more_letters", 'e');
    idle(200);
    escape(@"escape.clears_query");
    idle(200);
    arrow(@"arrow.launcher", NSDownArrowFunctionKey, 125, 6);
    escape(@"hide.after_moving");
    idle(300);
    summon(@"summon.launcher", launcher);
    idle(200);
    escape(@"hide.untouched");
    idle(300);
}

static void modesRound(void) {
    summon(@"summon.clipboard", clipboard);
    idle(300);
    arrow(@"arrow.clipboard", NSDownArrowFunctionKey, 125, 5);
    escape(@"hide.clipboard");
    idle(300);
    summon(@"summon.emoji", emoji);
    idle(300);
    arrow(@"arrow.emoji", NSDownArrowFunctionKey, 125, 5);
    arrow(@"arrow.emoji_right", NSRightArrowFunctionKey, 124, 5);
    letter(@"key.emoji_letter", 'h');
    backspace(@"key.emoji_backspace");
    escape(@"hide.emoji");
    idle(300);
}

// Long runs, so the selection leaves the visible band and the list has to follow it.
static void scrollRound(void) {
    summon(@"summon.launcher", launcher);
    idle(300);
    arrow(@"arrow.launcher_long", NSDownArrowFunctionKey, 125, 40);
    arrow(@"arrow.launcher_long_up", NSUpArrowFunctionKey, 126, 40);
    escape(@"hide.after_moving");
    idle(300);
    summon(@"summon.emoji", emoji);
    idle(300);
    arrow(@"arrow.emoji_long", NSDownArrowFunctionKey, 125, 30);
    arrow(@"arrow.emoji_long_up", NSUpArrowFunctionKey, 126, 30);
    escape(@"hide.emoji");
    idle(300);
    summon(@"summon.clipboard", clipboard);
    idle(300);
    arrow(@"arrow.clipboard_long", NSDownArrowFunctionKey, 125, 30);
    escape(@"hide.clipboard");
    idle(300);
}

// Blitz Bench, which run.sh installs: 600 GitLab-shaped rows, filtered by the extension or by Blitz.
static void extensionRound(NSString *command) {
    measureFor([@"open." stringByAppendingString:command], 3000,
        ^{ openLink([@"blitz://extensions/blitz-bench/" stringByAppendingString:command]); });
    idle(500);
    extensionKey([@"key.first." stringByAppendingString:command], 'd');
    extensionKey([@"key.more." stringByAppendingString:command], 'a');
    extensionKey([@"key.more." stringByAppendingString:command], 's');
    extensionBackspace([@"key.backspace." stringByAppendingString:command]);
    extensionBackspace([@"key.backspace." stringByAppendingString:command]);
    extensionBackspace([@"key.backspace_to_empty." stringByAppendingString:command]);
    arrow([@"arrow." stringByAppendingString:command], NSDownArrowFunctionKey, 125, 10);
    arrow([@"arrow." stringByAppendingString:command], NSUpArrowFunctionKey, 126, 10);
    arrow([@"arrow_long." stringByAppendingString:command], NSDownArrowFunctionKey, 125, 40);
    commandK([@"actions.open." stringByAppendingString:command]);
    idle(200);
    escape([@"actions.close." stringByAppendingString:command]);
    idle(200);
    escape([@"leave." stringByAppendingString:command]);
    idle(300);
}

static void buildScenario(void) {
    NSString *scenario = env(@"BLITZ_BENCH_SCENARIO") ?: @"launcher";
    int rounds = env(@"BLITZ_BENCH_ROUNDS").intValue ?: 6;
    summon(@"summon.first", launcher);
    idle(300);
    escape(@"hide.untouched");
    idle(300);
    for (int round = 0; round < rounds; round++) {
        if ([scenario isEqual:@"launcher"]) launcherRound();
        if ([scenario isEqual:@"modes"]) modesRound();
        if ([scenario isEqual:@"scroll"]) scrollRound();
        if ([scenario isEqual:@"extension"]) {
            extensionRound(@"search-list");
            extensionRound(@"filter-list");
            summon(@"summon.launcher", launcher);
            idle(300);
            commandK(@"actions.open.launcher");
            idle(200);
            escape(@"actions.close.launcher");
            idle(200);
            escape(@"hide.untouched");
            idle(300);
        }
    }
}

__attribute__((constructor)) static void start(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        napGuard = [NSProcessInfo.processInfo
            beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                              reason:@"palette benchmark"];
        pointsOfInterest = os_log_create("palette-benchmark", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
        results = [NSMutableDictionary dictionary];
        steps = [NSMutableArray array];
        installObservers();
        buildScenario();
        double settle = env(@"BLITZ_BENCH_SETTLE").doubleValue ?: 8;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settle * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{ runNext(); });
    });
}
