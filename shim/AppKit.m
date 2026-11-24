// AppKit 층: Unity 맥 플레이어가 쓰는 AppKit 클래스를 UIKit 위에 구현한다.
//
// Unity 맥 플레이어 흐름 (UnityPlayer.dylib class-dump + MainMenu.nib):
//   main -> PlayerMain -> NSApplicationMain
//   NSPrincipalClass = PlayerApplication (: NSApplication), MainMenu.nib 가 PlayerAppDelegate 를 만들어 delegate 로 연결
//   applicationDidFinishLaunching: -> PlayerWindow(: NSWindow) + 콘텐츠 뷰(+CAMetalLayer) 생성, NSTimer 로 UpdatePlayer
//   입력: [NSApp sendEvent:] -> PlayerApplication sendEvent: -> PlayerWindow sendEvent: -> first responder (UnicodeInputView keyDown:)
//
// 여기서는:
//   NSApplicationMain -> UIApplicationMain. UIKit 이 뜨면 PlayerApplication / PlayerAppDelegate 를 만들고 launching 알림을 보낸다.
//   NSWindow/NSView 는 하나의 전체화면 UIWindow 위 호스트 뷰에 CAMetalLayer 를 붙인다.
//   터치 / 하드웨어 키보드 -> NSEvent (맥 virtual key code) -> [NSApp sendEvent:]
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "Shim.h"

volatile uint8_t g_shimKeyDown[256];
volatile uint64_t g_shimModFlags;
volatile uint32_t g_shimMouseButtons;

id NSApp = nil;

// NSEventType / 수정키 플래그 (AppKit 값)
enum { kLDown = 1, kLUp = 2, kRDown = 3, kRUp = 4, kMouseMoved = 5, kLDrag = 6, kRDrag = 7, kKeyDown = 10, kKeyUp = 11,
       kFlagsChanged = 12, kAppDefined = 15, kScroll = 22 };
enum { kFlagCaps = 1 << 16, kFlagShift = 1 << 17, kFlagCtrl = 1 << 18, kFlagOpt = 1 << 19, kFlagCmd = 1 << 20 };
enum { kStyleTitled = 1, kStyleFullScreen = 1 << 14 };

// ---------------------------------------------------------------- 화면 정보
static ShimScreen g_screen = { 852, 393, 3, 120 };
ShimScreen ShimScreenInfo(void) { return g_screen; }
static UIWindow *g_uiWindow;
static UIView *g_host;

static void UpdateScreen(void) {   // 메인 스레드
    UIWindowScene *sc = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) sc = (UIWindowScene *)s;
    UIScreen *scr = sc.screen ?: UIScreen.mainScreen;
    CGRect b = g_host ? g_host.bounds : scr.bounds;
    double w = MAX(b.size.width, b.size.height), h = MIN(b.size.width, b.size.height);
    double scale = ShimCfgNum("BackingScale", scr.nativeScale);
    g_screen = (ShimScreen){ w, h, scale, (double)scr.maximumFramesPerSecond };
}

// ---------------------------------------------------------------- 기반: 모르는 셀렉터 -> 로그 + 0
@interface ShimBase : NSObject @end
@implementation ShimBase
static void LogMissing(id self, SEL sel, BOOL cls) {
    char k[256];
    snprintf(k, sizeof k, "%c[%s %s]", cls ? '+' : '-', class_getName(cls ? (Class)self : object_getClass(self)), sel_getName(sel));
    ShimLogOnce(k, "AppKit: unimplemented %s", k);
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [super methodSignatureForSelector:sel] ?: [NSMethodSignature signatureWithObjCTypes:"q@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    LogMissing(self, inv.selector, NO);
    char z[64] = {0};
    if (inv.methodSignature.methodReturnLength && inv.methodSignature.methodReturnLength <= sizeof z) [inv setReturnValue:z];
}
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [super methodSignatureForSelector:sel] ?: [NSMethodSignature signatureWithObjCTypes:"q@:"];
}
+ (void)forwardInvocation:(NSInvocation *)inv {
    LogMissing(self, inv.selector, YES);
    char z[64] = {0};
    if (inv.methodSignature.methodReturnLength && inv.methodSignature.methodReturnLength <= sizeof z) [inv setReturnValue:z];
}
@end

@interface NSResponder : ShimBase
@property(nonatomic, weak) id nextResponder;
@end
@implementation NSResponder
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)becomeFirstResponder { return YES; }
- (BOOL)resignFirstResponder { return YES; }
- (void)keyDown:(id)e { [self.nextResponder keyDown:e]; }
- (void)keyUp:(id)e { [self.nextResponder keyUp:e]; }
- (void)flagsChanged:(id)e { [self.nextResponder flagsChanged:e]; }
- (void)mouseDown:(id)e {} - (void)mouseUp:(id)e {} - (void)mouseMoved:(id)e {} - (void)mouseDragged:(id)e {}
- (void)rightMouseDown:(id)e {} - (void)rightMouseUp:(id)e {} - (void)rightMouseDragged:(id)e {}
- (void)otherMouseDown:(id)e {} - (void)otherMouseUp:(id)e {} - (void)otherMouseDragged:(id)e {}
- (void)scrollWheel:(id)e {} - (void)mouseEntered:(id)e {} - (void)mouseExited:(id)e {}
- (void)interpretKeyEvents:(NSArray *)events {
    // 텍스트 입력: insertText: 로 문자 전달 (IME 없음)
    for (id e in events) {
        NSString *s = [e characters];
        if (s.length && [self respondsToSelector:@selector(insertText:)]) [(id)self insertText:s];
    }
}
- (void)doCommandBySelector:(SEL)s {}
@end

// ---------------------------------------------------------------- NSScreen
@interface NSScreen : ShimBase @end
@implementation NSScreen
+ (instancetype)mainScreen { static NSScreen *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [NSScreen new]; }); return s; }
+ (NSArray *)screens { return @[ [self mainScreen] ]; }
+ (instancetype)deepestScreen { return [self mainScreen]; }
- (CGRect)frame { ShimScreen s = ShimScreenInfo(); return CGRectMake(0, 0, s.w, s.h); }
- (CGRect)visibleFrame { return self.frame; }
- (CGFloat)backingScaleFactor { return ShimScreenInfo().scale; }
- (NSInteger)maximumFramesPerSecond { return (NSInteger)ShimScreenInfo().maxFPS; }
- (double)minimumRefreshInterval { return 1.0 / ShimScreenInfo().maxFPS; }
- (double)maximumRefreshInterval { return 1.0 / 60; }
- (CGFloat)maximumExtendedDynamicRangeColorComponentValue { return 1; }
- (CGFloat)maximumPotentialExtendedDynamicRangeColorComponentValue { return 1; }
- (CGFloat)maximumReferenceExtendedDynamicRangeColorComponentValue { return 0; }
- (UIEdgeInsets)safeAreaInsets { return UIEdgeInsetsZero; }   // NSEdgeInsets 와 같은 배치 (top,left,bottom,right)
- (NSString *)localizedName { return @"iPhone Display"; }
- (BOOL)canRepresentDisplayGamut:(NSInteger)g { return YES; }
- (id)colorSpace { return nil; }
- (NSDictionary *)deviceDescription {
    ShimScreen s = ShimScreenInfo();
    return @{ @"NSScreenNumber": @1u, @"NSDeviceSize": [NSValue valueWithCGSize:CGSizeMake(s.w, s.h)],
              @"NSDeviceResolution": [NSValue valueWithCGSize:CGSizeMake(72 * s.scale, 72 * s.scale)],
              @"NSDeviceIsScreen": @"YES", @"NSDeviceBitsPerSample": @8 };
}
@end

// ---------------------------------------------------------------- NSEvent
@interface NSEvent : ShimBase
@property(nonatomic) NSUInteger type, modifierFlags;
@property(nonatomic) NSInteger buttonNumber, clickCount, subtype;
@property(nonatomic) CGPoint locationInWindow;
@property(nonatomic) unsigned short keyCode;
@property(nonatomic) CGFloat deltaX, deltaY, deltaZ, scrollingDeltaX, scrollingDeltaY;
@property(nonatomic) float pressure;
@property(nonatomic) BOOL hasPreciseScrollingDeltas, isARepeat;
@property(nonatomic) NSTimeInterval timestamp;
@property(nonatomic, copy) NSString *characters, *charactersIgnoringModifiers;
@property(nonatomic, weak) id window;
@end
@implementation NSEvent
static CGPoint g_mouse;   // 맥 좌표 (왼쪽 아래 원점, 포인트)
+ (CGPoint)mouseLocation { return g_mouse; }
+ (NSUInteger)modifierFlags { return (NSUInteger)g_shimModFlags; }
+ (NSUInteger)pressedMouseButtons { return g_shimMouseButtons; }
+ (double)keyRepeatDelay { return 0.5; }
+ (double)keyRepeatInterval { return 0.05; }
+ (double)doubleClickInterval { return 0.3; }
+ (void)setMouseCoalescingEnabled:(BOOL)b {}
+ (BOOL)isMouseCoalescingEnabled { return NO; }
+ (id)eventWithCGEvent:(void *)e { return nil; }
+ (id)addLocalMonitorForEventsMatchingMask:(unsigned long long)m handler:(id)h { ShimLog("AppKit: addLocalMonitorForEventsMatchingMask %llx (ignored)", m); return [NSObject new]; }
+ (id)addGlobalMonitorForEventsMatchingMask:(unsigned long long)m handler:(id)h { return [NSObject new]; }
+ (void)removeMonitor:(id)m {}
- (NSInteger)windowNumber { return 1; }
- (NSInteger)eventNumber { return 0; }
- (NSUInteger)pointingDeviceType { return 0; }
- (CGPoint)tilt { return CGPointZero; }
- (float)rotation { return 0; }
- (BOOL)isEnteringProximity { return NO; }
- (NSUInteger)phase { return 0; }
- (NSUInteger)momentumPhase { return 0; }
- (BOOL)isDirectionInvertedFromDevice { return NO; }
- (void *)CGEvent { return NULL; }
- (id)context { return nil; }
- (NSUInteger)specialKey { return 0; }
- (NSString *)charactersByApplyingModifiers:(NSUInteger)m { return self.characters; }
@end

// ---------------------------------------------------------------- 키 코드 표
// GCKeyCode(USB HID usage) -> 맥 virtual key code, 그리고 맥 key code -> 문자 (US 배열; 소문자, 대문자)
static NSDictionary *HIDToMac(void) {
    static NSDictionary *m; static dispatch_once_t o;
    dispatch_once(&o, ^{ m = @{
        @(GCKeyCodeKeyA.integerValue):@0, @(GCKeyCodeKeyS.integerValue):@1, @(GCKeyCodeKeyD.integerValue):@2, @(GCKeyCodeKeyF.integerValue):@3,
        @(GCKeyCodeKeyH.integerValue):@4, @(GCKeyCodeKeyG.integerValue):@5, @(GCKeyCodeKeyZ.integerValue):@6, @(GCKeyCodeKeyX.integerValue):@7,
        @(GCKeyCodeKeyC.integerValue):@8, @(GCKeyCodeKeyV.integerValue):@9, @(GCKeyCodeKeyB.integerValue):@11, @(GCKeyCodeKeyQ.integerValue):@12,
        @(GCKeyCodeKeyW.integerValue):@13, @(GCKeyCodeKeyE.integerValue):@14, @(GCKeyCodeKeyR.integerValue):@15, @(GCKeyCodeKeyY.integerValue):@16,
        @(GCKeyCodeKeyT.integerValue):@17, @(GCKeyCodeOne.integerValue):@18, @(GCKeyCodeTwo.integerValue):@19, @(GCKeyCodeThree.integerValue):@20,
        @(GCKeyCodeFour.integerValue):@21, @(GCKeyCodeSix.integerValue):@22, @(GCKeyCodeFive.integerValue):@23, @(GCKeyCodeEqualSign.integerValue):@24,
        @(GCKeyCodeNine.integerValue):@25, @(GCKeyCodeSeven.integerValue):@26, @(GCKeyCodeHyphen.integerValue):@27, @(GCKeyCodeEight.integerValue):@28,
        @(GCKeyCodeZero.integerValue):@29, @(GCKeyCodeCloseBracket.integerValue):@30, @(GCKeyCodeKeyO.integerValue):@31, @(GCKeyCodeKeyU.integerValue):@32,
        @(GCKeyCodeOpenBracket.integerValue):@33, @(GCKeyCodeKeyI.integerValue):@34, @(GCKeyCodeKeyP.integerValue):@35, @(GCKeyCodeReturnOrEnter.integerValue):@36,
        @(GCKeyCodeKeyL.integerValue):@37, @(GCKeyCodeKeyJ.integerValue):@38, @(GCKeyCodeQuote.integerValue):@39, @(GCKeyCodeKeyK.integerValue):@40,
        @(GCKeyCodeSemicolon.integerValue):@41, @(GCKeyCodeBackslash.integerValue):@42, @(GCKeyCodeComma.integerValue):@43, @(GCKeyCodeSlash.integerValue):@44,
        @(GCKeyCodeKeyN.integerValue):@45, @(GCKeyCodeKeyM.integerValue):@46, @(GCKeyCodePeriod.integerValue):@47, @(GCKeyCodeTab.integerValue):@48,
        @(GCKeyCodeSpacebar.integerValue):@49, @(GCKeyCodeGraveAccentAndTilde.integerValue):@50, @(GCKeyCodeDeleteOrBackspace.integerValue):@51,
        @(GCKeyCodeEscape.integerValue):@53, @(GCKeyCodeRightGUI.integerValue):@54, @(GCKeyCodeLeftGUI.integerValue):@55, @(GCKeyCodeLeftShift.integerValue):@56,
        @(GCKeyCodeCapsLock.integerValue):@57, @(GCKeyCodeLeftAlt.integerValue):@58, @(GCKeyCodeLeftControl.integerValue):@59, @(GCKeyCodeRightShift.integerValue):@60,
        @(GCKeyCodeRightAlt.integerValue):@61, @(GCKeyCodeRightControl.integerValue):@62,
        @(GCKeyCodeF1.integerValue):@122, @(GCKeyCodeF2.integerValue):@120, @(GCKeyCodeF3.integerValue):@99, @(GCKeyCodeF4.integerValue):@118,
        @(GCKeyCodeF5.integerValue):@96, @(GCKeyCodeF6.integerValue):@97, @(GCKeyCodeF7.integerValue):@98, @(GCKeyCodeF8.integerValue):@100,
        @(GCKeyCodeF9.integerValue):@101, @(GCKeyCodeF10.integerValue):@109, @(GCKeyCodeF11.integerValue):@103, @(GCKeyCodeF12.integerValue):@111,
        @(GCKeyCodeHome.integerValue):@115, @(GCKeyCodePageUp.integerValue):@116, @(GCKeyCodeDeleteForward.integerValue):@117, @(GCKeyCodeEnd.integerValue):@119,
        @(GCKeyCodePageDown.integerValue):@121, @(GCKeyCodeLeftArrow.integerValue):@123, @(GCKeyCodeRightArrow.integerValue):@124,
        @(GCKeyCodeDownArrow.integerValue):@125, @(GCKeyCodeUpArrow.integerValue):@126,
        @(GCKeyCodeKeypadEnter.integerValue):@76, @(GCKeyCodeKeypadPeriod.integerValue):@65, @(GCKeyCodeKeypadAsterisk.integerValue):@67,
        @(GCKeyCodeKeypadPlus.integerValue):@69, @(GCKeyCodeKeypadHyphen.integerValue):@78, @(GCKeyCodeKeypadSlash.integerValue):@75,
        @(GCKeyCodeKeypad0.integerValue):@82, @(GCKeyCodeKeypad1.integerValue):@83, @(GCKeyCodeKeypad2.integerValue):@84, @(GCKeyCodeKeypad3.integerValue):@85,
        @(GCKeyCodeKeypad4.integerValue):@86, @(GCKeyCodeKeypad5.integerValue):@87, @(GCKeyCodeKeypad6.integerValue):@88, @(GCKeyCodeKeypad7.integerValue):@89,
        @(GCKeyCodeKeypad8.integerValue):@91, @(GCKeyCodeKeypad9.integerValue):@92,
    }; });
    return m;
}

// 맥 key code -> US 배열 문자 {보통, shift}. Stubs.c 의 UCKeyTranslate 도 쓴다.
const char *ShimMacKeyChars(unsigned code, bool shift) {
    static const char *lo[128] = {
        [0]="a",[1]="s",[2]="d",[3]="f",[4]="h",[5]="g",[6]="z",[7]="x",[8]="c",[9]="v",[11]="b",[12]="q",[13]="w",[14]="e",[15]="r",
        [16]="y",[17]="t",[18]="1",[19]="2",[20]="3",[21]="4",[22]="6",[23]="5",[24]="=",[25]="9",[26]="7",[27]="-",[28]="8",[29]="0",
        [30]="]",[31]="o",[32]="u",[33]="[",[34]="i",[35]="p",[36]="\r",[37]="l",[38]="j",[39]="'",[40]="k",[41]=";",[42]="\\",[43]=",",
        [44]="/",[45]="n",[46]="m",[47]=".",[48]="\t",[49]=" ",[50]="`",[51]="\x7f",[53]="\x1b",[76]="\x03",[65]=".",[67]="*",[69]="+",
        [78]="-",[75]="/",[82]="0",[83]="1",[84]="2",[85]="3",[86]="4",[87]="5",[88]="6",[89]="7",[91]="8",[92]="9" };
    static const char *up[128] = {
        [0]="A",[1]="S",[2]="D",[3]="F",[4]="H",[5]="G",[6]="Z",[7]="X",[8]="C",[9]="V",[11]="B",[12]="Q",[13]="W",[14]="E",[15]="R",
        [16]="Y",[17]="T",[18]="!",[19]="@",[20]="#",[21]="$",[22]="^",[23]="%",[24]="+",[25]="(",[26]="&",[27]="_",[28]="*",[29]=")",
        [30]="}",[31]="O",[32]="U",[33]="{",[34]="I",[35]="P",[37]="L",[38]="J",[39]="\"",[40]="K",[41]=":",[42]="|",[43]="<",
        [44]="?",[45]="N",[46]="M",[47]=">",[50]="~" };
    if (code >= 128) return "";
    const char *s = shift && up[code] ? up[code] : lo[code];
    return s ?: "";
}

static NSString *FunctionKeyChar(unsigned code) {
    unichar c = 0;
    switch (code) {
        case 123: c = 0xF702; break; case 124: c = 0xF703; break; case 125: c = 0xF701; break; case 126: c = 0xF700; break;
        case 122: c = 0xF704; break; case 120: c = 0xF705; break; case 99: c = 0xF706; break; case 118: c = 0xF707; break;
        case 96: c = 0xF708; break; case 97: c = 0xF709; break; case 98: c = 0xF70A; break; case 100: c = 0xF70B; break;
        case 101: c = 0xF70C; break; case 109: c = 0xF70D; break; case 103: c = 0xF70E; break; case 111: c = 0xF70F; break;
        case 115: c = 0xF729; break; case 119: c = 0xF72B; break; case 116: c = 0xF72C; break; case 121: c = 0xF72D; break;
        case 117: c = 0xF728; break;
    }
    return c ? [NSString stringWithCharacters:&c length:1] : nil;
}

static uint64_t FlagForKey(unsigned k) {
    switch (k) { case 56: case 60: return kFlagShift; case 59: case 62: return kFlagCtrl; case 58: case 61: return kFlagOpt;
                 case 55: case 54: return kFlagCmd; case 57: return kFlagCaps; default: return 0; }
}

// ---------------------------------------------------------------- NSView
@class NSWindow;
@interface NSView : NSResponder
@property(nonatomic) CGRect frame, bounds;
@property(nonatomic, strong) CALayer *layer;
@property(nonatomic) BOOL wantsLayer;
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, weak) NSView *superview;
@property(nonatomic, strong) NSMutableArray *subviews;
@end

static void HostLayer(CALayer *l) {
    if (!l) return;
    dispatch_block_t b = ^{
        if (!g_host) { ShimLog("AppKit: layer set before host view exists"); return; }
        if (l.superlayer != g_host.layer) [g_host.layer addSublayer:l];
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        l.frame = g_host.bounds;
        [CATransaction commit];
        ShimLog("AppKit: hosting %s frame %.0fx%.0f contentsScale %.2f", object_getClassName(l), l.frame.size.width, l.frame.size.height, l.contentsScale);
    };
    if ([NSThread isMainThread]) b(); else dispatch_async(dispatch_get_main_queue(), b);
}

@implementation NSView
- (instancetype)init { return [self initWithFrame:CGRectZero]; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super init])) { ShimScreen s = ShimScreenInfo(); _frame = CGRectMake(0, 0, s.w, s.h); _bounds = _frame; _subviews = [NSMutableArray array]; }
    return self;
}
- (void)setFrame:(CGRect)f { /* 항상 전체화면 */ }
- (void)setFrameSize:(CGSize)s {}
- (void)setFrameOrigin:(CGPoint)p {}
- (void)setBounds:(CGRect)b {}
- (CGRect)frame { ShimScreen s = ShimScreenInfo(); return CGRectMake(0, 0, s.w, s.h); }
- (CGRect)bounds { return self.frame; }
- (CGRect)visibleRect { return self.frame; }
- (void)setLayer:(CALayer *)l { _layer = l; ShimLog("AppKit: [%s setLayer:%s]", object_getClassName(self), object_getClassName(l)); HostLayer(l); }
- (CALayer *)makeBackingLayer { return [CALayer layer]; }
- (void)setWantsLayer:(BOOL)w { _wantsLayer = w; }
- (void)setLayerContentsRedrawPolicy:(NSInteger)p {}
- (void)setLayerContentsPlacement:(NSInteger)p {}
- (void)setWantsBestResolutionOpenGLSurface:(BOOL)b {}
- (void)setWantsExtendedDynamicRangeOpenGLSurface:(BOOL)b {}
- (void)setAutoresizingMask:(NSUInteger)m {}
- (void)setAutoresizesSubviews:(BOOL)b {}
- (void)setPostsFrameChangedNotifications:(BOOL)b {}
- (void)setNeedsDisplay:(BOOL)b {}
- (void)setHidden:(BOOL)h {}
- (BOOL)isHidden { return NO; }
- (BOOL)isFlipped { return NO; }
- (BOOL)isOpaque { return YES; }
- (BOOL)inLiveResize { return NO; }
- (void)addSubview:(NSView *)v { if (!v) return; [_subviews addObject:v]; v.superview = self; v.window = self.window; v.nextResponder = self; if (v.layer) HostLayer(v.layer); }
- (void)addSubview:(NSView *)v positioned:(NSInteger)p relativeTo:(id)o { [self addSubview:v]; }
- (void)removeFromSuperview { [self.superview.subviews removeObject:self]; self.superview = nil; }
- (NSView *)hitTest:(CGPoint)p { return self; }
- (BOOL)mouse:(CGPoint)p inRect:(CGRect)r { return CGRectContainsPoint(r, p); }
- (CGPoint)convertPoint:(CGPoint)p fromView:(id)v { return p; }
- (CGPoint)convertPoint:(CGPoint)p toView:(id)v { return p; }
- (CGRect)convertRect:(CGRect)r fromView:(id)v { return r; }
- (CGRect)convertRect:(CGRect)r toView:(id)v { return r; }
- (CGRect)convertRectToBacking:(CGRect)r { double k = ShimScreenInfo().scale; return CGRectMake(r.origin.x * k, r.origin.y * k, r.size.width * k, r.size.height * k); }
- (CGRect)convertRectFromBacking:(CGRect)r { double k = ShimScreenInfo().scale; return CGRectMake(r.origin.x / k, r.origin.y / k, r.size.width / k, r.size.height / k); }
- (CGSize)convertSizeToBacking:(CGSize)s { double k = ShimScreenInfo().scale; return CGSizeMake(s.width * k, s.height * k); }
- (CGPoint)convertPointToBacking:(CGPoint)p { double k = ShimScreenInfo().scale; return CGPointMake(p.x * k, p.y * k); }
- (void)addTrackingArea:(id)a {}
- (void)removeTrackingArea:(id)a {}
- (NSArray *)trackingAreas { return @[]; }
- (void)updateTrackingAreas {}
- (void)addCursorRect:(CGRect)r cursor:(id)c {}
- (void)discardCursorRects {}
- (void)resetCursorRects {}
- (void)lockFocus {} - (void)unlockFocus {}
- (void)registerForDraggedTypes:(NSArray *)t {}
- (id)inputContext { return nil; }
- (void)setAccessibilityElement:(BOOL)b {} - (void)setAccessibilityChildren:(NSArray *)c {}
- (NSArray *)accessibilityChildren { return @[]; }
@end

// ---------------------------------------------------------------- NSViewController (GameCenter 래퍼용)
@interface NSViewController : NSResponder @property(nonatomic, strong) NSView *view; @end
@implementation NSViewController
- (void)presentViewController:(id)vc {} - (void)dismissViewController:(id)vc {} - (void)dismiss:(id)s {}
- (void)presentViewControllerAsSheet:(id)vc {} - (void)presentViewControllerAsModalWindow:(id)vc {}
@end

// ---------------------------------------------------------------- NSWindow
@interface NSWindow : NSResponder
@property(nonatomic, strong) NSView *contentView;
@property(nonatomic, weak) id delegate;
@property(nonatomic, weak) NSResponder *firstResponder;
@property(nonatomic) NSUInteger styleMask, collectionBehavior;
@property(nonatomic) NSInteger level;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, strong) id backgroundColor;
@property(nonatomic) BOOL opaque, acceptsMouseMovedEvents, ignoresMouseEvents, hasShadow, releasedWhenClosed;
@end
static __weak NSWindow *g_window;   // 게임 창 (보통 하나)

@implementation NSWindow
- (instancetype)initWithContentRect:(CGRect)r styleMask:(NSUInteger)m backing:(NSUInteger)b defer:(BOOL)d {
    if ((self = [super init])) {
        _styleMask = m | kStyleFullScreen;
        ShimLog("AppKit: %s initWithContentRect %.0fx%.0f style %lx", object_getClassName(self), r.size.width, r.size.height, (unsigned long)m);
        if (!g_window) g_window = self;
    }
    return self;
}
- (instancetype)initWithContentRect:(CGRect)r styleMask:(NSUInteger)m backing:(NSUInteger)b defer:(BOOL)d screen:(id)s {
    return [self initWithContentRect:r styleMask:m backing:b defer:d];
}
- (void)setContentView:(NSView *)v {
    _contentView = v; v.window = self; v.nextResponder = self;
    if (!_firstResponder) _firstResponder = v;
    ShimLog("AppKit: [%s setContentView:%s]", object_getClassName(self), object_getClassName(v));
    if (v.layer) HostLayer(v.layer);
}
- (void)setStyleMask:(NSUInteger)m { _styleMask = m | kStyleFullScreen; }
- (CGRect)frame { ShimScreen s = ShimScreenInfo(); return CGRectMake(0, 0, s.w, s.h); }
- (CGRect)contentLayoutRect { return self.frame; }
- (void)setFrame:(CGRect)f display:(BOOL)d { ShimLogOnce("setFrame", "AppKit: setFrame %.0fx%.0f (ignored: always fullscreen)", f.size.width, f.size.height); }
- (void)setFrame:(CGRect)f display:(BOOL)d animate:(BOOL)a { [self setFrame:f display:d]; }
- (void)setFrameOrigin:(CGPoint)p {} - (void)setFrameTopLeftPoint:(CGPoint)p {}
- (void)setContentSize:(CGSize)s {} - (void)setContentMinSize:(CGSize)s {} - (void)setContentMaxSize:(CGSize)s {}
- (void)setMinSize:(CGSize)s {} - (void)setMaxSize:(CGSize)s {} - (void)setContentAspectRatio:(CGSize)s {}
- (void)setContentResizeIncrements:(CGSize)s {} - (void)center {}
- (CGRect)contentRectForFrameRect:(CGRect)r { return r; }
- (CGRect)frameRectForContentRect:(CGRect)r { return r; }
+ (CGRect)frameRectForContentRect:(CGRect)r styleMask:(NSUInteger)m { return r; }
+ (CGRect)contentRectForFrameRect:(CGRect)r styleMask:(NSUInteger)m { return r; }
- (CGRect)convertRectToScreen:(CGRect)r { return r; }
- (CGRect)convertRectFromScreen:(CGRect)r { return r; }
- (CGPoint)convertPointToScreen:(CGPoint)p { return p; }
- (CGPoint)convertPointFromScreen:(CGPoint)p { return p; }
- (CGRect)convertRectToBacking:(CGRect)r { return [_contentView convertRectToBacking:r]; }
- (CGPoint)mouseLocationOutsideOfEventStream { return g_mouse; }
- (NSScreen *)screen { return [NSScreen mainScreen]; }
- (NSScreen *)deepestScreen { return [NSScreen mainScreen]; }
- (CGFloat)backingScaleFactor { return ShimScreenInfo().scale; }
- (BOOL)makeFirstResponder:(NSResponder *)r { _firstResponder = r ?: (NSResponder *)self; [r becomeFirstResponder]; return YES; }
- (void)makeKeyAndOrderFront:(id)s { ShimLog("AppKit: makeKeyAndOrderFront"); }
- (void)makeKeyWindow {} - (void)makeMainWindow {} - (void)orderFront:(id)s {} - (void)orderOut:(id)s {} - (void)orderFrontRegardless {}
- (void)orderBack:(id)s {} - (void)display {} - (void)close {} - (void)performClose:(id)s {} - (void)miniaturize:(id)s {}
- (void)deminiaturize:(id)s {} - (void)setParentWindow:(id)w {} - (void)setMovable:(BOOL)b {} - (void)setMovableByWindowBackground:(BOOL)b {}
- (void)setRestorable:(BOOL)b {} - (void)setTabbingMode:(NSInteger)m {} - (void)setColorSpace:(id)c {} - (void)setDisplaysWhenScreenProfileChanges:(BOOL)b {}
- (void)setAnimationBehavior:(NSInteger)b {} - (void)setSharingType:(NSUInteger)t {} - (void)invalidateCursorRectsForView:(id)v {}
- (void)setAlphaValue:(CGFloat)a {} - (void)setHidesOnDeactivate:(BOOL)b {} - (void)setTitleVisibility:(NSInteger)v {}
- (void)setTitlebarAppearsTransparent:(BOOL)b {} - (void)setStyleMaskNoChange:(id)x {} - (void)setShowsResizeIndicator:(BOOL)b {}
- (void)toggleFullScreen:(id)s { ShimLog("AppKit: toggleFullScreen (already fullscreen)"); }
- (BOOL)isKeyWindow { return YES; } - (BOOL)isMainWindow { return YES; } - (BOOL)isVisible { return YES; }
- (BOOL)isMiniaturized { return NO; } - (BOOL)isZoomed { return NO; } - (BOOL)inLiveResize { return NO; }
- (BOOL)isOnActiveSpace { return YES; } - (BOOL)canBecomeKeyWindow { return YES; } - (BOOL)canBecomeMainWindow { return YES; }
- (id)attachedSheet { return nil; }
- (NSUInteger)occlusionState { return 1 << 1; /* NSWindowOcclusionStateVisible */ }
- (NSInteger)windowNumber { return 1; }
- (id)standardWindowButton:(NSInteger)b { return nil; }
- (id)windowController { return nil; }
- (id)tabbingIdentifier { return @""; }
- (void)sendEvent:(NSEvent *)e {
    switch (e.type) {
        case kKeyDown: [(id)(_firstResponder ?: _contentView) keyDown:e]; break;
        case kKeyUp: [(id)(_firstResponder ?: _contentView) keyUp:e]; break;
        case kFlagsChanged: [(id)(_firstResponder ?: _contentView) flagsChanged:e]; break;
        case kLDown: [_contentView mouseDown:e]; break;
        case kLUp: [_contentView mouseUp:e]; break;
        case kLDrag: [_contentView mouseDragged:e]; break;
        case kRDown: [_contentView rightMouseDown:e]; break;
        case kRUp: [_contentView rightMouseUp:e]; break;
        case kMouseMoved: [_contentView mouseMoved:e]; break;
        case kScroll: [_contentView scrollWheel:e]; break;
    }
}
@end

// ---------------------------------------------------------------- NSApplication
@interface NSApplication : NSResponder
@property(nonatomic, weak) id delegate;
@property(nonatomic) NSUInteger presentationOptions;
@property(nonatomic, strong) id mainMenu;
@end
static BOOL g_uikitUp, g_active = YES, g_launched;
static int g_argc; static char **g_argv;
static void StartUIKit(void);

@implementation NSApplication
+ (instancetype)sharedApplication {
    if (!NSApp) { NSApp = [[self alloc] init]; ShimLog("AppKit: NSApp = %s", object_getClassName(NSApp)); }
    return NSApp;
}
- (void)setDelegate:(id)d { _delegate = d; ShimLog("AppKit: NSApp delegate = %s", object_getClassName(d)); }
- (void)run { ShimLog("AppKit: [NSApp run]"); StartUIKit(); }
- (void)finishLaunching {}
- (void)stop:(id)s {} - (void)terminate:(id)s { ShimLog("AppKit: terminate: -> exit(0)"); exit(0); }
- (void)replyToApplicationShouldTerminate:(BOOL)b {}
- (BOOL)isActive { return g_active; }
- (BOOL)isRunning { return g_launched; }
- (BOOL)isHidden { return !g_active; }
- (void)activateIgnoringOtherApps:(BOOL)b {} - (void)activate {} - (void)deactivate {}
- (BOOL)setActivationPolicy:(NSInteger)p { return YES; }
- (NSInteger)activationPolicy { return 0; }
- (void)hide:(id)s {} - (void)unhide:(id)s {} - (void)unhideWithoutActivation {}
- (id)mainWindow { return g_window; }
- (id)keyWindow { return g_window; }
- (NSArray *)windows { return g_window ? @[ g_window ] : @[]; }
- (id)currentEvent { return nil; }
- (NSUInteger)occlusionState { return 1 << 1; }
- (void)sendEvent:(NSEvent *)e { [(id)(e.window ?: g_window) sendEvent:e]; }
- (void)postEvent:(NSEvent *)e atStart:(BOOL)s { [self sendEvent:e]; }
- (id)nextEventMatchingMask:(unsigned long long)m untilDate:(id)d inMode:(id)mode dequeue:(BOOL)dq { return nil; }
- (void)discardEventsMatchingMask:(unsigned long long)m beforeEvent:(id)e {}
- (void)setWindowsMenu:(id)m {} - (void)setServicesMenu:(id)m {} - (void)setHelpMenu:(id)m {}
- (void)setAppearance:(id)a {} - (id)effectiveAppearance { return nil; }
- (void)requestUserAttention:(NSInteger)t {} - (void)setApplicationIconImage:(id)i {}
- (id)dockTile { return nil; }
- (void)registerForRemoteNotifications {} - (void)setAutomaticCustomizeTouchBarMenuItemEnabled:(BOOL)b {}
+ (void)setAllowsAutomaticWindowTabbing:(BOOL)b {}
- (CGFloat)menuBarHeight { return 0; }
@end

// ---------------------------------------------------------------- 그 밖의 AppKit 클래스
@interface NSCursor : ShimBase @end
@implementation NSCursor
+ (instancetype)arrowCursor { static NSCursor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = [NSCursor new]; }); return c; }
+ (instancetype)currentCursor { return [self arrowCursor]; }
+ (instancetype)IBeamCursor { return [self arrowCursor]; }
+ (instancetype)pointingHandCursor { return [self arrowCursor]; }
+ (void)hide {} + (void)unhide {} + (void)setHiddenUntilMouseMoves:(BOOL)b {}
- (instancetype)initWithImage:(id)i hotSpot:(CGPoint)p { return [super init]; }
- (void)set {} - (void)push {} - (void)pop {}
@end

@interface NSTrackingArea : ShimBase @end
@implementation NSTrackingArea
- (instancetype)initWithRect:(CGRect)r options:(NSUInteger)o owner:(id)ow userInfo:(NSDictionary *)u { return [super init]; }
@end

@interface NSImage : ShimBase @end
@implementation NSImage
- (instancetype)initWithSize:(CGSize)s { return [super init]; }
- (instancetype)initWithContentsOfFile:(NSString *)p { return [super init]; }
- (instancetype)initWithData:(NSData *)d { return [super init]; }
- (void)addRepresentation:(id)r {} - (void)lockFocus {} - (void)unlockFocus {}
- (CGSize)size { return CGSizeZero; }
@end

@interface NSBitmapImageRep : ShimBase { NSMutableData *_data; } @end
@implementation NSBitmapImageRep
- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes pixelsWide:(NSInteger)w pixelsHigh:(NSInteger)h bitsPerSample:(NSInteger)bps
                         samplesPerPixel:(NSInteger)spp hasAlpha:(BOOL)a isPlanar:(BOOL)p colorSpaceName:(id)c bitmapFormat:(NSUInteger)f
                             bytesPerRow:(NSInteger)bpr bitsPerPixel:(NSInteger)bpp {
    if ((self = [super init])) { NSInteger row = bpr ?: w * spp * bps / 8; _data = [NSMutableData dataWithLength:(NSUInteger)(row * h)]; }
    return self;
}
- (instancetype)initWithFocusedViewRect:(CGRect)r { return [super init]; }
- (unsigned char *)bitmapData { return _data.mutableBytes; }
- (NSData *)representationUsingType:(NSUInteger)t properties:(NSDictionary *)p { return nil; }
@end

@interface NSColor : ShimBase @end
@implementation NSColor
+ (instancetype)blackColor { return [self new]; } + (instancetype)clearColor { return [self new]; } + (instancetype)whiteColor { return [self new]; }
+ (instancetype)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [self new]; }
- (CGColorRef)CGColor { return NULL; }
@end

@interface NSPasteboard : ShimBase @end
@implementation NSPasteboard
+ (instancetype)generalPasteboard { return [self new]; }
- (NSInteger)declareTypes:(NSArray *)t owner:(id)o { return 0; }
- (NSInteger)clearContents { return 0; }
- (BOOL)setString:(NSString *)s forType:(NSString *)t { UIPasteboard.generalPasteboard.string = s; return YES; }
- (NSString *)stringForType:(NSString *)t { return UIPasteboard.generalPasteboard.string; }
@end

@interface NSWorkspace : ShimBase @end
@implementation NSWorkspace
+ (instancetype)sharedWorkspace { static NSWorkspace *w; static dispatch_once_t o; dispatch_once(&o, ^{ w = [NSWorkspace new]; }); return w; }
- (BOOL)openURL:(NSURL *)u {
    ShimLog("AppKit: openURL %s", u.absoluteString.UTF8String);
    dispatch_async(dispatch_get_main_queue(), ^{ [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil]; });
    return YES;
}
- (BOOL)selectFile:(NSString *)f inFileViewerRootedAtPath:(NSString *)r { return NO; }
- (NSNotificationCenter *)notificationCenter { return [NSNotificationCenter defaultCenter]; }
- (BOOL)accessibilityDisplayShouldReduceMotion { return NO; }
- (BOOL)isVoiceOverEnabled { return NO; }
- (NSArray *)runningApplications { return @[]; }
@end

@interface NSInputManager : ShimBase @end
@implementation NSInputManager + (id)currentInputManager { return nil; } @end

@interface NSOpenGLContext : ShimBase @end
@implementation NSOpenGLContext
- (instancetype)initWithCGLContextObj:(void *)c { return [super init]; }
+ (void)clearCurrentContext {}
@end

@interface NSAccessibilityElement : ShimBase @end
@implementation NSAccessibilityElement
- (BOOL)isAccessibilityElement { return NO; }
- (BOOL)isAccessibilitySelected { return NO; }
- (id)accessibilityParent { return nil; }
- (NSArray *)accessibilityChildren { return @[]; }
- (NSString *)accessibilityRole { return @""; }
@end

@interface NSAppleEventManager : ShimBase @end
@implementation NSAppleEventManager
+ (instancetype)sharedAppleEventManager { static NSAppleEventManager *m; static dispatch_once_t o; dispatch_once(&o, ^{ m = [NSAppleEventManager new]; }); return m; }
- (void)setEventHandler:(id)h andSelector:(SEL)s forEventClass:(uint32_t)c andEventID:(uint32_t)i {}
- (void)removeEventHandlerForEventClass:(uint32_t)c andEventID:(uint32_t)i {}
@end

@interface NSMenu : ShimBase @end
@implementation NSMenu + (void)setMenuBarVisible:(BOOL)v {} + (BOOL)menuBarVisible { return NO; } + (CGFloat)menuBarHeight { return 0; } @end

// ---------------------------------------------------------------- 상수 / C 함수
NSString *const NSApplicationDidBecomeActiveNotification = @"NSApplicationDidBecomeActiveNotification";
NSString *const NSApplicationDidChangeScreenParametersNotification = @"NSApplicationDidChangeScreenParametersNotification";
NSString *const NSWindowDidMoveNotification = @"NSWindowDidMoveNotification";
NSString *const NSWindowDidResizeNotification = @"NSWindowDidResizeNotification";
NSString *const NSTextInputContextKeyboardSelectionDidChangeNotification = @"NSTextInputContextKeyboardSelectionDidChangeNotification";
NSString *const NSCalibratedRGBColorSpace = @"NSCalibratedRGBColorSpace";
NSString *const NSPasteboardTypeString = @"public.utf8-plain-text";
NSString *const NSAccessibilityAnnouncementKey = @"AXAnnouncementKey";
NSString *const NSAccessibilityAnnouncementRequestedNotification = @"AXAnnouncementRequested";
NSString *const NSAccessibilityButtonRole = @"AXButton";
NSString *const NSAccessibilityCheckBoxRole = @"AXCheckBox";
NSString *const NSAccessibilityGroupRole = @"AXGroup";
NSString *const NSAccessibilityImageRole = @"AXImage";
NSString *const NSAccessibilityLayoutChangedNotification = @"AXLayoutChanged";
NSString *const NSAccessibilityPopUpButtonRole = @"AXPopUpButton";
NSString *const NSAccessibilityRadioButtonRole = @"AXRadioButton";
NSString *const NSAccessibilityScrollAreaRole = @"AXScrollArea";
NSString *const NSAccessibilitySearchFieldSubrole = @"AXSearchField";
NSString *const NSAccessibilitySliderRole = @"AXSlider";
NSString *const NSAccessibilityStaticTextRole = @"AXStaticText";
NSString *const NSAccessibilityTabButtonSubrole = @"AXTabButton";
NSString *const NSAccessibilityTabGroupRole = @"AXTabGroup";
NSString *const NSAccessibilityTextFieldRole = @"AXTextField";
NSString *const NSAccessibilityUIElementsKey = @"AXUIElementsKey";
NSString *const NSAccessibilityUnknownRole = @"AXUnknown";
NSString *const NSAccessibilityUnknownSubrole = @"AXUnknown";
void NSAccessibilityPostNotificationWithUserInfo(id e, NSString *n, NSDictionary *u) {}

int NSApplicationMain(int argc, const char **argv) {
    ShimLog("AppKit: NSApplicationMain(argc %d)", argc);
    g_argc = argc; g_argv = (char **)argv;
    StartUIKit();
    return 0;
}

// ---------------------------------------------------------------- 이벤트 생성
static void Dispatch(NSEvent *e) {
    if (!g_launched || !NSApp) return;
    e.window = g_window;
    [NSApp sendEvent:e];
}

static void SendKey(unsigned code, BOOL down, NSTimeInterval ts) {
    if (code > 255) return;
    uint64_t flag = FlagForKey(code);
    if (flag) {
        if (code == 57) { if (down) g_shimModFlags ^= flag; }
        else if (down) g_shimModFlags |= flag; else g_shimModFlags &= ~flag;
        g_shimKeyDown[code] = down;
        NSEvent *e = [NSEvent new]; e.type = kFlagsChanged; e.keyCode = code; e.modifierFlags = (NSUInteger)g_shimModFlags; e.timestamp = ts;
        Dispatch(e);
        return;
    }
    BOOL repeat = down && g_shimKeyDown[code];
    g_shimKeyDown[code] = down;
    NSEvent *e = [NSEvent new];
    e.type = down ? kKeyDown : kKeyUp; e.keyCode = code; e.isARepeat = repeat;
    e.modifierFlags = (NSUInteger)g_shimModFlags; e.timestamp = ts;
    NSString *f = FunctionKeyChar(code);
    e.characters = f ?: @(ShimMacKeyChars(code, g_shimModFlags & kFlagShift));
    e.charactersIgnoringModifiers = f ?: @(ShimMacKeyChars(code, false));
    e.locationInWindow = g_mouse;
    Dispatch(e);
}

static void SendMouse(NSUInteger type, CGPoint p, NSTimeInterval ts, NSInteger clicks) {
    g_mouse = p;
    NSEvent *e = [NSEvent new];
    e.type = type; e.locationInWindow = p; e.timestamp = ts; e.clickCount = clicks; e.pressure = (type == kLDown || type == kLDrag) ? 1 : 0;
    e.buttonNumber = (type == kRDown || type == kRUp) ? 1 : 0; e.modifierFlags = (NSUInteger)g_shimModFlags;
    if (type == kLDown) g_shimMouseButtons |= 1; else if (type == kLUp) g_shimMouseButtons &= ~1u;
    Dispatch(e);
}

// ---------------------------------------------------------------- 터치 -> 입력
// TouchMode 0 (기본): 손가락마다 다른 키 (얼불춤은 아무 키나 박자에 누르는 게임; 손가락을 나눠야 겹치는 홀드도 됨)
//                    + 왼쪽 위 모서리 터치 = ESC (일시정지/뒤로)
// TouchMode 1: 마우스 (메뉴 클릭용)
static const unsigned kTouchKeys[] = { 3 /*F*/, 38 /*J*/, 2 /*D*/, 40 /*K*/, 1 /*S*/, 37 /*L*/, 0 /*A*/, 41 /*;*/ };
@interface ShimHostView : UIView @end
@implementation ShimHostView {
    NSMapTable<UITouch *, NSNumber *> *_touchKey;
}
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES;
        self.backgroundColor = UIColor.blackColor;
        _touchKey = [NSMapTable strongToStrongObjectsMapTable];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    UpdateScreen();
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (CALayer *l in self.layer.sublayers) l.frame = self.bounds;
    [CATransaction commit];
}
- (CGPoint)macPoint:(UITouch *)t {
    CGPoint p = [t locationInView:self];
    return CGPointMake(p.x, self.bounds.size.height - p.y);
}
- (unsigned)freeKey {
    NSMutableSet *used = [NSMutableSet set];
    for (UITouch *t in _touchKey) [used addObject:[_touchKey objectForKey:t]];
    for (size_t i = 0; i < sizeof kTouchKeys / sizeof *kTouchKeys; i++) if (![used containsObject:@(kTouchKeys[i])]) return kTouchKeys[i];
    return 49;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)ev {
    int mode = (int)ShimCfgNum("TouchMode", 0);
    for (UITouch *t in touches) {
        CGPoint ui = [t locationInView:self];
        if (mode == 1) { SendMouse(kLDown, [self macPoint:t], t.timestamp, t.tapCount ?: 1); continue; }
        unsigned key = (ui.x < 80 && ui.y < 80) ? 53 /*ESC*/ : [self freeKey];
        [_touchKey setObject:@(key) forKey:t];
        SendKey(key, YES, t.timestamp);
    }
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)ev {
    if ((int)ShimCfgNum("TouchMode", 0) == 1) for (UITouch *t in touches) SendMouse(kLDrag, [self macPoint:t], t.timestamp, 1);
}
- (void)endTouches:(NSSet<UITouch *> *)touches {
    for (UITouch *t in touches) {
        if ((int)ShimCfgNum("TouchMode", 0) == 1) { SendMouse(kLUp, [self macPoint:t], t.timestamp, 1); continue; }
        NSNumber *k = [_touchKey objectForKey:t];
        if (!k) continue;
        [_touchKey removeObjectForKey:t];
        SendKey(k.unsignedIntValue, NO, t.timestamp);
    }
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)ev { [self endTouches:touches]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)ev { [self endTouches:touches]; }
@end

@interface ShimRootVC : UIViewController @end
@implementation ShimRootVC
- (void)loadView { self.view = g_host = [[ShimHostView alloc] initWithFrame:UIScreen.mainScreen.bounds]; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

// ---------------------------------------------------------------- 하드웨어 키보드
static void AttachKeyboard(GCKeyboard *kb) {
    ShimLog("input: keyboard connected (%s)", kb.vendorName.UTF8String ?: "?");
    kb.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *in, GCControllerButtonInput *btn, GCKeyCode code, BOOL pressed) {
        NSNumber *mac = HIDToMac()[@(code)];
        if (!mac) { ShimLogOnce([NSString stringWithFormat:@"hid%ld", (long)code].UTF8String, "input: unmapped HID key %ld", (long)code); return; }
        NSTimeInterval ts = NSProcessInfo.processInfo.systemUptime;
        dispatch_block_t b = ^{ SendKey(mac.unsignedIntValue, pressed, ts); };
        if ([NSThread isMainThread]) b(); else dispatch_async(dispatch_get_main_queue(), b);
    };
}

// ---------------------------------------------------------------- UIKit 앱
static void Notify(SEL sel, NSString *name) {
    NSNotification *n = [NSNotification notificationWithName:name object:NSApp];
    id d = [NSApp delegate];
    if ([d respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(d, sel, n);
    [[NSNotificationCenter defaultCenter] postNotification:n];
}

// 백그라운드에서 Metal 작업 = 크래시. 백그라운드에서는 Unity 의 프레임 갱신을 건너뛴다.
static IMP g_origUpdate;
static void ShimUpdatePlayer(id self, SEL _cmd) {
    if (!g_active) return;
    ((void (*)(id, SEL))g_origUpdate)(self, _cmd);
}

@interface ShimAppDelegate : UIResponder <UIApplicationDelegate> @property(nonatomic, strong) UIWindow *window; @end
@implementation ShimAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    ShimLog("UIKit: didFinishLaunching");
    self.window = g_uiWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [ShimRootVC new];
    [self.window makeKeyAndVisible];
    [g_host layoutIfNeeded];
    UpdateScreen();
    ShimScreen s = ShimScreenInfo();
    ShimLog("UIKit: screen %.0fx%.0f pt, backing scale %.2f, %.0f Hz", s.w, s.h, s.scale, s.maxFPS);

    for (GCKeyboard *kb in @[ GCKeyboard.coalescedKeyboard ?: (id)NSNull.null ]) if (kb != (id)NSNull.null) AttachKeyboard(kb);
    [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) { AttachKeyboard(n.object); }];

    // AppKit 앱 객체 + delegate (맥에서는 Info.plist NSPrincipalClass + MainMenu.nib 이 하는 일)
    if (!NSApp) {
        Class pc = NSClassFromString(@"PlayerApplication") ?: [NSApplication class];
        [pc sharedApplication];
    }
    if (![NSApp delegate]) {
        Class dc = NSClassFromString(@"PlayerAppDelegate");
        if (dc) {
            static id delegate; delegate = [dc new];   // NSApp.delegate 는 weak
            [NSApp setDelegate:delegate];
        } else ShimLog("AppKit: PlayerAppDelegate class not found!");
    }
    Class dc = object_getClass([NSApp delegate]);
    Method m = class_getInstanceMethod(dc, @selector(UpdatePlayer));
    if (m) { g_origUpdate = method_setImplementation(m, (IMP)ShimUpdatePlayer); ShimLog("AppKit: UpdatePlayer paused while in background"); }

    dispatch_async(dispatch_get_main_queue(), ^{
        ShimLog("AppKit: applicationWillFinishLaunching");
        Notify(@selector(applicationWillFinishLaunching:), @"NSApplicationWillFinishLaunchingNotification");
        g_launched = YES;
        ShimLog("AppKit: applicationDidFinishLaunching");
        Notify(@selector(applicationDidFinishLaunching:), @"NSApplicationDidFinishLaunchingNotification");
        ShimLog("AppKit: applicationDidFinishLaunching returned");
        Notify(@selector(applicationDidBecomeActive:), NSApplicationDidBecomeActiveNotification);
    });
    return YES;
}
- (void)applicationWillResignActive:(UIApplication *)a {
    ShimLog("UIKit: resign active"); g_active = NO;
    if (g_launched) Notify(@selector(applicationDidResignActive:), @"NSApplicationDidResignActiveNotification");
}
- (void)applicationDidBecomeActive:(UIApplication *)a {
    BOOL was = g_active; g_active = YES;
    if (g_launched && !was) { ShimLog("UIKit: become active"); Notify(@selector(applicationDidBecomeActive:), NSApplicationDidBecomeActiveNotification); }
}
- (void)applicationWillTerminate:(UIApplication *)a {
    ShimLog("UIKit: will terminate");
    id d = [NSApp delegate];
    if ([d respondsToSelector:@selector(applicationWillTerminate:)])
        [d applicationWillTerminate:[NSNotification notificationWithName:@"NSApplicationWillTerminateNotification" object:NSApp]];
}
- (UIInterfaceOrientationMask)application:(UIApplication *)a supportedInterfaceOrientationsForWindow:(UIWindow *)w { return UIInterfaceOrientationMaskLandscape; }
@end

static void StartUIKit(void) {
    if (g_uikitUp) return;
    g_uikitUp = YES;
    ShimLog("UIKit: UIApplicationMain");
    static char *fallback[] = { "ADOFAI", NULL };
    UIApplicationMain(g_argc ?: 1, g_argv ?: fallback, nil, NSStringFromClass(ShimAppDelegate.class));
}
