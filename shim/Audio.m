// 오디오: 맥 CoreAudio HAL -> iOS
//
// Unity(FMOD) 맥 출력은
//   1. AudioObjectGetPropertyData 로 기본 출력 장치 / 샘플레이트 / 버퍼 크기 / 채널 구성을 묻고
//   2. AudioComponentFindNext({auou, ahal 또는 def}) 로 HAL 출력 유닛을 만들어
//   3. kAudioOutputUnitProperty_CurrentDevice 로 장치를 지정한 뒤 렌더 콜백으로 소리를 낸다.
// iOS 에는 HAL(AudioObject*)이 없고 출력 유닛은 RemoteIO('rioc') 하나뿐이다. 그래서
//   - AudioObject* / AudioDevice* / AudioHardware* : 가상 장치 하나(스피커)를 흉내 낸다 (값은 AVAudioSession 에서)
//   - UnityPlayer 의 AudioComponentFindNext / AudioUnitSetProperty / AudioUnitGetProperty import 를 훅:
//       ahal/def/sys 출력 -> rioc, 맥 전용 속성(CurrentDevice 등)은 성공한 척
// 리듬 게임이라 지연이 중요: AVAudioSession 의 IO 버퍼를 짧게 요청한다 (AudioIOBufferMs, 기본 5ms).
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include "Shim.h"

#define EXPORT __attribute__((visibility("default")))
#define FOURCC(s) ((UInt32)((s)[0] << 24 | (s)[1] << 16 | (s)[2] << 8 | (s)[3]))

enum { kSystemObject = 1, kDevice = 2, kOutStream = 3 };
#ifndef kAudioHardwareUnknownPropertyError
#define kAudioHardwareUnknownPropertyError ((OSStatus)0x77686F3F)   /* 'who?' (macOS AudioHardwareBase.h) */
#endif

typedef struct { UInt32 mSelector, mScope, mElement; } Addr;
static const char *FCC(UInt32 v, char b[8]) { b[0] = v >> 24; b[1] = v >> 16; b[2] = v >> 8; b[3] = v; b[4] = 0; return b; }

static double SampleRate(void) { double r = AVAudioSession.sharedInstance.sampleRate; return r > 0 ? r : 48000; }
static UInt32 BufferFrames(void) {
    double d = AVAudioSession.sharedInstance.IOBufferDuration;
    UInt32 f = d > 0 ? (UInt32)lround(d * SampleRate()) : 256;
    return f ? f : 256;
}
static UInt32 Channels(void) { NSInteger c = AVAudioSession.sharedInstance.outputNumberOfChannels; return c > 0 ? (UInt32)c : 2; }

static void SetupSession(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance;
    NSError *e = nil;
    [s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&e];
    double ms = ShimCfgNum("AudioIOBufferMs", 5);
    [s setPreferredIOBufferDuration:ms / 1000.0 error:nil];
    [s setActive:YES error:&e];
    ShimLog("audio: session active (%s) %.0f Hz, IO buffer %.1f ms (%u frames), %u ch, output latency %.1f ms",
            e ? e.localizedDescription.UTF8String : "ok", s.sampleRate, s.IOBufferDuration * 1000, BufferFrames(), Channels(),
            s.outputLatency * 1000);
}

// ---------------------------------------------------------------- 가상 HAL
static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = SampleRate(); f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mChannelsPerFrame = Channels(); f.mBitsPerChannel = 32; f.mFramesPerPacket = 1;
    f.mBytesPerFrame = f.mBytesPerPacket = 4 * f.mChannelsPerFrame;
    return f;
}

// 속성 값을 만든다. 모르는 속성이면 NO.
static BOOL PropValue(UInt32 obj, const Addr *a, NSMutableData *out) {
#define PUT(v) do { __typeof__(v) _x = (v); [out appendBytes:&_x length:sizeof _x]; } while (0)
    UInt32 sel = a->mSelector;
    BOOL output = a->mScope != FOURCC("inpt");
    if (obj == kSystemObject) {
        if (sel == FOURCC("dOut") || sel == FOURCC("sOut")) { PUT((UInt32)kDevice); return YES; }
        if (sel == FOURCC("dIn ")) { PUT((UInt32)0); return YES; }
        if (sel == FOURCC("dev#")) { PUT((UInt32)kDevice); return YES; }
        if (sel == FOURCC("lnam") || sel == FOURCC("name")) { PUT((CFStringRef)CFRetain(CFSTR("System"))); return YES; }
        return NO;
    }
    if (obj == kDevice) {
        if (sel == FOURCC("nsrt")) { PUT((Float64)SampleRate()); return YES; }
        if (sel == FOURCC("nsr#")) { AudioValueRange r = { SampleRate(), SampleRate() }; PUT(r); return YES; }
        if (sel == FOURCC("fsiz")) { PUT(BufferFrames()); return YES; }
        if (sel == FOURCC("fsz#")) { AudioValueRange r = { 64, 4096 }; PUT(r); return YES; }
        if (sel == FOURCC("slay")) {        // AudioBufferList
            UInt32 n = output ? 1 : 0; PUT(n);
            if (n) { AudioBuffer b = { Channels(), 0, NULL }; PUT(b); }
            return YES;
        }
        if (sel == FOURCC("stm#")) { if (output) PUT((UInt32)kOutStream); return YES; }
        if (sel == FOURCC("lnam") || sel == FOURCC("name")) { PUT((CFStringRef)CFRetain(CFSTR("iPhone Speaker"))); return YES; }
        if (sel == FOURCC("uid ")) { PUT((CFStringRef)CFRetain(CFSTR("ADOFAIShimOutput"))); return YES; }
        if (sel == FOURCC("muid")) { PUT((CFStringRef)CFRetain(CFSTR("ADOFAIShimOutput"))); return YES; }
        if (sel == FOURCC("lmak") || sel == FOURCC("makr")) { PUT((CFStringRef)CFRetain(CFSTR("Apple"))); return YES; }
        if (sel == FOURCC("ltnc")) { PUT((UInt32)lround(AVAudioSession.sharedInstance.outputLatency * SampleRate())); return YES; }
        if (sel == FOURCC("saft")) { PUT((UInt32)0); return YES; }
        if (sel == FOURCC("livn") || sel == FOURCC("goin") || sel == FOURCC("gone")) { PUT((UInt32)(sel != FOURCC("gone"))); return YES; }
        if (sel == FOURCC("tran")) { PUT((UInt32)FOURCC("bltn")); return YES; }
        if (sel == FOURCC("dch2")) { UInt32 c[2] = { 1, 2 }; [out appendBytes:c length:sizeof c]; return YES; }
        if (sel == FOURCC("hog ")) { PUT((pid_t)-1); return YES; }
        if (sel == FOURCC("ssrc")) { PUT((UInt32)FOURCC("ispk")); return YES; }
        if (sel == FOURCC("mute")) { PUT((UInt32)0); return YES; }
        if (sel == FOURCC("volm")) { PUT((Float32)1); return YES; }
        if (sel == FOURCC("cdis")) { PUT((UInt32)1); return YES; }  // ClockDomain
        if (sel == FOURCC("ownd")) { if (output) PUT((UInt32)kOutStream); return YES; }  // owned objects
        if (sel == FOURCC("clas")) { PUT((UInt32)FOURCC("adev")); return YES; }
        if (sel == FOURCC("bcls")) { PUT((UInt32)FOURCC("aobj")); return YES; }
        if (sel == FOURCC("srnd")) {   // AudioChannelLayout (stereo)
            AudioChannelLayout l = {0}; l.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo; PUT(l); return YES;
        }
        return NO;
    }
    if (obj == kOutStream) {
        if (sel == FOURCC("sfmt") || sel == FOURCC("pft ")) { PUT(StreamFormat()); return YES; }
        if (sel == FOURCC("sdir")) { PUT((UInt32)0); return YES; }
        if (sel == FOURCC("stc1")) { PUT((UInt32)1); return YES; }
        if (sel == FOURCC("ltnc")) { PUT((UInt32)0); return YES; }
        if (sel == FOURCC("sfma") || sel == FOURCC("pfta")) {   // AudioStreamRangedDescription
            struct { AudioStreamBasicDescription f; AudioValueRange r; } d = { StreamFormat(), { SampleRate(), SampleRate() } };  // AudioStreamRangedDescription (macOS)
            PUT(d); return YES;
        }
        return NO;
    }
    return NO;
#undef PUT
}

static void LogProp(const char *what, UInt32 obj, const Addr *a, BOOL known) {
    char b1[8], b2[8], key[64];
    snprintf(key, sizeof key, "%s%u%s%s", what, obj, FCC(a->mSelector, b1), FCC(a->mScope, b2));
    ShimLogOnce(key, "audio HAL: %s obj %u '%s' scope '%s' elem %u%s", what, obj, FCC(a->mSelector, b1), FCC(a->mScope, b2),
                a->mElement, known ? "" : " -> unknown property");
}

EXPORT OSStatus AudioObjectGetPropertyDataSize(UInt32 obj, const Addr *a, UInt32 qs, const void *q, UInt32 *size) {
    NSMutableData *d = [NSMutableData data];
    BOOL ok = PropValue(obj, a, d);
    LogProp("size", obj, a, ok);
    if (!ok) return kAudioHardwareUnknownPropertyError;
    if (size) *size = (UInt32)d.length;
    // CFString 은 PropValue 가 retain 했으므로 해제
    if (d.length == sizeof(CFStringRef) && (a->mSelector == FOURCC("lnam") || a->mSelector == FOURCC("name") || a->mSelector == FOURCC("uid ") ||
        a->mSelector == FOURCC("muid") || a->mSelector == FOURCC("lmak") || a->mSelector == FOURCC("makr"))) CFRelease(*(CFStringRef *)d.bytes);
    return 0;
}
EXPORT OSStatus AudioObjectGetPropertyData(UInt32 obj, const Addr *a, UInt32 qs, const void *q, UInt32 *size, void *data) {
    NSMutableData *d = [NSMutableData data];
    BOOL ok = PropValue(obj, a, d);
    LogProp("get", obj, a, ok);
    if (!ok) return kAudioHardwareUnknownPropertyError;
    UInt32 n = (UInt32)MIN((NSUInteger)(size ? *size : 0), d.length);
    if (data) memcpy(data, d.bytes, n);
    if (size) *size = n;
    return 0;
}
EXPORT OSStatus AudioObjectSetPropertyData(UInt32 obj, const Addr *a, UInt32 qs, const void *q, UInt32 size, const void *data) {
    char b[8];
    ShimLogOnce("halset", "audio HAL: set obj %u '%s' (ignored)", obj, FCC(a->mSelector, b));
    if (a->mSelector == FOURCC("fsiz") && size >= 4) {
        UInt32 f = *(const UInt32 *)data;
        [AVAudioSession.sharedInstance setPreferredIOBufferDuration:f / SampleRate() error:nil];
        ShimLog("audio HAL: game asks %u frame buffer -> IO buffer now %.1f ms", f, AVAudioSession.sharedInstance.IOBufferDuration * 1000);
    }
    return 0;
}
EXPORT Boolean AudioObjectHasProperty(UInt32 obj, const Addr *a) { NSMutableData *d = [NSMutableData data]; return PropValue(obj, a, d); }
EXPORT OSStatus AudioObjectIsPropertySettable(UInt32 obj, const Addr *a, Boolean *s) { if (s) *s = false; return 0; }
EXPORT OSStatus AudioObjectAddPropertyListener(UInt32 obj, const Addr *a, void *l, void *c) { return 0; }
EXPORT OSStatus AudioObjectRemovePropertyListener(UInt32 obj, const Addr *a, void *l, void *c) { return 0; }
EXPORT OSStatus AudioObjectAddPropertyListenerBlock(UInt32 obj, const Addr *a, dispatch_queue_t q, id b) { return 0; }
EXPORT OSStatus AudioObjectRemovePropertyListenerBlock(UInt32 obj, const Addr *a, dispatch_queue_t q, id b) { return 0; }

// 옛 API (Boolean isInput 로 scope 를 고른다)
static Addr Old(UInt32 sel, Boolean in, UInt32 ch) { return (Addr){ sel, in ? FOURCC("inpt") : FOURCC("outp"), ch }; }
EXPORT OSStatus AudioDeviceGetPropertyInfo(UInt32 dev, UInt32 ch, Boolean in, UInt32 sel, UInt32 *size, Boolean *writable) {
    Addr a = Old(sel, in, ch); if (writable) *writable = false; return AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, size);
}
EXPORT OSStatus AudioDeviceGetProperty(UInt32 dev, UInt32 ch, Boolean in, UInt32 sel, UInt32 *size, void *data) {
    Addr a = Old(sel, in, ch); return AudioObjectGetPropertyData(dev, &a, 0, NULL, size, data);
}
EXPORT OSStatus AudioDeviceSetProperty(UInt32 dev, const void *when, UInt32 ch, Boolean in, UInt32 sel, UInt32 size, const void *data) {
    Addr a = Old(sel, in, ch); return AudioObjectSetPropertyData(dev, &a, 0, NULL, size, data);
}
EXPORT OSStatus AudioHardwareGetPropertyInfo(UInt32 sel, UInt32 *size, Boolean *writable) {
    Addr a = { sel, FOURCC("glob"), 0 }; if (writable) *writable = false; return AudioObjectGetPropertyDataSize(kSystemObject, &a, 0, NULL, size);
}
EXPORT OSStatus AudioHardwareGetProperty(UInt32 sel, UInt32 *size, void *data) {
    Addr a = { sel, FOURCC("glob"), 0 }; return AudioObjectGetPropertyData(kSystemObject, &a, 0, NULL, size, data);
}
EXPORT OSStatus AudioHardwareAddPropertyListener(UInt32 sel, void *l, void *c) { return 0; }

// ---------------------------------------------------------------- 출력 유닛: HAL -> RemoteIO
static AudioComponent (*real_FindNext)(AudioComponent, const AudioComponentDescription *);
static OSStatus (*real_SetProp)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus (*real_GetProp)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, void *, UInt32 *);

static AudioComponent shim_FindNext(AudioComponent c, const AudioComponentDescription *d) {
    if (d && d->componentType == kAudioUnitType_Output &&
        (d->componentSubType == FOURCC("ahal") || d->componentSubType == FOURCC("def ") || d->componentSubType == FOURCC("sys "))) {
        AudioComponentDescription r = *d;
        char b[8];
        ShimLog("audio: output unit '%s' -> RemoteIO", FCC(d->componentSubType, b));
        r.componentSubType = kAudioUnitSubType_RemoteIO;
        r.componentManufacturer = kAudioUnitManufacturer_Apple;
        return real_FindNext(c, &r);
    }
    return real_FindNext(c, d);
}

static BOOL MacOnlyProp(AudioUnitPropertyID p) {
    return p == 2000 /* CurrentDevice */ || p == 2010 /* ChannelMap */ || p == 2011 /* HasIO */ || p == 2013 /* StartTimestampsAtZero */ ||
           p == FOURCC("fsiz") || p == FOURCC("nsrt");
}
static OSStatus shim_SetProp(AudioUnit u, AudioUnitPropertyID p, AudioUnitScope s, AudioUnitElement e, const void *d, UInt32 n) {
    if (p == 2000) { ShimLog("audio: kAudioOutputUnitProperty_CurrentDevice = %u (RemoteIO has no devices; ok)", d ? *(const UInt32 *)d : 0); return 0; }
    OSStatus r = real_SetProp(u, p, s, e, d, n);
    if (r) {
        char key[48]; snprintf(key, sizeof key, "ausetp%u_%u", p, s);
        ShimLogOnce(key, "audio: AudioUnitSetProperty(%u, scope %u, elem %u) = %d%s", p, s, e, (int)r, MacOnlyProp(p) ? " (mac-only, ignored)" : "");
        if (MacOnlyProp(p)) return 0;
    }
    return r;
}
static OSStatus shim_GetProp(AudioUnit u, AudioUnitPropertyID p, AudioUnitScope s, AudioUnitElement e, void *d, UInt32 *n) {
    if (p == 2000 && d && n && *n >= 4) { *(UInt32 *)d = kDevice; *n = 4; return 0; }
    OSStatus r = real_GetProp(u, p, s, e, d, n);
    if (r) { char key[48]; snprintf(key, sizeof key, "augetp%u_%u", p, s); ShimLogOnce(key, "audio: AudioUnitGetProperty(%u, scope %u) = %d", p, s, (int)r); }
    return r;
}

static void OnInterruption(NSNotification *n) {
    NSUInteger t = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    ShimLog("audio: interruption %s", t == AVAudioSessionInterruptionTypeBegan ? "began" : "ended");
    if (t == AVAudioSessionInterruptionTypeEnded) [AVAudioSession.sharedInstance setActive:YES error:nil];
}

void ShimAudioInstall(void) {
    SetupSession();
    ShimHookImport("UnityPlayer", "AudioComponentFindNext", (void *)shim_FindNext, (void **)&real_FindNext);
    ShimHookImport("UnityPlayer", "AudioUnitSetProperty", (void *)shim_SetProp, (void **)&real_SetProp);
    ShimHookImport("UnityPlayer", "AudioUnitGetProperty", (void *)shim_GetProp, (void **)&real_GetProp);
    if (!real_FindNext) real_FindNext = AudioComponentFindNext;
    if (!real_SetProp) real_SetProp = AudioUnitSetProperty;
    if (!real_GetProp) real_GetProp = AudioUnitGetProperty;
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *n) { OnInterruption(n); }];
}
