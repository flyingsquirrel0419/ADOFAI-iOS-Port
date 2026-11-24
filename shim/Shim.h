// ADOFAIShim - 얼불춤 맥 빌드(Unity 6000.3, Mono)를 iOS에서 돌리기 위한 shim 공용 선언
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- 로그: Documents/adofaishim.log (+ stderr). 사용자가 이 파일을 보내주면 그걸로 디버깅한다.
void ShimLog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
// 같은 key 로는 한 번만 찍는다 (스텁이 매 프레임 불리는 경우)
void ShimLogOnce(const char *key, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

// ---- 설정: Documents/ADOFAIShim.plist (없으면 기본값)
double ShimCfgNum(const char *key, double def);
bool ShimCfgBool(const char *key, bool def);

// ---- GOT 슬롯 교체 (fishhook 방식): image 이름에 name_part 가 들어간 이미지의 import 슬롯 중
//      심볼 sym 의 실제 주소를 가리키는 것을 repl 로 바꾼다. 바꾼 슬롯 수를 돌려준다. *orig 에 원래 주소.
int ShimHookImport(const char *image_name_part, const char *sym, void *repl, void **orig);

// ---- 화면 (UIKit 메인 스레드에서 갱신되는 값; 어느 스레드에서 읽어도 됨)
typedef struct {
    double w, h;        // 가로 모드 기준 포인트 크기
    double scale;       // backingScaleFactor 로 게임에 알려주는 값
    double maxFPS;
} ShimScreen;
ShimScreen ShimScreenInfo(void);

// ---- 입력 상태 (CGEventSource*State 용)
extern volatile uint8_t g_shimKeyDown[256];   // 맥 virtual key code
extern volatile uint64_t g_shimModFlags;      // NSEventModifierFlags
extern volatile uint32_t g_shimMouseButtons;

// ---- 각 모듈 초기화 (ShimCore 의 constructor 가 부름)
void ShimMonoInstall(void);
void ShimAudioInstall(void);

#ifdef __cplusplus
}
#endif
