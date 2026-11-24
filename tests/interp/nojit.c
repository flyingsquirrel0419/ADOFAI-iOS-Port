// iOS(사이드로드 앱)의 "실행 중 코드 생성 금지"를 macOS 에서 흉내 내는 인터포저.
//   DYLD_INSERT_LIBRARIES=libnojit.dylib mono ...
// - 익명 메모리를 실행 가능으로 mmap (PROT_EXEC 또는 MAP_JIT)          -> 거부 (EPERM)
// - mprotect 로 실행 권한 추가                                          -> 거부 (EPERM)
// - pthread_jit_write_protect_np (JIT 페이지 쓰기/실행 전환)              -> 중단
// 파일에서 매핑하는 코드(dylib, AOT 이미지)는 iOS 에서도 되므로 허용한다.
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#define INTERPOSE(repl, orig) \
    __attribute__((used)) static struct { const void *r, *o; } _ip_##orig __attribute__((section("__DATA,__interpose"))) = { (const void *)repl, (const void *)orig };

static int g_blocked;

static void *nj_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    if ((flags & MAP_JIT) || ((prot & PROT_EXEC) && fd == -1)) {
        if (g_blocked++ < 5) fprintf(stderr, "NOJIT: blocked mmap(len=%zu prot=%#x flags=%#x fd=%d)\n", len, prot, flags, fd);
        errno = EPERM;
        return MAP_FAILED;
    }
    return mmap(addr, len, prot, flags, fd, off);
}
INTERPOSE(nj_mmap, mmap)

static int nj_mprotect(void *addr, size_t len, int prot) {
    if (prot & PROT_EXEC) {
        if (g_blocked++ < 5) fprintf(stderr, "NOJIT: blocked mprotect(%p, %zu, prot=%#x)\n", addr, len, prot);
        errno = EPERM;
        return -1;
    }
    return mprotect(addr, len, prot);
}
INTERPOSE(nj_mprotect, mprotect)

static void nj_jit_wp(int enabled) {
    fprintf(stderr, "NOJIT: pthread_jit_write_protect_np(%d) called -> abort (iOS would kill the app)\n", enabled);
    abort();
}
INTERPOSE(nj_jit_wp, pthread_jit_write_protect_np)

__attribute__((constructor)) static void nj_init(void) { fprintf(stderr, "NOJIT: active (iOS-like: no runtime code generation)\n"); }
