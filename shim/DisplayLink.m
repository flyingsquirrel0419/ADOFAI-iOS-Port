// CVDisplayLink (macOS 전용) 을 CADisplayLink 로 구현. 콜백은 맥처럼 별도 스레드에서 부른다.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#include <mach/mach_time.h>
#include "Shim.h"

#define EXPORT __attribute__((visibility("default")))

// CVTimeStamp (CoreVideo/CVBase.h 와 같은 배치)
typedef struct {
    uint32_t version; int32_t videoTimeScale; int64_t videoTime; uint64_t hostTime; double rateScalar;
    int64_t videoRefreshPeriod; int64_t smpteTime[3]; uint64_t flags; uint64_t reserved;
} TS;
typedef int32_t (*OutputCB)(void *link, const TS *now, const TS *out, uint64_t fin, uint64_t *fout, void *ctx);

@interface ShimDisplayLink : NSObject {
@public
    OutputCB cb; void *ctx; CADisplayLink *dl; NSThread *thread; BOOL running; double period;
}
@end
@implementation ShimDisplayLink
- (void)tick:(CADisplayLink *)d {
    if (!running || !cb) return;
    period = d.targetTimestamp - d.timestamp;
    if (period <= 0) period = d.duration;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    TS now = {0}, out = {0};
    now.version = out.version = 0;
    now.videoTimeScale = out.videoTimeScale = 1000000;
    now.videoRefreshPeriod = out.videoRefreshPeriod = (int64_t)(period * 1e6);
    now.rateScalar = out.rateScalar = 1;
    now.hostTime = (uint64_t)(d.timestamp * 1e9 * tb.denom / tb.numer);
    out.hostTime = (uint64_t)(d.targetTimestamp * 1e9 * tb.denom / tb.numer);
    now.videoTime = (int64_t)(d.timestamp * 1e6); out.videoTime = (int64_t)(d.targetTimestamp * 1e6);
    now.flags = out.flags = 1 | 2 | 4;   // VideoTimeValid | HostTimeValid | SMPTETimeValid(무시)
    uint64_t fout = 0;
    cb((__bridge void *)self, &now, &out, 0, &fout, ctx);
}
- (void)threadMain {
    @autoreleasepool {
        dl = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        double fps = ShimScreenInfo().maxFPS;
        if (@available(iOS 15.0, *)) dl.preferredFrameRateRange = CAFrameRateRangeMake(60, (float)fps, (float)fps);
        [dl addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
        while (running) @autoreleasepool { [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; }
        [dl invalidate]; dl = nil;
    }
}
@end

static NSMutableSet *g_links;

EXPORT int32_t CVDisplayLinkCreateWithActiveCGDisplays(void **out) {
    static dispatch_once_t o; dispatch_once(&o, ^{ g_links = [NSMutableSet set]; });
    ShimDisplayLink *l = [ShimDisplayLink new];
    l->period = 1.0 / ShimScreenInfo().maxFPS;
    @synchronized (g_links) { [g_links addObject:l]; }
    *out = (__bridge void *)l;
    ShimLog("CVDisplayLink: created %p", *out);
    return 0;
}
EXPORT int32_t CVDisplayLinkCreateWithCGDisplay(uint32_t d, void **out) { return CVDisplayLinkCreateWithActiveCGDisplays(out); }
EXPORT int32_t CVDisplayLinkSetCurrentCGDisplay(void *l, uint32_t d) { return 0; }
EXPORT int32_t CVDisplayLinkSetOutputCallback(void *l, OutputCB cb, void *ctx) {
    ShimDisplayLink *s = (__bridge ShimDisplayLink *)l; s->cb = cb; s->ctx = ctx; return 0;
}
EXPORT int32_t CVDisplayLinkStart(void *l) {
    ShimDisplayLink *s = (__bridge ShimDisplayLink *)l;
    if (s->running) return 0;
    s->running = YES;
    s->thread = [[NSThread alloc] initWithTarget:s selector:@selector(threadMain) object:nil];
    s->thread.qualityOfService = NSQualityOfServiceUserInteractive;
    s->thread.name = @"CVDisplayLink";
    [s->thread start];
    ShimLog("CVDisplayLink: start %p", l);
    return 0;
}
EXPORT int32_t CVDisplayLinkStop(void *l) { ((__bridge ShimDisplayLink *)l)->running = NO; return 0; }
EXPORT void CVDisplayLinkRelease(void *l) {
    ShimDisplayLink *s = (__bridge ShimDisplayLink *)l;
    s->running = NO;
    @synchronized (g_links) { [g_links removeObject:s]; }
}
// CVTime { int64 timeValue; int32 timeScale; int32 flags }
typedef struct { int64_t v; int32_t scale; int32_t flags; } CVTime_;
EXPORT CVTime_ CVDisplayLinkGetNominalOutputVideoRefreshPeriod(void *l) {
    return (CVTime_){ (int64_t)(1e6 / ShimScreenInfo().maxFPS), 1000000, 0 };
}
EXPORT double CVDisplayLinkGetActualOutputVideoRefreshPeriod(void *l) { return ((__bridge ShimDisplayLink *)l)->period; }

// AVFoundation: 맥 전용 캡처 프리셋 상수
EXPORT NSString *const AVCaptureSessionPreset320x240 = @"AVCaptureSessionPreset320x240";
EXPORT NSString *const AVCaptureSessionPreset960x540 = @"AVCaptureSessionPreset960x540";
