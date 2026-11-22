// MiddleTap — three-finger click / tap on the trackpad = middle mouse click.
// A small menu-bar app with a settings window, for macOS on Apple silicon.

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <math.h>

// ---------------------------------------------------------------------------
// Private MultitouchSupport.framework (loaded at runtime with dlopen)
// ---------------------------------------------------------------------------
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
typedef struct {
    int      frame;
    double   timestamp;
    int      identifier, state, fingerID, handID;
    MTVector normalized;          // 0..1 position on the pad
    float    size;
    int      zero1;
    float    angle, majorAxis, minorAxis;
    MTVector mm;
    int      zero2[2];
    float    unk2;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, const MTTouch *, int, double, int);

static CFArrayRef (*pMTDeviceCreateList)(void);
static void (*pMTRegisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*pMTUnregisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*pMTDeviceStart)(MTDeviceRef, int);
static void (*pMTDeviceStop)(MTDeviceRef);

static BOOL loadMultitouch(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!h) return NO;
    pMTDeviceCreateList               = dlsym(h, "MTDeviceCreateList");
    pMTRegisterContactFrameCallback   = dlsym(h, "MTRegisterContactFrameCallback");
    pMTUnregisterContactFrameCallback = dlsym(h, "MTUnregisterContactFrameCallback");
    pMTDeviceStart                    = dlsym(h, "MTDeviceStart");
    pMTDeviceStop                     = dlsym(h, "MTDeviceStop");
    return pMTDeviceCreateList && pMTRegisterContactFrameCallback && pMTDeviceStart;
}

// ---------------------------------------------------------------------------
// Settings keys
// ---------------------------------------------------------------------------
static NSString *const kClickEnabled = @"clickEnabled";
static NSString *const kTapEnabled   = @"tapEnabled";
static NSString *const kTapTimeMs    = @"tapTimeMs";      // max tap duration, milliseconds
static NSString *const kTapMovePct   = @"tapMovePercent"; // max movement, % of pad size
static NSString *const kShowMenuIcon = @"showMenuBarIcon";
static NSString *const kLaunchedOnce = @"hasLaunchedBefore";

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------
static _Atomic int    gFingers = 0;                  // fingers currently on the pad
static _Atomic bool   gClickedDuringGesture = false; // a physical click happened this gesture
static _Atomic bool   gClickOn = true;
static _Atomic bool   gTapOn   = true;
static _Atomic double gMaxTapDuration = 0.30;        // seconds
static _Atomic float  gMaxTapMovement = 0.04f;       // normalized pad units

static CFMachPortRef gEventTap = NULL;
static bool gMiddleDown = false;                     // main thread only

// Tap-gesture tracking (multitouch callback thread only)
static bool   tActive = false, tValid = false, tSawThree = false;
static double tStart = 0;
static float  tCx = 0, tCy = 0;

static void postMiddleClick(void) {
    CGEventRef cur = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(cur);
    CFRelease(cur);

    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseDown, p, kCGMouseButtonCenter);
    CGEventRef up   = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseUp,   p, kCGMouseButtonCenter);
    CGEventSetIntegerValueField(down, kCGMouseEventClickState, 1);
    CGEventSetIntegerValueField(up,   kCGMouseEventClickState, 1);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
}

static int touchCallback(MTDeviceRef dev, const MTTouch *touches, int n, double ts, int frame) {
    (void)dev; (void)ts; (void)frame;
    atomic_store(&gFingers, n);
    double now = CFAbsoluteTimeGetCurrent();

    if (n > 0 && !tActive) {               // gesture begins
        tActive = true; tValid = true; tSawThree = false; tStart = now;
        atomic_store(&gClickedDuringGesture, false);
    }
    if (!tActive) return 0;

    if (n > 3) tValid = false;             // four+ fingers: not our gesture

    if (n == 3 && tValid) {
        float cx = 0, cy = 0;
        for (int i = 0; i < 3; i++) { cx += touches[i].normalized.pos.x; cy += touches[i].normalized.pos.y; }
        cx /= 3; cy /= 3;
        if (!tSawThree) { tSawThree = true; tCx = cx; tCy = cy; }
        else if (hypotf(cx - tCx, cy - tCy) > atomic_load(&gMaxTapMovement)) tValid = false; // a swipe
    }

    if (n == 0) {                          // all fingers lifted
        tActive = false;
        if (tValid && tSawThree
            && (now - tStart) <= atomic_load(&gMaxTapDuration)
            && !atomic_load(&gClickedDuringGesture)
            && atomic_load(&gTapOn)) {
            dispatch_async(dispatch_get_main_queue(), ^{ postMiddleClick(); });
        }
    }
    return 0;
}

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef ev, void *ref) {
    (void)proxy; (void)ref;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gEventTap) CGEventTapEnable(gEventTap, true);
        return ev;
    }
    switch (type) {
        case kCGEventLeftMouseDown:
            if (atomic_load(&gClickOn) && atomic_load(&gFingers) == 3) {
                atomic_store(&gClickedDuringGesture, true);
                gMiddleDown = true;
                CGEventSetType(ev, kCGEventOtherMouseDown);
                CGEventSetIntegerValueField(ev, kCGMouseEventButtonNumber, kCGMouseButtonCenter);
            }
            break;
        case kCGEventLeftMouseDragged:
            if (gMiddleDown) {
                CGEventSetType(ev, kCGEventOtherMouseDragged);
                CGEventSetIntegerValueField(ev, kCGMouseEventButtonNumber, kCGMouseButtonCenter);
            }
            break;
        case kCGEventLeftMouseUp:
            if (gMiddleDown) {
                gMiddleDown = false;
                CGEventSetType(ev, kCGEventOtherMouseUp);
                CGEventSetIntegerValueField(ev, kCGMouseEventButtonNumber, kCGMouseButtonCenter);
            }
            break;
        default: break;
    }
    return ev;
}

// ---------------------------------------------------------------------------
// Menu-bar icon: a small trackpad outline with three fingertips (template image)
// ---------------------------------------------------------------------------
static NSImage *menuBarIcon(void) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(20, 16) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [NSColor.blackColor set];
        NSBezierPath *pad = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1.5, 1.5, 17, 13) xRadius:3 yRadius:3];
        pad.lineWidth = 1.4;
        [pad stroke];
        CGFloat d = 3.6;
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(4.6 - d/2, 7.0 - d/2, d, d)] fill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(10.0 - d/2, 8.6 - d/2, d, d)] fill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(15.4 - d/2, 7.0 - d/2, d, d)] fill];
        return YES;
    }];
    img.template = YES;
    img.accessibilityDescription = @"MiddleTap";
    return img;
}

// ---------------------------------------------------------------------------
// UI building blocks
// ---------------------------------------------------------------------------

// Rounded "grouped" background, like System Settings sections.
@interface GroupView : NSView
@end
@implementation GroupView
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    self.layer.cornerRadius = 10;
    self.layer.borderWidth = 0.5;
    self.layer.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:0.045].CGColor;
    self.layer.borderColor = NSColor.separatorColor.CGColor;
}
@end

// Live test area: shows fingers on the trackpad and catches middle clicks.
@interface TestPadView : NSView
@property NSInteger middleClicks;
@property CGFloat flash;
@property (copy) NSString *message;
@property (strong) NSTimer *flashTimer;
@end

@implementation TestPadView
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) { _message = @"Middle-click here to test"; }
    return self;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)isFlipped { return YES; }

- (void)otherMouseDown:(NSEvent *)e {
    if (e.buttonNumber != 2) return;
    self.middleClicks++;
    self.message = [NSString stringWithFormat:@"Middle click ✓   (%ld)", (long)self.middleClicks];
    self.flash = 1.0;
    [self.flashTimer invalidate];
    self.flashTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer *t) {
        self.flash -= 0.035;
        if (self.flash <= 0) { self.flash = 0; [t invalidate]; }
        self.needsDisplay = YES;
    }];
    self.needsDisplay = YES;
}
- (void)mouseDown:(NSEvent *)e      { self.message = @"That was a normal click: try three fingers"; self.needsDisplay = YES; }
- (void)rightMouseDown:(NSEvent *)e { self.message = @"That was a right click: try three fingers";  self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
    NSRect b = NSInsetRect(self.bounds, 1, 1);
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:b xRadius:10 yRadius:10];

    NSColor *accent = NSColor.controlAccentColor;
    [[accent colorWithAlphaComponent:0.06 + 0.25 * self.flash] setFill];
    [outline fill];

    CGFloat dash[] = {5, 4};
    [outline setLineDash:dash count:2 phase:0];
    outline.lineWidth = 1.2;
    [[accent colorWithAlphaComponent:0.45 + 0.5 * self.flash] setStroke];
    [outline stroke];

    // Finger indicator: five dots, filled for each finger currently on the trackpad.
    int fingers = atomic_load(&gFingers);
    CGFloat d = 12, gap = 8, total = 5 * d + 4 * gap;
    CGFloat x0 = NSMidX(b) - total / 2, y = 22;
    for (int i = 0; i < 5; i++) {
        NSRect r = NSMakeRect(x0 + i * (d + gap), y, d, d);
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:r];
        if (i < fingers) {
            [(fingers == 3 ? accent : NSColor.secondaryLabelColor) setFill];
            [dot fill];
        } else {
            [NSColor.tertiaryLabelColor setStroke];
            dot.lineWidth = 1;
            [dot stroke];
        }
    }

    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary *big = @{ NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightMedium],
                           NSForegroundColorAttributeName: NSColor.labelColor, NSParagraphStyleAttributeName: ps };
    NSDictionary *small = @{ NSFontAttributeName: [NSFont systemFontOfSize:11],
                             NSForegroundColorAttributeName: NSColor.secondaryLabelColor, NSParagraphStyleAttributeName: ps };
    [self.message drawInRect:NSMakeRect(b.origin.x, 48, b.size.width, 20) withAttributes:big];
    NSString *sub = fingers > 0 ? [NSString stringWithFormat:@"%d finger%@ on trackpad", fingers, fingers == 1 ? @"" : @"s"]
                                : @"Put three fingers on the trackpad and click or tap";
    [sub drawInRect:NSMakeRect(b.origin.x, 72, b.size.width, 16) withAttributes:small];
}
@end

static NSTextField *label(NSString *s, CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *t = [NSTextField labelWithString:s];
    t.font = [NSFont systemFontOfSize:size weight:w];
    t.textColor = c;
    return t;
}

static NSTextField *wrapLabel(NSString *s, CGFloat width) {
    NSTextField *t = [NSTextField wrappingLabelWithString:s];
    t.font = [NSFont systemFontOfSize:11];
    t.textColor = NSColor.secondaryLabelColor;
    t.preferredMaxLayoutWidth = width;
    return t;
}

static NSView *separator(void) {
    NSBox *b = [NSBox new];
    b.boxType = NSBoxSeparator;
    return b;
}

// A titled group of rows with hairline separators between them.
static NSView *section(NSString *title, NSArray<NSView *> *rows) {
    GroupView *group = [GroupView new];
    NSMutableArray *items = [NSMutableArray array];
    for (NSUInteger i = 0; i < rows.count; i++) {
        if (i > 0) [items addObject:separator()];
        [items addObject:rows[i]];
    }
    NSStackView *inner = [NSStackView stackViewWithViews:items];
    inner.orientation = NSUserInterfaceLayoutOrientationVertical;
    inner.alignment = NSLayoutAttributeLeading;
    inner.spacing = 10;
    inner.edgeInsets = NSEdgeInsetsMake(12, 14, 12, 14);
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [group addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:group.topAnchor],
        [inner.bottomAnchor constraintEqualToAnchor:group.bottomAnchor],
        [inner.leadingAnchor constraintEqualToAnchor:group.leadingAnchor],
        [inner.trailingAnchor constraintEqualToAnchor:group.trailingAnchor],
    ]];
    for (NSView *v in items) [v.widthAnchor constraintEqualToAnchor:inner.widthAnchor constant:-28].active = YES;

    NSStackView *outer = [NSStackView stackViewWithViews:@[
        label(title.uppercaseString, 10.5, NSFontWeightSemibold, NSColor.secondaryLabelColor), group]];
    outer.orientation = NSUserInterfaceLayoutOrientationVertical;
    outer.alignment = NSLayoutAttributeLeading;
    outer.spacing = 6;
    [group.widthAnchor constraintEqualToAnchor:outer.widthAnchor].active = YES;
    return outer;
}

// "Title / detail ............ [control]"
static NSView *rowW(NSString *title, NSString *detail, NSView *control, CGFloat wrap) {
    NSMutableArray *texts = [NSMutableArray arrayWithObject:label(title, 13, NSFontWeightRegular, NSColor.labelColor)];
    if (detail) {
        NSTextField *t = wrapLabel(detail, wrap);
        [t setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [texts addObject:t];
    }
    NSStackView *textStack = [NSStackView stackViewWithViews:texts];
    textStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    textStack.alignment = NSLayoutAttributeLeading;
    textStack.spacing = 2;

    NSStackView *h = [NSStackView stackViewWithViews:@[textStack, control]];
    h.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    h.alignment = NSLayoutAttributeCenterY;
    h.distribution = NSStackViewDistributionFill;
    [textStack setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [control setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return h;
}

static NSView *row(NSString *title, NSString *detail, NSView *control) { return rowW(title, detail, control, 290); }

// ---------------------------------------------------------------------------
// App delegate (menu bar + settings window)
// ---------------------------------------------------------------------------
@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMenuItem *permissionItem, *clickItem, *tapItem;
@property (strong) NSArray *devices;
@property (strong) NSTimer *retryTimer, *uiTimer;

@property (strong) NSWindow *window;
@property (strong) NSSwitch *clickSwitch, *tapSwitch, *loginSwitch, *menuIconSwitch;
@property (strong) NSSlider *timeSlider, *moveSlider;
@property (strong) NSTextField *timeValue, *moveValue, *statusLabel;
@property (strong) NSView *permissionBanner;
@property (strong) TestPadView *testPad;
@property (strong) NSView *rootView;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d registerDefaults:@{ kClickEnabled: @YES, kTapEnabled: @YES, kTapTimeMs: @300,
                           kTapMovePct: @4, kShowMenuIcon: @YES, kLaunchedOnce: @NO }];
    [self loadSettings];
    [self buildMenu];

    if (!loadMultitouch()) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"MiddleTap couldn't load the trackpad framework.";
        a.informativeText = @"This version of macOS may have changed MultitouchSupport.";
        [a runModal];
        [NSApp terminate:nil];
        return;
    }
    [self startMultitouch];

    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(didWake:)
                                                           name:NSWorkspaceDidWakeNotification object:nil];

    NSDictionary *opts = @{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES };
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    BOOL tapOK = [self installEventTap];
    if (!tapOK) {
        self.retryTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
            if ([self installEventTap]) { [t invalidate]; self.retryTimer = nil; [self refreshUI]; }
        }];
    }

    // Open the window on first launch, or when permission is still missing.
    if (![d boolForKey:kLaunchedOnce] || !tapOK) {
        [d setBool:YES forKey:kLaunchedOnce];
        [self showSettings:nil];
    }
}

// Double-clicking the app while it's already running opens the settings window.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {
    [self showSettings:nil];
    return NO;
}

- (void)loadSettings {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    atomic_store(&gClickOn, [d boolForKey:kClickEnabled]);
    atomic_store(&gTapOn,   [d boolForKey:kTapEnabled]);
    atomic_store(&gMaxTapDuration, [d doubleForKey:kTapTimeMs] / 1000.0);
    atomic_store(&gMaxTapMovement, (float)([d doubleForKey:kTapMovePct] / 100.0));
}

- (BOOL)installEventTap {
    if (gEventTap) return YES;
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp)
                     | CGEventMaskBit(kCGEventLeftMouseDragged);
    gEventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                 mask, eventTapCallback, NULL);
    if (!gEventTap) return NO;
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, gEventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    CGEventTapEnable(gEventTap, true);
    return YES;
}

- (void)startMultitouch {
    [self stopMultitouch];
    CFArrayRef list = pMTDeviceCreateList();
    if (!list) return;
    self.devices = CFBridgingRelease(list);
    for (id obj in self.devices) {
        MTDeviceRef dev = (__bridge MTDeviceRef)obj;
        pMTRegisterContactFrameCallback(dev, touchCallback);
        pMTDeviceStart(dev, 0);
    }
}

- (void)stopMultitouch {
    for (id obj in self.devices) {
        MTDeviceRef dev = (__bridge MTDeviceRef)obj;
        if (pMTUnregisterContactFrameCallback) pMTUnregisterContactFrameCallback(dev, touchCallback);
        if (pMTDeviceStop) pMTDeviceStop(dev);
    }
    self.devices = nil;
    atomic_store(&gFingers, 0);
}

- (void)didWake:(NSNotification *)n {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self startMultitouch];
    });
}

// ---- Menu bar ------------------------------------------------------------

- (void)buildMenu {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = menuBarIcon();
    self.statusItem.visible = [NSUserDefaults.standardUserDefaults boolForKey:kShowMenuIcon];

    NSMenu *m = [NSMenu new];
    m.autoenablesItems = NO;

    self.permissionItem = [m addItemWithTitle:@"⚠︎ Grant Accessibility Permission…"
                                       action:@selector(openAccessibility:) keyEquivalent:@""];
    self.permissionItem.target = self;

    self.clickItem = [m addItemWithTitle:@"Three-Finger Click" action:@selector(menuToggleClick:) keyEquivalent:@""];
    self.clickItem.target = self;
    self.tapItem = [m addItemWithTitle:@"Three-Finger Tap" action:@selector(menuToggleTap:) keyEquivalent:@""];
    self.tapItem.target = self;

    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *settings = [m addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","];
    settings.target = self;
    [m addItem:NSMenuItem.separatorItem];
    [m addItemWithTitle:@"Quit MiddleTap" action:@selector(terminate:) keyEquivalent:@"q"];

    self.statusItem.menu = m;
    [self refreshUI];
}

// ---- Settings window -----------------------------------------------------

// System Settings uses mini-size switches; NSSwitch defaults to the large "regular" size.
- (NSSwitch *)makeSwitch {
    NSSwitch *sw = [NSSwitch new];
    sw.controlSize = NSControlSizeMini;
    sw.target = self;
    sw.action = @selector(switchChanged:);
    return sw;
}

- (void)buildWindow {
    const CGFloat W = 460;

    // Header: icon, name, tagline, status
    NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
    [icon.widthAnchor constraintEqualToConstant:64].active = YES;
    [icon.heightAnchor constraintEqualToConstant:64].active = YES;

    NSStackView *titles = [NSStackView stackViewWithViews:@[
        label(@"MiddleTap", 20, NSFontWeightBold, NSColor.labelColor),
        label(@"Three fingers, one middle click.", 12, NSFontWeightRegular, NSColor.secondaryLabelColor)]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 2;

    self.statusLabel = label(@"", 12, NSFontWeightMedium, NSColor.secondaryLabelColor);

    NSStackView *header = [NSStackView stackViewWithViews:@[icon, titles, self.statusLabel]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 14;
    [titles setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    // Permission banner
    NSButton *grant = [NSButton buttonWithTitle:@"Open Settings" target:self action:@selector(openAccessibility:)];
    grant.bezelStyle = NSBezelStyleRounded;
    grant.keyEquivalent = @"\r";
    self.permissionBanner = section(@"Permission needed", @[
        row(@"Allow Accessibility access",
            @"Turn on MiddleTap in Privacy & Security → Accessibility. It starts working a couple of seconds after you do.",
            grant)]);

    // Gestures
    self.clickSwitch = [self makeSwitch];
    self.tapSwitch   = [self makeSwitch];
    NSView *gestures = section(@"Gestures", @[
        row(@"Three-finger click", @"Press the trackpad down with three fingers.", self.clickSwitch),
        row(@"Three-finger tap", @"Lightly tap with three fingers. Swipes are ignored.", self.tapSwitch)]);

    // Tap sensitivity
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    self.timeSlider = [NSSlider sliderWithValue:[d doubleForKey:kTapTimeMs] minValue:150 maxValue:500
                                         target:self action:@selector(sliderChanged:)];
    self.moveSlider = [NSSlider sliderWithValue:[d doubleForKey:kTapMovePct] minValue:1 maxValue:10
                                         target:self action:@selector(sliderChanged:)];
    for (NSSlider *s in @[self.timeSlider, self.moveSlider]) {
        s.controlSize = NSControlSizeSmall;   // matches the sliders in System Settings
        [s.widthAnchor constraintEqualToConstant:140].active = YES;
    }
    self.timeValue = label(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.moveValue = label(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    for (NSTextField *t in @[self.timeValue, self.moveValue]) {
        t.alignment = NSTextAlignmentRight;
        t.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
        [t.widthAnchor constraintEqualToConstant:48].active = YES;
    }
    NSStackView *(^sliderGroup)(NSSlider *, NSTextField *) = ^(NSSlider *s, NSTextField *v) {
        NSStackView *g = [NSStackView stackViewWithViews:@[s, v]];
        g.spacing = 6;
        return g;
    };
    NSView *sensitivity = section(@"Tap sensitivity", @[
        rowW(@"Maximum tap time", @"Longer taps are ignored.", sliderGroup(self.timeSlider, self.timeValue), 170),
        rowW(@"Movement allowed", @"How far fingers can drift and still count as a tap.",
             sliderGroup(self.moveSlider, self.moveValue), 170)]);

    // Test pad
    self.testPad = [[TestPadView alloc] initWithFrame:NSZeroRect];
    [self.testPad.heightAnchor constraintEqualToConstant:104].active = YES;
    NSView *test = section(@"Try it", @[self.testPad]);

    // General
    self.loginSwitch    = [self makeSwitch];
    self.menuIconSwitch = [self makeSwitch];
    NSView *general = section(@"General", @[
        row(@"Launch at login", nil, self.loginSwitch),
        row(@"Show icon in menu bar", @"When hidden, open MiddleTap from Applications to see this window.", self.menuIconSwitch)]);

    // Footer
    NSButton *rescan = [NSButton buttonWithTitle:@"Rescan Trackpads" target:self action:@selector(rescan:)];
    NSButton *quit   = [NSButton buttonWithTitle:@"Quit MiddleTap" target:NSApp action:@selector(terminate:)];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *footer = [NSStackView stackViewWithViews:@[rescan, spacer, quit]];
    footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;

    // Root
    NSArray *parts = @[header, self.permissionBanner, gestures, sensitivity, test, general, footer];
    NSStackView *root = [NSStackView stackViewWithViews:parts];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 18;
    root.edgeInsets = NSEdgeInsetsMake(38, 24, 20, 24);   // top inset clears the traffic lights
    root.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *v in parts) [v.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-48].active = YES;
    [root.widthAnchor constraintEqualToConstant:W].active = YES;

    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, 600)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                        | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView
                                                backing:NSBackingStoreBuffered defer:NO];
    w.titlebarAppearsTransparent = YES;
    w.titleVisibility = NSWindowTitleHidden;
    w.title = @"MiddleTap";
    w.releasedWhenClosed = NO;
    w.delegate = self;
    w.movableByWindowBackground = YES;

    NSView *content = [NSView new];
    [content addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:content.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [root.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    ]];
    w.contentView = content;
    self.window = w;
    self.rootView = root;
}

- (void)showSettings:(id)sender {
    if (!self.window) [self buildWindow];
    [self refreshUI];
    [self.rootView layoutSubtreeIfNeeded];
    [self.window setContentSize:self.rootView.fittingSize];
    if (!self.window.isVisible) [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    if (@available(macOS 14.0, *)) [NSApp activate];
    else [NSApp activateIgnoringOtherApps:YES];

    // Live updates (finger dots, permission status) only while the window is open.
    [self.uiTimer invalidate];
    self.uiTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        self.testPad.needsDisplay = YES;
        [self refreshStatus];
    }];
}

- (void)windowWillClose:(NSNotification *)n {
    [self.uiTimer invalidate];
    self.uiTimer = nil;
}

// ---- State → UI ----------------------------------------------------------

- (void)refreshStatus {
    BOOL ok = gEventTap != NULL;
    BOOL anyOn = atomic_load(&gClickOn) || atomic_load(&gTapOn);
    if (self.statusLabel) {
        if (!ok)        { self.statusLabel.stringValue = @"● Needs permission"; self.statusLabel.textColor = NSColor.systemOrangeColor; }
        else if (anyOn) { self.statusLabel.stringValue = @"● Active";           self.statusLabel.textColor = NSColor.systemGreenColor; }
        else            { self.statusLabel.stringValue = @"● Paused";           self.statusLabel.textColor = NSColor.secondaryLabelColor; }
    }
    if (self.permissionBanner.hidden != ok) {
        self.permissionBanner.hidden = ok;
        if (self.window.isVisible) [self.window setContentSize:self.rootView.fittingSize];
    }
    self.permissionItem.hidden = ok;
}

- (void)refreshUI {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL click = atomic_load(&gClickOn), tap = atomic_load(&gTapOn);
    BOOL login = SMAppService.mainAppService.status == SMAppServiceStatusEnabled;

    self.clickItem.state = click ? NSControlStateValueOn : NSControlStateValueOff;
    self.tapItem.state   = tap   ? NSControlStateValueOn : NSControlStateValueOff;

    self.clickSwitch.state    = click ? NSControlStateValueOn : NSControlStateValueOff;
    self.tapSwitch.state      = tap   ? NSControlStateValueOn : NSControlStateValueOff;
    self.loginSwitch.state    = login ? NSControlStateValueOn : NSControlStateValueOff;
    self.menuIconSwitch.state = [d boolForKey:kShowMenuIcon] ? NSControlStateValueOn : NSControlStateValueOff;

    self.timeValue.stringValue = [NSString stringWithFormat:@"%ld ms", lround(self.timeSlider.doubleValue)];
    self.moveValue.stringValue = [NSString stringWithFormat:@"%ld%%",  lround(self.moveSlider.doubleValue)];
    self.timeSlider.enabled = self.moveSlider.enabled = tap;

    [self refreshStatus];
}

// ---- Actions -------------------------------------------------------------

- (void)setClick:(BOOL)v { atomic_store(&gClickOn, v); [NSUserDefaults.standardUserDefaults setBool:v forKey:kClickEnabled]; }
- (void)setTap:(BOOL)v   { atomic_store(&gTapOn, v);   [NSUserDefaults.standardUserDefaults setBool:v forKey:kTapEnabled]; }

- (void)menuToggleClick:(id)s { [self setClick:!atomic_load(&gClickOn)]; [self refreshUI]; }
- (void)menuToggleTap:(id)s   { [self setTap:!atomic_load(&gTapOn)];     [self refreshUI]; }

- (void)switchChanged:(NSSwitch *)s {
    BOOL on = s.state == NSControlStateValueOn;
    if (s == self.clickSwitch) [self setClick:on];
    else if (s == self.tapSwitch) [self setTap:on];
    else if (s == self.menuIconSwitch) {
        [NSUserDefaults.standardUserDefaults setBool:on forKey:kShowMenuIcon];
        self.statusItem.visible = on;
    }
    else if (s == self.loginSwitch) {
        SMAppService *svc = SMAppService.mainAppService;
        NSError *err = nil;
        if (on) [svc registerAndReturnError:&err]; else [svc unregisterAndReturnError:&err];
        if (err) {
            NSAlert *a = [NSAlert new];
            a.messageText = @"Couldn't change Launch at Login.";
            a.informativeText = [NSString stringWithFormat:@"%@\n\nYou can add MiddleTap manually in System Settings → General → Login Items.",
                                 err.localizedDescription];
            [a beginSheetModalForWindow:self.window completionHandler:nil];
        }
    }
    [self refreshUI];
}

- (void)sliderChanged:(NSSlider *)s {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (s == self.timeSlider) {
        long ms = lround(s.doubleValue);
        [d setInteger:ms forKey:kTapTimeMs];
        atomic_store(&gMaxTapDuration, ms / 1000.0);
    } else {
        long pct = lround(s.doubleValue);
        [d setInteger:pct forKey:kTapMovePct];
        atomic_store(&gMaxTapMovement, (float)(pct / 100.0));
    }
    [self refreshUI];
}

- (void)rescan:(id)s { [self startMultitouch]; }

- (void)openAccessibility:(id)s {
    [NSWorkspace.sharedWorkspace openURL:
        [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        static AppDelegate *delegate;   // NSApp holds its delegate weakly
        delegate = [AppDelegate new];
        app.delegate = delegate;
        app.activationPolicy = NSApplicationActivationPolicyAccessory; // no Dock icon
        [app run];
    }
    return 0;
}
