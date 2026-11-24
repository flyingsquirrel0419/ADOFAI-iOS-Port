// iOS(사이드로드 앱)의 "실행 중 코드 생성 금지"를 macOS 에서 흉내 내는 인터포저.
//   DYLD_INSERT_LIBRARIES=libnojit.dylib mono ...
//
// iOS 에서는 MAP_JIT / 익명 메모리의 PROT_EXEC 가 허용되지 않는다. 그런데 Mono 는 인터프리터 모드에서도
// 코드와 상관없는 메모리(해저드 포인터 테이블 등)를 MAP_JIT 나 PROT_EXEC 를 붙여 잡는다.
// shim 은 이것을 "실행 권한만 떼고 할당"으로 바꾼다 (shim/MonoInterp.c). 여기서도 똑같이 한다:
// - 익명 mmap 의 MAP_JIT, PROT_EXEC -> 떼고 할당 (실행하면 그 자리에서 크래시 = 숨은 JIT 가 있으면 드러남)
// - mprotect 의 PROT_EXEC          -> 떼고 적용
// - pthread_jit_write_protect_np    -> 아무것도 안 함
// 파일에서 매핑하는 코드(dylib, AOT 이미지)는 iOS 에서도 되므로 그대로 둔다.
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#define INTERPOSE(repl, orig) \
    __attribute__((used)) static struct { const void *r, *o; } _ip_##orig __attribute__((section("__DATA,__interpose"))) = { (const void *)repl, (const void *)orig };

static int g_n;

static void *nj_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    if ((flags & MAP_JIT) || ((prot & PROT_EXEC) && (flags & MAP_ANON))) {
        if (g_n++ < 8) fprintf(stderr, "NOJIT: mmap(len=%zu prot=%#x flags=%#x) -> without JIT/EXEC\n", len, prot, flags);
        flags &= ~MAP_JIT;
        prot &= ~PROT_EXEC;
    }
    return mmap(addr, len, prot, flags, fd, off);
}
INTERPOSE(nj_mmap, mmap)

static int nj_mprotect(void *addr, size_t len, int prot) {
    if (prot & PROT_EXEC) {
        // 파일에서 매핑된 코드(dyld 가 하는 것)는 여기로 안 온다. 익명 메모리를 실행 가능하게 하려는 것 = JIT
        if (g_n++ < 8) fprintf(stderr, "NOJIT: mprotect(%p, %zu, prot=%#x) -> without EXEC\n", addr, len, prot);
        prot &= ~PROT_EXEC;
    }
    return mprotect(addr, len, prot);
}
INTERPOSE(nj_mprotect, mprotect)

static void nj_jit_wp(int enabled) {
    static int said;
    if (!said++) fprintf(stderr, "NOJIT: pthread_jit_write_protect_np(%d) ignored\n", enabled);
}
INTERPOSE(nj_jit_wp, pthread_jit_write_protect_np)

__attribute__((constructor)) static void nj_init(void) { fprintf(stderr, "NOJIT: active (iOS-like: no executable anonymous memory)\n"); }
