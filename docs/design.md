# Bartender.spoon 설계

macOS 27(Golden Gate)의 메뉴바 오버플로(`«`)를 이용해, 사용자가 고른 메뉴바 항목만 접는
Hammerspoon Spoon. 접힌 항목을 보는 것은 시스템 `«` 버튼이 담당한다. 이 Spoon 은 "무엇을
접을지"만 제어한다.

## 배경: macOS 27 메뉴바 동작 (2026-09-16 실측, 27.0 26A428)

- 메뉴바 항목이 예산을 넘으면 시스템이 **왼쪽부터 순서대로** `«` 오버플로로 접는다.
  `«` 는 시스템 프로세스 MenuBarAgent 의 항목이며 AX description 은 "Show Hidden Menu Bar Items".
- 항목 하나가 너무 넓어 들어가지 못하면 그 항목만 접히고 나머지는 되돌아온다.
  내장 1512pt 화면에서 구분자 폭 200 은 왼쪽 항목을 밀어냈고, 400 은 구분자 자신까지 접혔고,
  800 이상은 구분자만 접히고 나머지가 전부 복귀했다.
- 예전 방식(폭 10000 구분자로 화면 밖으로 밀어내기)은 동작하지 않는다. 시스템이 그 항목을 접는다.
- **접힘 판정**: 항목의 AX x 좌표가 `«` 의 x 보다 작으면 접힌 것이다. 실측한 모든 폭에서 일치했다.
  접힌 항목의 window frame 과 AX 좌표는 옛 값을 유지하므로 좌표 자체로는 판정할 수 없고,
  반드시 `«` 와 비교해야 한다.
- "디스플레이마다 별도 Space" 가 꺼져 있으면 메뉴바는 주 디스플레이에만 뜬다. 이 맥이 그 설정이다.
- `hs.menubar` 항목에 `hs.canvas` 로 만든 투명 이미지를 `setIcon` 하면 이미지 폭이 항목 폭이 된다.
  autosaveName 을 주면 ⌘+드래그 위치가 재시작 후에도 유지된다.

이 동작은 문서화된 API 가 아니라 27.0 첫 빌드의 관찰 결과다. OS 업데이트 후에는 재검증한다.

## 사용법

1. Hammerspoon 이 구분자(투명 항목)를 메뉴바에 만든다.
2. 사용자가 ⌘+드래그로 구분자와 다른 항목을 배치한다. 구분자 **왼쪽 = 접힘**, 오른쪽 = 표시.
3. 접힌 항목을 보려면 시스템 `«` 를 누른다.

설정 파일, 단축키, UI 는 없다.

## 구성 요소

### 구분자 (`sep`)
- `hs.menubar.new(true, "bartender_sep")` 하나. 아이콘은 `hs.canvas` 로 만든 alpha 0.001 의 사각형.
- `setWidth(w)`: 폭 w 의 투명 이미지를 만들어 `setIcon`. w=0 이면 폭 1 이미지(항목 유지, 사실상 보이지 않음).

### 판독기 (`probe`)
- 모든 실행 중 앱의 `AXExtrasMenuBar` 자식을 모아 `{pid, title, x}` 목록으로 만든다 (`hs.axuielement`).
- `«` 의 x 를 찾는다. 없으면 `nil` (전부 들어간 상태).
- 구분자 자신은 Hammerspoon pid 의 자식 중 `bartender_sep` 로 식별한다. hs.menubar 항목의 AX title 이
  비어 있으면 구분자 `frame()` 의 x 와 대조해 찾는다. 이 식별 방식은 구현 시 실측으로 정한다.
- `isHidden(item)`: `«` 가 있고 `item.x < «.x`.

### 탐색기 (`fit`)
목표: 구분자 바로 왼쪽 항목은 접히고, 구분자는 보이는 **가장 작은 폭**.

1. 폭 0 으로 두고 판독. `«` 왼쪽 항목이 있으면 그것들은 어차피 접힐 것이므로 무시한다.
   구분자보다 왼쪽에 있는 항목 중 가장 오른쪽 것을 `neighbor` 로 잡는다. 없으면 폭 0 으로 끝낸다.
2. `lo=0, hi=600` 이분 탐색. 각 단계에서 폭을 정하고 150ms 뒤 판독한다.
   - 구분자가 접혔으면 → `hi = mid`
   - `neighbor` 가 보이면 → `lo = mid`
   - `neighbor` 접힘 & 구분자 보임 → `hi = mid` (더 작은 값 시도)
   폭 차이가 4pt 이하이면 종료하고 조건을 만족한 마지막 값을 적용한다.
3. 만족하는 값이 없으면(오른쪽 항목만으로 예산 초과 등) 폭 0 으로 두고 `hs.printf` 로 남긴다.

탐색 중 하나의 실행만 허용한다. 실행 중에 요청이 오면 끝난 뒤 한 번 더 돈다.

### 트리거
- `hs.screen.watcher` — 주 디스플레이·해상도 변경
- `hs.application.watcher` — launched / terminated / activated
- `hs.timer.doEvery(60, ...)` — 앱이 자기 항목 폭을 바꾼 경우의 보정
- 세 경로 모두 `schedule()` 을 부르고, `schedule()` 은 0.5초 디바운스 후 `fit()` 을 호출한다.

## 파일

```
Bartender.spoon/
  init.lua        Spoon 본체 (sep, probe, fit, 트리거)
  docs/design.md  이 문서
  README.md       설치·사용법
  tests/          probe 결과를 가짜 표로 주입해 fit 의 결정 로직을 검증하는 순수 Lua 테스트
```

`~/.hammerspoon/init.lua` 에 `hs.loadSpoon("Bartender"):start()`.

## 테스트

- `fit` 의 결정 로직(다음 폭 선택, 종료 조건)은 판독 함수를 인자로 받는 순수 함수로 분리해
  가짜 좌표 표로 단위 테스트한다. `lua tests/run.lua` 로 Hammerspoon 없이 실행.
- 실제 메뉴바 동작은 `screencapture -R0,0,<width>,30` 으로 수동 확인한다.

## 범위 밖

- 단축키로 전부 펼치기 / 자동 재접기 (필요해지면 `setWidth(0)` 토글로 추가)
- 여러 디스플레이에 메뉴바가 동시에 뜨는 구성 ("디스플레이마다 별도 Space" 켬)
- 접힌 항목의 미리보기·검색 등 Bartender 앱의 부가 기능
