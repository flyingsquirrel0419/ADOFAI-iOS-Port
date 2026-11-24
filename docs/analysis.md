# A Dance of Fire and Ice (Steam Mac) → iOS: 분석

작성 2026-11-24. 대상: 스팀 맥 빌드 v3.4.0 (app 977950, depot 977952/977955), 기기 iPhone 15 Pro / iOS 27.2 / LiveContainer(메모리 증가).

## 빌드 정보
- Unity **6000.3.25f1** (e1dba0a9aba4), Mono 스크립팅 백엔드 (IL2CPP 아님)
- Mono 런타임 6.13.0, 커밋 `explicit/9d7c9afd` = `Unity-Technologies/mono@9d7c9afd266e523029fb0cab48e944e528e61e68` (공개, 2026-08-06)
- 모든 Mach-O가 universal (x86_64 + arm64), minos macOS 11~12
- `libmonobdwgc-2.0.dylib`에 **인터프리터 포함** (`Interpreter: yes`, `--full-aot-interp`, `mono_jit_set_aot_mode`)

## 핵심 블로커와 해결 방향
iOS는 사이드로드 앱의 런타임 코드 생성(JIT)을 금지 → Mono JIT 불가.

해결: **MONO_AOT_MODE_INTERP** (Xamarin.iOS 인터프리터 방식, `mono/mini/driver.c`)
- `mono_aot_only = TRUE`, `mono_use_interpreter = TRUE`, `use_aot_trampolines = TRUE`
- C# 코드는 인터프리터가 실행, 트램폴린/interp_in 래퍼는 AOT 이미지에서 로드 → 실행 중 코드 생성 없음
- 필요한 것: 같은 커밋의 Mono AOT 컴파일러로 `--aot=interp` 이미지 생성 (mscorlib 등 클래스 라이브러리는 같은 커밋 소스에서 직접 빌드 가능 → 게임 파일 배포 불필요)
- 게임 어셈블리(Assembly-CSharp 등)의 reverse P/Invoke 콜백용 래퍼: 사용자 기기/PC에서 사용자 본인 파일로 생성하거나 런타임 대체 (조사 필요)
- 주입 지점: UnityPlayer가 `dlsym`으로 찾는 `mono_jit_parse_options` / `mono_jit_init_version` 앞에서 shim이 `mono_jit_set_aot_mode(MONO_AOT_MODE_INTERP)` 호출

위험: 인터프리터 성능 (C# 로직 수~수십 배 느림). 렌더링·오디오는 네이티브라 영향 적음. 판정 타이밍 실측 필요.

## UnityPlayer.dylib 맥 전용 import (arm64)
| 라이브러리 | 개수 | 내용 / 대응 |
|---|---|---|
| AppKit | 50 | NSApplication/NSWindow/NSView/NSViewController/NSEvent/NSScreen/NSCursor/NSPasteboard/NSWorkspace, 접근성 상수 → shim (CyPort MacShim 재사용) |
| IOKit | 50 | IOHID* (입력), IOPS* (배터리), IORegistry*, 전원 → 스텁/대체 |
| Carbon | 11 | TIS* 키보드 레이아웃, GetCurrentEventTime → shim |
| CoreServices | 7 | UCKeyTranslate → shim, 나머지 libSystem 수학 함수 |
| AudioUnit | 10 | iOS AudioToolbox에 존재 → 경로만 변경 (HAL Output → RemoteIO 서브타입 교정 필요) |
| CoreAudio | 10 | AudioObject*/AudioDevice*/AudioHardware* (HAL) → 스텁 |
| OpenGL | 19 | Metal 사용 → 스텁 |
| IOSurface | 5 | iOS IOSurface.framework 존재 → 경로 변경 |

## 플러그인
| 파일 | 의존 | 대응 |
|---|---|---|
| libmonobdwgc / libmono-native / libMonoPosixHelper | libSystem, CF, Foundation, z, iconv (+GSS) | 리타겟만 (GSS → 스텁) |
| libsteam_api.dylib | libc++ | 대체 라이브러리 (본인 계정 세션 기반, 소유 확인만) |
| Rewired_MacOS.bundle | GameController, CoreHaptics | iOS에 존재 → 리타겟 |
| skyhook.bundle | IOKit, AppKit | 비동기 키 입력 훅 → 터치 입력 경로로 대체 |
| adofaiplatformhelper.bundle | AudioUnit, CoreAudio, OpenAL, CoreMIDI | 확인 필요 (OpenAL iOS 존재 여부) |
| RDMacPlugin.bundle | AppKit, Cocoa | shim |
| ufb.dylib (파일 브라우저) | AppKit, CloudKit, CoreData | shim / UIDocumentPicker |
| discord_game_sdk.dylib | CoreServices, Security | 로드 안 하게 (스텁) |
| unitypurchasing.bundle | – | 스텁 |
| lib_burst_generated.bundle | – | 리타겟 (AOT 네이티브 코드) |

## 진행 단계
1. **Mono 인터프리터 검증 (CI, macOS 러너)**: 같은 커밋 Mono 빌드 → 클래스 라이브러리 `--aot=interp` → JIT 권한 없는 hardened runtime 프로세스에서 interp 모드 실행 → 코드 생성 0 확인
2. 리타겟 + 기본 shim → 타이틀 화면
3. 오디오 / 터치 입력 / 판정 지연
4. Steam 대체, 클라우드 세이브, IPA (GitHub Actions)

원칙: 게임 파일은 저장소/IPA에 포함하지 않음. 사용자 본인 계정으로 받은 파일을 사용자 기기에서 변환.

## AOT 이미지 호환성 (aot-runtime.c)
- AOT 이미지의 `runtime_version` 이 런타임의 `mono_get_runtime_build_info()` 와 같아야 로드됨.
- 게임 런타임(임베디드)은 `mono_build_date` 가 NULL → `"6.13.0 (explicit/9d7c9afd)"`.
- `mono` 실행 파일로 AOT 하면 main.c 가 build_date 를 넣어서 `"6.13.0 (explicit/9d7c9afd <날짜>)"` 가 됨 → 불일치.
  → 2단계에서 게임용 AOT는 build_date 를 넣지 않는 임베딩 드라이버로 컴파일하거나, 이미지의 문자열을 맞춘다.
- 커밋 해시 길이도 맞춰야 함 (CI 얕은 클론은 7자리 → `core.abbrev 8`).
