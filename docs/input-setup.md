# 기존 Windows 스타일 입력 설정 준비

WindowBridge의 창 전환은 단독으로 동작하지만, 키보드·마우스 통합 제어는 Karabiner-Elements와 LinearMouse의 기존 설정을 관리합니다. 이 저장소에는 원저자의 실제 장치 목록이나 개인 설정 백업을 포함하지 않습니다.

## 키보드

1. 공식 사이트에서 Karabiner-Elements를 설치하고 안내에 따라 권한을 허용합니다.
2. EventViewer의 Devices에서 사용할 키보드의 `vendor_id`와 `product_id`를 확인합니다.
3. `examples/karabiner-windows-rules.json`의 예시 ID `4660`, `22136`을 자신의 키보드 ID로 바꿉니다. 규칙의 description은 통합 설정이 식별에 사용하므로 유지하세요.
4. 원래 `~/.config/karabiner/karabiner.json`을 개인 폴더에 백업합니다. 예제는 complex modifications import용 파일입니다. 전체 설정 파일에 그대로 덮어쓰지 마세요.
5. 수정한 예제를 `~/.config/karabiner/assets/complex_modifications/`에 두고 Karabiner의 Complex Modifications에서 필요한 규칙을 추가합니다. 선택한 프로필을 사용해야 합니다.

규칙에는 오른쪽 한영/LANG1·Alt → Caps Lock, Alt+F4, Finder 단축키, 일반 Ctrl 단축키와 탐색키가 포함됩니다. 새 예제는 unshifted Ctrl+A/C/V를 왼쪽 Ctrl에만 적용해 Codex와 IDE에서도 Command+A/C/V로 바꿉니다. 터미널 앱, VM, 원격 데스크톱 예외는 유지합니다. 기존 설정 파일은 일부 개발 도구에만 이 규칙을 적용할 수 있으므로 WindowBridge에서 새 항목이 혼합 상태로 표시되면 켜고 ‘변경 적용’을 눌러 확장하세요. Shift+Ctrl+A/C/V는 기존 규칙대로 유지됩니다. 한영 전환은 macOS 입력 소스에서 Caps Lock을 ABC/한글 전환으로 설정한 환경을 전제로 합니다.

개발 도구에서 오른쪽 Ctrl은 remap하지 않습니다. IDE 통합 터미널에서 오른쪽 Ctrl+C를 사용하면 기존 인터럽트 동작을 유지할 수 있습니다. WindowBridge에서 왼쪽 Ctrl+C/V/A를 끄면 해당 세 입력의 관리 규칙을 비활성화합니다. 설정을 변경하기 전 상태로 되돌리려면 ‘백업·복원’의 마지막 적용 복원을 사용하세요.

기존 hidutil 보완 설정이 없다면 Karabiner의 한영 규칙만으로 사용할 수 있지만 WindowBridge의 한영 on/off 제어는 사용할 수 없습니다. 현재 버전은 `com.codex.hangul-key-remap.plist`를 사용하는 기존 one-shot RunAtLoad 설정을 함께 제어하도록 만들어졌습니다. 다른 이름이나 구조를 쓰는 장치에서는 고급 설정을 사용하세요. 관리되는 두 원본(LA 파일과 현재 hidutil)의 다른 키 매핑을 보존하고, 반복 실행 트리거가 있는 LaunchAgent는 변경하지 않습니다.

## 마우스

1. 공식 사이트에서 LinearMouse를 설치하고 손쉬운 사용 권한을 허용합니다.
2. 기존 설정을 먼저 백업합니다.
3. `examples/linearmouse.json`은 마우스 전체에 적용되는 일반 예제입니다. 기존 schemes가 있다면 해당 내용을 병합하고 사용자 장치별 규칙을 보존하세요.
4. WindowBridge의 마우스 탭에서 현재 값이 읽히는지 확인합니다.

권장 예시는 추가 휠 반전 OFF, 부드러운 스크롤 OFF, 세로 간격 3입니다. 자연스러운 스크롤·관성·기본 휠 배율은 WindowBridge에서 별도로 확인하고 적용합니다.

## 적용 전후

WindowBridge는 체크만 바꿔서는 저장하지 않습니다. ‘변경 적용’을 누르면 먼저 로컬 백업을 만들며, 파일이 다른 앱에서 바뀌었으면 중단합니다. 무변경 적용은 파일을 수정하지 않습니다. 백업에는 개인 설정이 들어갈 수 있으므로 GitHub에 올리지 마세요.

입력 설정 예제는 다음 공식 형식을 따릅니다.

- [Karabiner complex modifications](https://karabiner-elements.pqrs.org/docs/manual/configuration/add-your-own-complex-modifications/)
- [Karabiner device conditions](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/conditions/device/)
- [LinearMouse](https://linearmouse.app/)
