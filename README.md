# Bartender.spoon

macOS 27 의 메뉴바 오버플로(`«`)를 이용해 고른 메뉴바 항목만 접는 Hammerspoon Spoon.

투명한 **구분자** 항목 하나를 메뉴바에 두고 그 폭을 조절한다. 구분자가 넓어지면 왼쪽
항목들이 밀려나 시스템 오버플로로 접힌다. 접힌 항목을 보는 것은 시스템 `«` 가 담당한다.
이 Spoon 은 "무엇을 접을지"만 정한다.

설정 파일도, 단축키도, UI 도 없다.

## 설치

```lua
-- ~/.hammerspoon/init.lua
hs.loadSpoon("Bartender"):start()
```

`~/.hammerspoon/Spoons/Bartender.spoon/` 에 두면 된다.

## 사용법

1. `start()` 하면 메뉴바에 폭 0 의 투명한 구분자가 생긴다. 눈에 띄지 않지만 다른 항목
   사이에 19pt 쯤의 빈칸으로 자리를 차지한다.
2. **⌘ 을 누른 채 그 빈칸을 드래그**해서 원하는 자리에 놓는다.
   구분자 **왼쪽 = 접힘**, **오른쪽 = 표시**.
3. 접힌 항목을 보려면 시스템 `«` 를 누른다.

구분자 자리는 `autosaveName` 으로 저장되므로 Hammerspoon 을 다시 켜도 유지된다.

Spoon 은 화면 변경·앱 실행/종료/전환·60초 주기 보정 때마다 폭을 다시 탐색한다.
앱마다 메뉴 길이가 달라 쓸 수 있는 폭이 바뀌므로 앱 전환도 트리거에 넣었다.
한 번 탐색에 1~2초가 걸린다.

## 디버깅

```lua
spoon.Bartender:fit()        -- 지금 바로 다시 탐색
spoon.Bartender:setWidth(80) -- 구분자 폭을 직접 지정
spoon.Bartender:probe()      -- 메뉴바 판독 결과 (sep / chevronX / items)
spoon.Bartender.lastWidth    -- 마지막 탐색이 고른 폭
```

`probe()` 의 `chevronX` 가 `nil` 이면 접힌 항목이 없는 상태다.
`fit()` 이 0 을 고르면 Hammerspoon 콘솔에 이유가 남는다.

## 테스트

폭 결정 로직(`lib/fit.lua`)은 `hs.*` 를 쓰지 않는 순수 함수다. 판독 함수와 폭 설정 함수를
주입해 가짜 좌표 표로 검증한다. 독립 lua 인터프리터가 없으므로 Hammerspoon 의 Lua 로 돌린다:

```sh
osascript -e 'tell application "Hammerspoon" to execute lua code
  "return dofile(\"/Users/insoul/.hammerspoon/Spoons/Bartender.spoon/tests/run.lua\")"'
# => 32 passed, 0 failed
```

실패하면 `error` 로 올라오므로 osascript 가 0 이 아닌 상태로 끝난다.

## macOS 27 주의사항

이 Spoon 은 문서화된 API 가 아니라 macOS 27.0 의 관찰된 동작에 기댄다. **OS 를 올린 뒤에는
`docs/design.md` 의 실측 항목을 다시 확인한다.**

- 접힘 판정은 항목 AX x 와 `«` 의 x 비교로만 한다. 접힌 항목의 좌표는 옛 값이거나 `«` 쪽으로
  몰린 값이라 절대 좌표로는 판정할 수 없다.
- `«` 는 접힌 항목이 있을 때만 AX description 이 `Show Hidden Menu Bar Items` 다.
  접힌 것이 없으면 같은 버튼이 `Hide Menu Bar Items`(`»`) 로 바뀐다.
- 구분자 식별은 `setTooltip` 이 AX `AXHelp` 로 실리는 것에 의존한다.
- 노치가 있는 화면에서는 노치 뒤가 죽은 공간이라 메뉴바 예산이 눈에 보이는 것보다 훨씬 좁다.
  이미 오버플로 중이면 `fit()` 은 폭 0 을 고르고 끝낸다 — 더 접을 것이 없기 때문이다.
- 구분자를 오른쪽 끝 가까이 두면, 폭을 키워도 시스템이 접지 않고 왼쪽 항목을 노치와 앱 메뉴
  뒤로 밀어 **그냥 가려버린다**. `«` 로 다시 꺼낼 수 없으므로 그 자리는 피한다.
  `fit()` 은 이 경우 접힘을 감지하지 못해 폭 0 으로 끝낸다.
- 오버플로로 한 번 접히면 여유가 다시 생겨도 자동으로 펴지지 않는다. `«` 를 눌러 편다.
- "디스플레이마다 별도 Space" 가 켜져 있으면(메뉴바가 여러 화면에 동시에 뜨면) 범위 밖이다.

## 파일

```
init.lua        Spoon 본체 — 구분자, 판독기, 트리거
lib/fit.lua     폭 결정 로직 (순수 Lua)
tests/          fit 단위 테스트
docs/design.md  설계와 실측 근거
```
