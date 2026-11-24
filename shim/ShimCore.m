// 로그, 설정, GOT 훅, 시작 시 초기화
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdarg.h>
#include <sys/time.h>
#include <sys/utsname.h>
#include "Shim.h"

static FILE *g_log;
static pthread_mutex_t g_logLock = PTHREAD_MUTEX_INITIALIZER;
static double g_t0;

static double now(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }

static NSString *DocumentsDir(void) {
    NSArray *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return d.firstObject ?: NSTemporaryDirectory();
}

static void LogOpen(void) {
    if (g_log) return;
    g_t0 = now();
    NSString *dir = DocumentsDir();
    NSString *p = [dir stringByAppendingPathComponent:@"adofaishim.log"];
    NSString *old = [dir stringByAppendingPathComponent:@"adofaishim.prev.log"];
    [[NSFileManager defaultManager] removeItemAtPath:old error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:p toPath:old error:nil];
    g_log = fopen(p.fileSystemRepresentation, "w");
}

static void LogV(const char *fmt, va_list ap) {
    char buf[4096];
    vsnprintf(buf, sizeof buf, fmt, ap);
    pthread_mutex_lock(&g_logLock);
    LogOpen();
    double t = now() - g_t0;
    int main = pthread_main_np();
    if (g_log) { fprintf(g_log, "[%9.3f]%s %s\n", t, main ? "" : " (bg)", buf); fflush(g_log); }
    fprintf(stderr, "ADOFAIShim [%9.3f] %s\n", t, buf);
    pthread_mutex_unlock(&g_logLock);
}

void ShimLog(const char *fmt, ...) { va_list ap; va_start(ap, fmt); LogV(fmt, ap); va_end(ap); }

void ShimLogOnce(const char *key, const char *fmt, ...) {
    static NSMutableSet *seen; static dispatch_once_t o; dispatch_once(&o, ^{ seen = [NSMutableSet set]; });
    NSString *k = @(key);
    @synchronized (seen) { if ([seen containsObject:k]) return; [seen addObject:k]; }
    va_list ap; va_start(ap, fmt); LogV(fmt, ap); va_end(ap);
}

// ---------------------------------------------------------------- 설정
static NSDictionary *Config(void) {
    static NSDictionary *c; static dispatch_once_t o;
    dispatch_once(&o, ^{
        NSString *p = [DocumentsDir() stringByAppendingPathComponent:@"ADOFAIShim.plist"];
        c = [NSDictionary dictionaryWithContentsOfFile:p] ?: @{};
        if (c.count) ShimLog("config: %s", c.description.UTF8String);
    });
    return c;
}
double ShimCfgNum(const char *key, double def) { id v = Config()[@(key)]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : def; }
bool ShimCfgBool(const char *key, bool def) { id v = Config()[@(key)]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : def; }

// ---------------------------------------------------------------- GOT 훅
static int HookImage(const struct mach_header_64 *mh, const char *sym, void *target, void *repl) {
    static const char *segs[] = { "__DATA_CONST", "__DATA", "__AUTH_CONST" };
    static const char *sects[] = { "__got", "__auth_got", "__la_symbol_ptr" };
    int n = 0;
    for (int s = 0; s < 3; s++) for (int t = 0; t < 3; t++) {
        unsigned long size = 0;
        void **p = (void **)getsectiondata(mh, segs[s], sects[t], &size);
        if (!p) continue;
        for (unsigned long i = 0; i < size / sizeof(void *); i++) {
            if (p[i] != target) continue;
            vm_address_t page = (vm_address_t)&p[i] & ~(vm_page_size - 1);
            kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            if (kr != KERN_SUCCESS) { ShimLog("hook %s: vm_protect failed %d", sym, kr); continue; }
            p[i] = repl; n++;
            vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ);
        }
    }
    return n;
}

int ShimHookImport(const char *image_name_part, const char *sym, void *repl, void **orig) {
    void *target = dlsym(RTLD_DEFAULT, sym);
    if (!target) { ShimLog("hook %s: symbol not found", sym); return 0; }
    if (orig) *orig = target;
    int n = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, image_name_part)) continue;
        n += HookImage((const struct mach_header_64 *)_dyld_get_image_header(i), sym, target, repl);
    }
    ShimLog("hook %s in %s: %d slot(s)", sym, image_name_part, n);
    return n;
}

// 나중에 로드되는 이미지(dlopen 되는 플러그인)에도 같은 훅을 걸기 위해 기록해 둔다
typedef struct { const char *img, *sym; void *repl; } LateHook;
static LateHook g_late[32]; static int g_nlate;
void ShimHookLater(const char *img, const char *sym, void *repl) { if (g_nlate < 32) g_late[g_nlate++] = (LateHook){ img, sym, repl }; }
static void OnImageAdded(const struct mach_header *mh, intptr_t slide) {
    Dl_info di;
    if (!dladdr(mh, &di) || !di.dli_fname) return;
    for (int i = 0; i < g_nlate; i++) {
        if (!strstr(di.dli_fname, g_late[i].img)) continue;
        void *target = dlsym(RTLD_DEFAULT, g_late[i].sym);
        int n = target ? HookImage((const struct mach_header_64 *)mh, g_late[i].sym, target, g_late[i].repl) : 0;
        if (n) ShimLog("hook %s in %s (loaded later): %d slot(s)", g_late[i].sym, di.dli_fname, n);
    }
}

// ---------------------------------------------------------------- 시작
__attribute__((constructor)) static void ShimInit(void) {
    struct utsname u; uname(&u);
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    ShimLog("ADOFAIShim start: %s iOS %s, bundle %s, game %s",
            u.machine, UIDevice.currentDevice.systemVersion.UTF8String,
            [NSBundle mainBundle].bundlePath.UTF8String,
            [info[@"CFBundleShortVersionString"] ?: @"?" UTF8String]);
    ShimMonoInstall();
    ShimAudioInstall();
    _dyld_register_func_for_add_image(OnImageAdded);
}
