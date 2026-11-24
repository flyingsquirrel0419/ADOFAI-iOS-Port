// iOS 에 없는 맥 C API 스텁 / 대체 구현.
// 대상 목록은 tools/retarget.py + tools/ios_symcheck.py 로 뽑은 것 (docs/analysis.md 참고).
// 원칙: 처음 불릴 때 한 번 로그를 남기고, "장치 없음/기능 없음"으로 자연스럽게 실패하는 값을 돌려준다.
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <math.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>
#include "Shim.h"

#define ONCE(name) ShimLogOnce(name, "stub: %s", name)
#define EXPORT __attribute__((visibility("default")))

typedef int32_t OSStatus_;
typedef uint32_t io_obj;          // io_object_t
typedef int kret;                 // kern_return_t / IOReturn
#define kIOReturnUnsupported ((kret)0xe00002c7)
#define kIOReturnNotFound ((kret)0xe00002f0)

// ================================================================ IOKit
EXPORT const mach_port_t kIOMasterPortDefault = 0;
EXPORT kret IOMasterPort(mach_port_t bootstrap, mach_port_t *port) { if (port) *port = 0; return 0; }
EXPORT CFMutableDictionaryRef IOServiceMatching(const char *name) {
    ShimLogOnce(name ?: "IOServiceMatching", "stub: IOServiceMatching(%s)", name ?: "");
    return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}
EXPORT CFMutableDictionaryRef IOBSDNameMatching(mach_port_t p, uint32_t o, const char *n) { return IOServiceMatching("IOBSDNameMatching"); }
EXPORT kret IOServiceGetMatchingServices(mach_port_t p, CFDictionaryRef m, io_obj *it) {
    if (m) CFRelease(m);   // 맥 API 는 matching 을 consume 한다
    if (it) *it = 0;
    return 0;
}
EXPORT io_obj IOIteratorNext(io_obj it) { return 0; }
EXPORT kret IOObjectRelease(io_obj o) { return 0; }
EXPORT io_obj IORegistryEntryFromPath(mach_port_t p, const char *path) { ONCE("IORegistryEntryFromPath"); return 0; }
EXPORT kret IORegistryEntryGetParentEntry(io_obj e, const char *plane, io_obj *parent) { if (parent) *parent = 0; return kIOReturnNotFound; }
EXPORT kret IORegistryEntryCreateIterator(io_obj e, const char *plane, uint32_t o, io_obj *it) { if (it) *it = 0; return kIOReturnNotFound; }
EXPORT CFTypeRef IORegistryEntryCreateCFProperty(io_obj e, CFStringRef key, CFAllocatorRef a, uint32_t o) { return NULL; }
EXPORT CFTypeRef IORegistryEntrySearchCFProperty(io_obj e, const char *plane, CFStringRef key, CFAllocatorRef a, uint32_t o) { return NULL; }
EXPORT kret IORegistryEntryCreateCFProperties(io_obj e, CFMutableDictionaryRef *props, CFAllocatorRef a, uint32_t o) { if (props) *props = NULL; return kIOReturnNotFound; }
EXPORT CFDictionaryRef IODisplayCreateInfoDictionary(io_obj f, uint32_t o) {
    return CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}
// 전원 알림: 포트 없음
EXPORT io_obj IORegisterForSystemPower(void *ref, void **notifyPort, void *cb, io_obj *notifier) {
    ONCE("IORegisterForSystemPower");
    if (notifyPort) *notifyPort = NULL;
    if (notifier) *notifier = 0;
    return 0;
}
EXPORT CFRunLoopSourceRef IONotificationPortGetRunLoopSource(void *port) { return NULL; }
EXPORT kret IOAllowPowerChange(io_obj k, intptr_t id) { return 0; }
EXPORT kret IOCancelPowerChange(io_obj k, intptr_t id) { return 0; }
// 배터리 (IOPowerSources): 전원 정보 없음 = 빈 목록
EXPORT CFTypeRef IOPSCopyPowerSourcesInfo(void) { return CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks); }
EXPORT CFArrayRef IOPSCopyPowerSourcesList(CFTypeRef blob) { return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks); }

// IOHID: 장치 없음 (게임패드는 GameController / Rewired 쪽으로, 키보드는 shim 이 NSEvent 로 넣는다)
static CFTypeRef DummyCF(void) { return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks); }
EXPORT CFTypeRef IOHIDManagerCreate(CFAllocatorRef a, uint32_t o) { ONCE("IOHIDManagerCreate"); return DummyCF(); }
EXPORT kret IOHIDManagerOpen(CFTypeRef m, uint32_t o) { return 0; }
EXPORT kret IOHIDManagerClose(CFTypeRef m, uint32_t o) { return 0; }
EXPORT CFSetRef IOHIDManagerCopyDevices(CFTypeRef m) { return CFSetCreate(NULL, NULL, 0, &kCFTypeSetCallBacks); }
EXPORT void IOHIDManagerSetDeviceMatching(CFTypeRef m, CFDictionaryRef d) {}
EXPORT void IOHIDManagerSetDeviceMatchingMultiple(CFTypeRef m, CFArrayRef a) {}
EXPORT void IOHIDManagerRegisterDeviceMatchingCallback(CFTypeRef m, void *cb, void *ctx) {}
EXPORT void IOHIDManagerRegisterDeviceRemovalCallback(CFTypeRef m, void *cb, void *ctx) {}
EXPORT void IOHIDManagerRegisterInputValueCallback(CFTypeRef m, void *cb, void *ctx) {}
EXPORT void IOHIDManagerScheduleWithRunLoop(CFTypeRef m, CFRunLoopRef rl, CFStringRef mode) {}
EXPORT void IOHIDManagerUnscheduleFromRunLoop(CFTypeRef m, CFRunLoopRef rl, CFStringRef mode) {}
EXPORT CFArrayRef IOHIDDeviceCopyMatchingElements(CFTypeRef d, CFDictionaryRef m, uint32_t o) { return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks); }
EXPORT CFTypeRef IOHIDDeviceGetProperty(CFTypeRef d, CFStringRef k) { return NULL; }
EXPORT int IOHIDDeviceSetProperty(CFTypeRef d, CFStringRef k, CFTypeRef v) { return 0; }
EXPORT void IOHIDDeviceRegisterInputReportCallback(CFTypeRef d, uint8_t *r, CFIndex l, void *cb, void *ctx) {}
EXPORT kret IOHIDDeviceSetReportWithCallback(CFTypeRef d, int t, CFIndex id, const uint8_t *r, CFIndex l, double to, void *cb, void *ctx) { return kIOReturnUnsupported; }
EXPORT void IOHIDDeviceUnscheduleFromRunLoop(CFTypeRef d, CFRunLoopRef rl, CFStringRef mode) {}
EXPORT CFTypeRef IOHIDElementGetDevice(CFTypeRef e) { return NULL; }
EXPORT CFIndex IOHIDElementGetLogicalMax(CFTypeRef e) { return 0; }
EXPORT CFIndex IOHIDElementGetLogicalMin(CFTypeRef e) { return 0; }
EXPORT int IOHIDElementGetType(CFTypeRef e) { return 0; }
EXPORT uint32_t IOHIDElementGetUsage(CFTypeRef e) { return 0; }
EXPORT uint32_t IOHIDElementGetUsagePage(CFTypeRef e) { return 0; }
EXPORT CFTypeRef IOHIDQueueCreate(CFAllocatorRef a, CFTypeRef d, CFIndex depth, uint32_t o) { return DummyCF(); }
EXPORT void IOHIDQueueAddElement(CFTypeRef q, CFTypeRef e) {}
EXPORT Boolean IOHIDQueueContainsElement(CFTypeRef q, CFTypeRef e) { return false; }
EXPORT CFTypeRef IOHIDQueueCopyNextValueWithTimeout(CFTypeRef q, double t) { return NULL; }
EXPORT void IOHIDQueueStart(CFTypeRef q) {}
EXPORT void IOHIDQueueStop(CFTypeRef q) {}
EXPORT CFTypeRef IOHIDValueGetElement(CFTypeRef v) { return NULL; }
EXPORT CFIndex IOHIDValueGetIntegerValue(CFTypeRef v) { return 0; }
EXPORT CFIndex IOHIDValueGetLength(CFTypeRef v) { return 0; }

// ================================================================ CoreGraphics (디스플레이 / 이벤트)
typedef uint32_t DisplayID;
typedef struct { double x, y, w, h; } Rect_;
typedef struct { double a, b; } Pair_;   // CGPoint / CGSize 와 같은 배치
EXPORT DisplayID CGMainDisplayID(void) { return 1; }
EXPORT int CGGetActiveDisplayList(uint32_t max, DisplayID *ids, uint32_t *count) {
    if (ids && max) ids[0] = 1;
    if (count) *count = 1;
    return 0;
}
EXPORT Rect_ CGDisplayBounds(DisplayID d) { ShimScreen s = ShimScreenInfo(); return (Rect_){ 0, 0, s.w, s.h }; }
EXPORT Pair_ CGDisplayScreenSize(DisplayID d) {
    ShimScreen s = ShimScreenInfo();   // 아이폰 화면 약 460 ppi, 포인트 = 3 픽셀
    double mm = 25.4 / 460.0 * 3;
    return (Pair_){ s.w * mm, s.h * mm };
}
EXPORT int CGDisplayIsBuiltin(DisplayID d) { return 1; }
EXPORT uint32_t CGDisplayIDToOpenGLDisplayMask(DisplayID d) { return 1; }
EXPORT io_obj CGDisplayIOServicePort(DisplayID d) { return 0; }
EXPORT int CGDisplayRegisterReconfigurationCallback(void *cb, void *ctx) { return 0; }
EXPORT int CGDisplayHideCursor(DisplayID d) { return 0; }
EXPORT int CGDisplayShowCursor(DisplayID d) { return 0; }
EXPORT int CGAssociateMouseAndMouseCursorPosition(int c) { return 0; }
EXPORT int CGWarpMouseCursorPosition(Pair_ p) { return 0; }
EXPORT void CGGetLastMouseDelta(int32_t *dx, int32_t *dy) { if (dx) *dx = 0; if (dy) *dy = 0; }
EXPORT int32_t CGShieldingWindowLevel(void) { return 2147483630; }
EXPORT void *CGEventCreateMouseEvent(void *src, uint32_t type, Pair_ p, uint32_t btn) { return NULL; }
EXPORT bool CGEventSourceKeyState(int state, uint16_t key) { return key < 256 && g_shimKeyDown[key]; }
EXPORT uint64_t CGEventSourceFlagsState(int state) { return g_shimModFlags; }
EXPORT bool CGEventSourceButtonState(int state, uint32_t btn) { return btn < 32 && (g_shimMouseButtons >> btn) & 1; }

// 디스플레이 모드: CFData 에 {w, h, pw, ph, hz} 를 담아 CF 객체로 쓴다 (CFRelease 가능)
typedef struct { double w, h, pw, ph, hz; } Mode;
static CFDataRef MakeMode(void) {
    ShimScreen s = ShimScreenInfo();
    Mode m = { s.w, s.h, s.w * s.scale, s.h * s.scale, s.maxFPS };
    return CFDataCreate(NULL, (const UInt8 *)&m, sizeof m);
}
static Mode GetMode(CFTypeRef r) {
    Mode m = {0};
    if (r && CFGetTypeID(r) == CFDataGetTypeID() && CFDataGetLength(r) == sizeof m) memcpy(&m, CFDataGetBytePtr(r), sizeof m);
    return m;
}
EXPORT CFTypeRef CGDisplayCopyDisplayMode(DisplayID d) { return MakeMode(); }
EXPORT CFArrayRef CGDisplayCopyAllDisplayModes(DisplayID d, CFDictionaryRef o) {
    CFTypeRef m = MakeMode();
    CFArrayRef a = CFArrayCreate(NULL, &m, 1, &kCFTypeArrayCallBacks);
    CFRelease(m);
    return a;
}
EXPORT void CGDisplayModeRelease(CFTypeRef m) { if (m) CFRelease(m); }
EXPORT size_t CGDisplayModeGetWidth(CFTypeRef m) { return (size_t)GetMode(m).w; }
EXPORT size_t CGDisplayModeGetHeight(CFTypeRef m) { return (size_t)GetMode(m).h; }
EXPORT size_t CGDisplayModeGetPixelWidth(CFTypeRef m) { return (size_t)GetMode(m).pw; }
EXPORT size_t CGDisplayModeGetPixelHeight(CFTypeRef m) { return (size_t)GetMode(m).ph; }
EXPORT CFStringRef CGDisplayModeCopyPixelEncoding(CFTypeRef m) { return CFSTR("--------RRRRRRRRGGGGGGGGBBBBBBBB"); }
EXPORT double CGDisplayModeGetRefreshRate(CFTypeRef m) { return GetMode(m).hz; }

// Metal 장치 (ObjC 객체; MTLCreateSystemDefaultDevice 는 +1 이 아니므로 retain)
extern void *MTLCreateSystemDefaultDevice(void);
extern void *objc_retain(void *);
EXPORT void *CGDirectDisplayCopyCurrentMetalDevice(DisplayID d) { return objc_retain(MTLCreateSystemDefaultDevice()); }

// ================================================================ CoreVideo: CVDisplayLink (CADisplayLink 로 구현: DisplayLink.m)
// CVOpenGLTextureCache: OpenGL 없음
EXPORT int32_t CVOpenGLTextureCacheCreate(void *a, CFDictionaryRef c, void *ctx, void *pf, CFDictionaryRef t, void **out) { if (out) *out = NULL; return -6660; }
EXPORT int32_t CVOpenGLTextureCacheCreateTextureFromImage(void *a, void *c, void *img, CFDictionaryRef at, void **out) { if (out) *out = NULL; return -6660; }
EXPORT void CVOpenGLTextureCacheFlush(void *c, uint64_t o) {}
EXPORT void CVOpenGLTextureCacheRelease(void *c) {}
EXPORT uint32_t CVOpenGLTextureGetName(void *t) { return 0; }
EXPORT uint32_t CVOpenGLTextureGetTarget(void *t) { return 0; }

// ================================================================ OpenGL / CGL: Metal 을 쓰므로 전부 실패
EXPORT int CGLChoosePixelFormat(const int *attrs, void **pix, int *npix) { ONCE("CGLChoosePixelFormat"); if (pix) *pix = NULL; if (npix) *npix = 0; return 10002; }
EXPORT int CGLCreateContext(void *pix, void *share, void **ctx) { if (ctx) *ctx = NULL; return 10002; }
EXPORT int CGLDestroyContext(void *ctx) { return 0; }
EXPORT int CGLReleaseContext(void *ctx) { return 0; }
EXPORT int CGLDestroyPixelFormat(void *pix) { return 0; }
EXPORT void *CGLGetPixelFormat(void *ctx) { return NULL; }
EXPORT void *CGLGetCurrentContext(void) { return NULL; }
EXPORT int CGLSetCurrentContext(void *ctx) { return 0; }
EXPORT int CGLSetParameter(void *ctx, int p, const int *v) { return 0; }
EXPORT int CGLEnable(void *ctx, int p) { return 0; }
EXPORT int CGLFlushDrawable(void *ctx) { return 0; }
EXPORT int CGLQueryRendererInfo(uint32_t mask, void **rend, int *n) { if (rend) *rend = NULL; if (n) *n = 0; return 10002; }
EXPORT int CGLDescribeRenderer(void *rend, int idx, int prop, int *v) { if (v) *v = 0; return 10002; }
EXPORT int CGLDestroyRendererInfo(void *rend) { return 0; }
EXPORT const char *CGLErrorString(int e) { return "CGL not available on iOS"; }
EXPORT void glFlush(void) {}
EXPORT void *glFenceSync(uint32_t c, uint32_t f) { return NULL; }
EXPORT void glDeleteSync(void *s) {}
EXPORT uint32_t glClientWaitSync(void *s, uint32_t f, uint64_t t) { return 0x911A; /* GL_ALREADY_SIGNALED */ }

// ================================================================ Carbon: 키보드 레이아웃 / 이벤트 시간
const char *ShimMacKeyChars(unsigned code, bool shift);
EXPORT const CFStringRef kTISPropertyInputSourceID = CFSTR("TISPropertyInputSourceID");
EXPORT const CFStringRef kTISPropertyInputSourceType = CFSTR("TISPropertyInputSourceType");
EXPORT const CFStringRef kTISPropertyUnicodeKeyLayoutData = CFSTR("TISPropertyUnicodeKeyLayoutData");
EXPORT const CFStringRef kTISTypeKeyboardLayout = CFSTR("TISTypeKeyboardLayout");
EXPORT const CFStringRef kTISNotifySelectedKeyboardInputSourceChanged = CFSTR("TISNotifySelectedKeyboardInputSourceChanged");

static CFDictionaryRef InputSource(void) {
    static CFDictionaryRef d; static dispatch_once_t o;
    dispatch_once(&o, ^{
        static const UInt8 uchr[64] = { 0 };   // 내용은 안 쓴다: UCKeyTranslate 가 US 배열로 직접 변환
        CFDataRef layout = CFDataCreate(NULL, uchr, sizeof uchr);
        const void *k[] = { kTISPropertyInputSourceID, kTISPropertyInputSourceType, kTISPropertyUnicodeKeyLayoutData };
        const void *v[] = { CFSTR("com.apple.keylayout.US"), kTISTypeKeyboardLayout, layout };
        d = CFDictionaryCreate(NULL, k, v, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(layout);
    });
    return (CFDictionaryRef)CFRetain(d);
}
EXPORT CFTypeRef TISCopyCurrentKeyboardInputSource(void) { return InputSource(); }
EXPORT CFTypeRef TISCopyCurrentKeyboardLayoutInputSource(void) { return InputSource(); }
EXPORT CFTypeRef TISCopyCurrentASCIICapableKeyboardLayoutInputSource(void) { return InputSource(); }
EXPORT void *TISGetInputSourceProperty(CFTypeRef src, CFStringRef key) {
    return src ? (void *)CFDictionaryGetValue((CFDictionaryRef)src, key) : NULL;
}
EXPORT uint8_t LMGetKbdType(void) { return 40; /* ANSI */ }
EXPORT int32_t UCKeyTranslate(const void *layout, uint16_t code, uint16_t action, uint32_t modState, uint32_t kbType,
                              uint32_t opts, uint32_t *deadKeyState, size_t maxLen, size_t *actualLen, uint16_t *out) {
    bool shift = (modState & 0x02) || (modState & 0x04) /* shiftKey / alphaLock (>>8) */;
    const char *s = ShimMacKeyChars(code, shift);
    size_t n = strlen(s);
    if (n > maxLen) n = maxLen;
    for (size_t i = 0; i < n; i++) out[i] = (uint8_t)s[i];
    if (actualLen) *actualLen = n;
    if (deadKeyState) *deadKeyState = 0;
    return 0;
}
EXPORT double GetCurrentEventTime(void) {
    // 맥: 부팅 후 초 (NSEvent timestamp 와 같은 기준)
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
}

// ================================================================ CoreServices
EXPORT int16_t UpdateSystemActivity(uint8_t a) { return 0; }
EXPORT int32_t LSRegisterURL(CFURLRef u, Boolean update) { return 0; }
EXPORT int32_t LSSetDefaultHandlerForURLScheme(CFStringRef scheme, CFStringRef bundle) { return 0; }

// ================================================================ Security (macOS 키체인 API)
#define errSecUnimplemented (-4)
EXPORT const CFStringRef kSecOIDX509V1IssuerName = CFSTR("2.16.840.1.113741.2.1.1.1.5");
EXPORT const CFStringRef kSecOIDX509V1SubjectName = CFSTR("2.16.840.1.113741.2.1.1.1.8");
EXPORT CFDictionaryRef SecCertificateCopyValues(void *c, CFArrayRef keys, CFErrorRef *e) { if (e) *e = NULL; return NULL; }
EXPORT OSStatus_ SecCertificateGetData(void *c, void *data) { return errSecUnimplemented; }
EXPORT OSStatus_ SecKeychainOpen(const char *path, void **kc) { if (kc) *kc = NULL; return errSecUnimplemented; }
EXPORT OSStatus_ SecKeychainSearchCreateFromAttributes(void *kc, uint32_t cls, const void *attrs, void **s) { if (s) *s = NULL; return errSecUnimplemented; }
EXPORT OSStatus_ SecKeychainSearchCopyNext(void *s, void **item) { if (item) *item = NULL; return -25300; /* errSecItemNotFound */ }
EXPORT OSStatus_ SecKeychainItemCopyContent(void *i, void *c, void *a, uint32_t *l, void **d) { return errSecUnimplemented; }
EXPORT OSStatus_ SecKeychainItemFreeContent(void *a, void *d) { return 0; }
EXPORT OSStatus_ SecTrustSettingsCopyCertificates(int domain, CFArrayRef *certs) { if (certs) *certs = NULL; return -25300; }
EXPORT OSStatus_ SecTrustSettingsCopyTrustSettings(void *c, int domain, CFArrayRef *s) { if (s) *s = NULL; return -25300; }

// ================================================================ libm (맥에서는 CoreServices 를 통해 링크됨)
// shim 이 CoreServices 자리를 맡으므로 이 다섯 개도 shim 이 내보내야 한다. 같은 이름의 libSystem 함수를
// shim 안에서 부르면 자기 자신을 부르게 되므로 직접 구현한다.
#include <fenv.h>
EXPORT const fenv_t _FE_DFL_ENV = { 0, 0 };    // arm64 기본: FPCR = 0, FPSR = 0
EXPORT int fegetenv(fenv_t *e) {
    uint64_t cr, sr;
    __asm__ volatile("mrs %0, fpcr" : "=r"(cr)); __asm__ volatile("mrs %0, fpsr" : "=r"(sr));
    e->__fpcr = cr; e->__fpsr = sr;
    return 0;
}
EXPORT int fesetenv(const fenv_t *e) {
    uint64_t cr = e->__fpcr, sr = e->__fpsr;
    __asm__ volatile("msr fpcr, %0" :: "r"(cr)); __asm__ volatile("msr fpsr, %0" :: "r"(sr));
    return 0;
}
EXPORT float modff(float x, float *ip) {
    float i = __builtin_truncf(x);   // frintz
    if (ip) *ip = i;
    if (__builtin_isinf(x)) return __builtin_copysignf(0.0f, x);
    return __builtin_copysignf(x - i, x);
}
EXPORT double exp2(double x) { return pow(2.0, x); }
