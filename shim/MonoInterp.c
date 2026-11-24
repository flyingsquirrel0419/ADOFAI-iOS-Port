// Mono 를 JIT 없이(MONO_AOT_MODE_INTERP) 돌리게 한다.
//
// UnityPlayer 는 libmonobdwgc-2.0.dylib 를 dlopen 하고 mono_* 함수를 dlsym 으로 찾는다.
// UnityPlayer 의 dlsym import 슬롯을 우리 함수로 바꿔서, "mono_jit_init_version" 을 찾을 때
// 우리 래퍼를 돌려준다. 래퍼는 진짜 init 전에 mono_jit_set_aot_mode(INTERP) 를 부른다.
//
// MONO_AOT_MODE_INTERP (mono/mini/driver.c):
//   mono_aot_only = TRUE, mono_use_interpreter = TRUE, use_aot_trampolines = TRUE
//   -> C# 는 인터프리터, 트램폴린은 mscorlib.dll.dylib 등 AOT 이미지에서. 실행 중 코드 생성 없음.
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include "Shim.h"

void ShimHookLater(const char *img, const char *sym, void *repl);

// mono/mini/jit.h MonoAotMode
enum { MONO_AOT_MODE_NONE, MONO_AOT_MODE_NORMAL, MONO_AOT_MODE_HYBRID, MONO_AOT_MODE_FULL, MONO_AOT_MODE_LLVMONLY,
       MONO_AOT_MODE_INTERP, MONO_AOT_MODE_INTERP_LLVMONLY, MONO_AOT_MODE_LLVMONLY_INTERP, MONO_AOT_MODE_INTERP_ONLY };

static void *(*real_dlsym)(void *, const char *);
static void *(*real_init)(const char *, const char *);
static void *g_monoHandle;

// 정적 AOT 모듈 등록: Contents/Frameworks/libADOFAIAot.dylib 에 링크된 mscorlib 의 AOT 이미지
// (--aot=interp,static 으로 만든 것; CI mono-interp 산출물). 경로 검색 대신 mono_aot_register_module 로 넘긴다.
static void RegisterAotModules(void) {
    void (*reg)(void **) = (void (*)(void **))real_dlsym(g_monoHandle ?: RTLD_DEFAULT, "mono_aot_register_module");
    if (!reg) { ShimLog("mono: mono_aot_register_module not found"); return; }
    // LiveContainer 에서는 게임 실행 파일이 dlopen 되므로 @rpath 대신 shim 과 같은 폴더의 절대 경로를 쓴다
    Dl_info di; char path[1024] = "libADOFAIAot.dylib";
    if (dladdr((void *)RegisterAotModules, &di) && di.dli_fname) {
        snprintf(path, sizeof path, "%s", di.dli_fname);
        char *slash = strrchr(path, '/');
        if (slash) snprintf(slash + 1, sizeof path - (size_t)(slash + 1 - path), "libADOFAIAot.dylib");
    }
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { ShimLog("mono: libADOFAIAot.dylib not loaded (%s) - interpreter needs the mscorlib AOT image", dlerror() ?: "?"); return; }
    static const char *mods[] = { "mscorlib", "System", "System.Core", "Mono.Security", NULL };   // aname 그대로 (aot-compiler.c)
    for (int i = 0; mods[i]; i++) {
        char sym[128];
        snprintf(sym, sizeof sym, "mono_aot_module_%s_info", mods[i]);
        void **info = (void **)dlsym(h, sym);
        if (!info) continue;
        reg(info);
        ShimLog("mono: registered static AOT module %s", mods[i]);
    }
}

static void *shim_mono_jit_init_version(const char *domain, const char *version) {
    RegisterAotModules();
    int mode = (int)ShimCfgNum("MonoAotMode", MONO_AOT_MODE_INTERP);
    void (*set_mode)(int) = (void (*)(int))real_dlsym(g_monoHandle ?: RTLD_DEFAULT, "mono_jit_set_aot_mode");
    if (set_mode && mode >= 0) {
        set_mode(mode);
        ShimLog("mono: mono_jit_set_aot_mode(%d)%s", mode, mode == MONO_AOT_MODE_INTERP ? " = INTERP (interpreter + AOT trampolines, no JIT)" : "");
    } else {
        ShimLog("mono: mono_jit_set_aot_mode NOT called (fn %p, mode %d) - Mono will try to JIT", (void *)set_mode, mode);
    }
    void *dom = real_init(domain, version);
    ShimLog("mono: mono_jit_init_version(%s, %s) -> %p", domain ?: "", version ?: "", dom);
    return dom;
}

static void *shim_dlsym(void *handle, const char *name) {
    void *p = real_dlsym(handle, name);
    if (name && !strncmp(name, "mono_", 5)) {
        if (!g_monoHandle) g_monoHandle = handle;
        if (!strcmp(name, "mono_jit_init_version") && p) {
            real_init = (void *(*)(const char *, const char *))p;
            ShimLog("mono: dlsym(mono_jit_init_version) -> shim wrapper");
            return (void *)shim_mono_jit_init_version;
        }
        if (!p) ShimLogOnce(name, "mono: dlsym(%s) = NULL", name);
    }
    return p;
}

static void *(*real_dlopen)(const char *, int);
static void *shim_dlopen(const char *path, int mode) {
    void *h = real_dlopen(path, mode);
    if (path) {
        if (!h) ShimLog("dlopen %s FAILED: %s", path, dlerror() ?: "?");
        else ShimLogOnce(path, "dlopen %s ok", path);
    }
    return h;
}

// ---------------------------------------------------------------- 실행 가능 익명 메모리 요청 정리
// Mono 는 인터프리터 모드에서도 코드와 상관없는 메모리(해저드 포인터 테이블, 코드 매니저 예약 등)를
// MAP_JIT 나 PROT_EXEC 로 잡는다. iOS 는 이걸 거부해서 Mono 초기화가 assert 로 죽는다
// (CI: "Assertion at hazard-pointer.c:131, condition `hazard_table != NULL'").
// 실행 권한만 떼고 할당해 준다. Mono 가 정말 그 메모리에서 코드를 실행하려 하면 그 자리에서 크래시가 난다.
#include <sys/mman.h>
static void *shim_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    if ((flags & MAP_JIT) || ((prot & PROT_EXEC) && (flags & MAP_ANON))) {
        static int n;
        if (n++ < 6) ShimLog("mono: mmap(len=%zu prot=%#x flags=%#x) -> without JIT/EXEC", len, prot, flags);
        flags &= ~MAP_JIT; prot &= ~PROT_EXEC;
    }
    return mmap(addr, len, prot, flags, fd, off);
}
static int shim_mprotect(void *addr, size_t len, int prot) {
    if (prot & PROT_EXEC) {
        static int n;
        if (n++ < 6) ShimLog("mono: mprotect(%p, %zu, %#x) -> without EXEC", addr, len, prot);
        prot &= ~PROT_EXEC;
    }
    return mprotect(addr, len, prot);
}
static void shim_jit_write_protect(int enabled) { ShimLogOnce("jitwp", "mono: pthread_jit_write_protect_np(%d) ignored", enabled); }

void ShimMonoInstall(void) {
    // libmonobdwgc 는 UnityPlayer 가 나중에 dlopen 한다 -> 로드될 때 import 슬롯을 바꾼다
    ShimHookLater("libmonobdwgc", "mmap", (void *)shim_mmap);
    ShimHookLater("libmonobdwgc", "mprotect", (void *)shim_mprotect);
    ShimHookLater("libmonobdwgc", "pthread_jit_write_protect_np", (void *)shim_jit_write_protect);
    real_dlsym = (void *(*)(void *, const char *))dlsym(RTLD_DEFAULT, "dlsym");
    void *orig;
    ShimHookImport("UnityPlayer", "dlsym", (void *)shim_dlsym, &orig);
    if (orig) real_dlsym = (void *(*)(void *, const char *))orig;
    ShimHookImport("UnityPlayer", "dlopen", (void *)shim_dlopen, (void **)&real_dlopen);
    if (!real_dlopen) real_dlopen = dlopen;
}
