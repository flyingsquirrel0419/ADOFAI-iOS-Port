// shim 이 기기에서 하는 Mono 초기화를 그대로 흉내 내는 임베딩 호스트 (Unity 가 하는 순서 + shim/MonoInterp.c)
//   host <aot dylib> <assemblies dir> <exe> [args]
//  1. 정적 AOT 이미지 dylib 를 dlopen, mono_aot_module_mscorlib_info 를 mono_aot_register_module 로 등록
//  2. mono_jit_set_aot_mode(MONO_AOT_MODE_INTERP)
//  3. mono_jit_init_version -> 어셈블리 실행
// mono_build_date 를 설정하지 않으므로 runtime_version 은 게임 런타임처럼 "6.13.0 (explicit/9d7c9afd)"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef void *MonoDomain, *MonoAssembly;
extern void mono_aot_register_module(void **info);
extern void mono_jit_set_aot_mode(int mode);
extern void mono_set_assemblies_path(const char *path);
extern MonoDomain *mono_jit_init_version(const char *name, const char *ver);
extern MonoAssembly *mono_domain_assembly_open(MonoDomain *d, const char *name);
extern int mono_jit_exec(MonoDomain *d, MonoAssembly *a, int argc, char *argv[]);
extern char *mono_get_runtime_build_info(void);

int main(int argc, char *argv[]) {
    if (argc < 4) { fprintf(stderr, "usage: host aot.dylib asmdir exe [args]\n"); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "HOST: dlopen %s: %s\n", argv[1], dlerror()); return 3; }
    // 심볼은 MonoAotFileInfo 를 가리키는 포인터를 가리킨다 (aot-compiler.c emit_aot_file_info)
    void ***sym = dlsym(h, "mono_aot_module_mscorlib_info");
    if (!sym) { fprintf(stderr, "HOST: no mono_aot_module_mscorlib_info\n"); return 4; }
    mono_aot_register_module(*sym);
    fprintf(stderr, "HOST: registered static AOT module mscorlib; runtime build info '%s'\n", mono_get_runtime_build_info());
    mono_jit_set_aot_mode(5 /* MONO_AOT_MODE_INTERP */);
    mono_set_assemblies_path(argv[2]);
    MonoDomain *d = mono_jit_init_version("host", "v4.0.30319");
    if (!d) { fprintf(stderr, "HOST: init failed\n"); return 5; }
    MonoAssembly *a = mono_domain_assembly_open(d, argv[3]);
    if (!a) { fprintf(stderr, "HOST: cannot open %s\n", argv[3]); return 6; }
    return mono_jit_exec(d, a, argc - 3, argv + 3);
}
