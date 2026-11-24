# ADOFAI-iOS-Port

**A Dance of Fire and Ice** 스팀 맥 빌드를 iPhone/iPad에서 돌리기 위한 개인 포팅 프로젝트 (CyPort 방식).

> 이 저장소에는 게임 파일이 **들어 있지 않고, 앞으로도 넣지 않습니다.** 게임은 각자 본인 스팀 계정으로 받은 파일을 본인 기기에서 변환해서 씁니다.
> 모바일에서 그냥 플레이하려면 7th Beat Games의 공식 iOS판을 이용하세요.

## 왜 그냥은 안 되나
스팀 맥 빌드는 Unity **Mono** 빌드라 C# 코드를 실행 중에 JIT 컴파일합니다. iOS는 사이드로드 앱의 JIT를 막습니다.

## 접근
게임의 Mono 런타임(`Unity-Technologies/mono@9d7c9afd`)에는 인터프리터가 들어 있습니다.
`MONO_AOT_MODE_INTERP` (Xamarin.iOS 방식)로 C# 코드는 인터프리터가 돌리고, 네이티브↔매니지드 트램폴린은 미리 컴파일한 AOT 이미지에서 불러와서
실행 중 코드 생성을 없앱니다. 나머지(UnityPlayer의 AppKit 등)는 Mach-O 리타겟 + shim.

자세한 분석: [docs/analysis.md](docs/analysis.md)

## 진행 상황
- [ ] 1단계: JIT 금지 프로세스에서 Mono 인터프리터 검증 (`.github/workflows/mono-interp.yml`)
- [ ] 2단계: 리타겟 + shim → 타이틀 화면
- [ ] 3단계: 오디오 / 터치 입력 / 판정 지연
- [ ] 4단계: 스팀 연동 대체, 클라우드 세이브, IPA
