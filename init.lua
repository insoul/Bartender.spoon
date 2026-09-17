--- === Bartender ===
---
--- macOS 27 의 메뉴바 오버플로(`«`)를 이용해 고른 항목만 접는다.
--- 투명한 구분자 항목 하나를 메뉴바에 두고, 그 폭을 조절해 왼쪽 항목들을 오버플로로 밀어낸다.
--- 구분자 왼쪽 = 접힘, 오른쪽 = 표시. 접힌 항목은 시스템 `«` 로 본다.
---
--- 필요할 때만 보이면 되는 시스템 항목(배터리·Wi-Fi)은 접는 대신 시스템 설정 → Menu Bar 의 스위치를
--- 상태에 따라 켜고 끈다. 꺼진 항목은 접힌 것이 아니라 없는 것이라 자리도 « 뒤 목록도 차지하지 않는다.
---
--- iPhone 에서 복사한 Universal Clipboard(핸드오프) 항목이 클립보드에 있으면 구분자 오른쪽 끝에 폰 글리프를
--- 띄우고, 구분자 메뉴에서 그 항목을 로컬 클립보드로 가져올 수 있게 한다. 핸드오프 항목은 클립보드 매니저가
--- 건너뛰므로 이렇게 한 번 다시 써야 Paste 같은 앱에 남는다.
---
--- 설계와 실측 근거는 docs/design.md 에 있다.

local obj = {}
obj.__index = obj

obj.name = "Bartender"
obj.version = "1.0"
obj.author = "buzz <buzz@watcha.com>"
obj.license = "MIT - https://opensource.org/licenses/MIT"
obj.homepage = "https://github.com/insoul/Bartender.spoon"

local spoonPath = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local fit = dofile(spoonPath .. "lib/fit.lua")
local guard = dofile(spoonPath .. "lib/guard.lua")
local handoff = dofile(spoonPath .. "lib/handoff.lua")
local menu = dofile(spoonPath .. "lib/menu.lua")
local place = dofile(spoonPath .. "lib/place.lua")
local rules = dofile(spoonPath .. "lib/rules.lua")

--- 시스템 항목 규칙. Battery/WiFi 를 false 로 두면 그 항목은 건드리지 않는다.
---   Battery — 전원이 빠져 배터리로 돌 때, 또는 전원이 연결돼 있어도 잔량이 batteryThreshold(%) 이하일 때 보인다.
---             batteryThreshold 가 nil 이면 배터리로 돌 때만이다.
---   WiFi    — 연결이 끊겼을 때만 보인다.
--- 이 스위치는 Spoon 이 소유한다 — 시스템 설정에서 손으로 바꿔도 다음 상태 변화 때 규칙대로 되돌아간다.
--- batteryThreshold 는 구분자 메뉴의 "배터리 표시"로도 바꿀 수 있고, 그 값은 hs.settings 에 남아 start() 때
--- 여기 적은 기본값을 덮는다. 메뉴로 한 번도 바꾸지 않았을 때만 이 값이 쓰인다.
obj.extras = { Battery = true, WiFi = true, batteryThreshold = 80 }

--- 구분자 식별: setTooltip 이 AX 의 AXHelp 로 실린다 (macOS 27.0 에서 실측 확인).
--- 툴팁은 항목 폭에 영향을 주지 않으므로 탐색을 방해하지 않는다.
local SEP_TOOLTIP = "bartender_sep"
local SEP_AUTOSAVE = "bartender_sep"

--- 시스템 항목 스위치가 저장되는 defaults 도메인. per-host(-currentHost) 이고 키는 항목 이름(Battery, WiFi),
--- 값은 정수 플래그(lib/rules.lua 의 FLAG_*)다.
local CC_DOMAIN = "com.apple.controlcenter"
--- 메뉴로 고른 배터리 임계값을 저장하는 hs.settings 키. "배터리로 돌 때만"은 false 로 저장한다 — nil 은 키 삭제라 구분이 안 된다
local SETTINGS_THRESHOLD = "Bartender.batteryThreshold"

--- MenuBarAgent 의 오버플로 버튼 하나가 설명 문자열로 상태를 알린다.
--- 접힌 항목이 있으면 « / "Show Hidden…", 없으면 » / "Hide Menu Bar Items".
local CHEVRON_HIDDEN = "Show Hidden Menu Bar Items"
local CHEVRON_EXPANDED = "Hide Menu Bar Items"

--- hs.timer 는 참조를 잃으면 GC 로 사라진다. 이 파일의 모든 타이머는 self 에 보존하고
--- stop() 에서 거둔다 — 보존하지 않으면 콜백이 오지 않아 탐색이 중간에 굳는다.

--- 폭을 바꾼 뒤 메뉴바가 자리를 잡을 때까지 기다리는 방식. 재배치는 애니메이션이라 걸리는 시간이
--- 일정하지 않으므로 고정 대기 대신, SETTLE_STEP 마다 판독해 구분자·« 위치가 두 번 연속 같으면
--- 끝낸다. SETTLE_MAX 를 넘기면 그대로 진행한다.
local SETTLE_STEP = 0.1
local SETTLE_MAX = 1.0
--- 트리거가 몰릴 때 마지막 것만 살리는 디바운스
local DEBOUNCE = 0.5
--- 앱이 제 항목 폭을 바꾼 경우를 위한 보정 주기
local CORRECTIVE = 60
--- 이 시간 안에 탐색이 끝나지 않으면 상태가 굳은 것으로 보고 되돌린다
local SEARCH_TIMEOUT = 40
--- placeRight 가 이 시간 안에 끝나지 않으면 굳은 것으로 보고 되돌린다
local PLACE_TIMEOUT = 10
--- 막 켜진 시스템 항목이 메뉴바에 나타나기를 기다리는 시간(초)
local APPEAR_DELAY = 1.0
--- ⌘+드래그 한 걸음 사이의 간격(마이크로초)
local DRAG_STEP_US = 15000
--- 아이콘 높이. 메뉴바 항목의 표준 높이다
local ICON_HEIGHT = 22
--- 핸드오프 배지(폰 글리프)가 차지하는 폭. 구분자 이미지의 오른쪽 끝에 그린다
local BADGE_WIDTH = 16
--- 핸드오프 항목 감시 주기(초). 타입 목록만 조회하므로 한 번에 20µs 수준이다
local HANDOFF_POLL = 0.5
--- 메뉴바 줄로 인정하는 y 범위. 이 밖의 항목은 시스템이 화면 밖에 치워 둔 것이다
local MENUBAR_ROW_HEIGHT = 40

--- 시스템이 자리를 고정하는 MenuBarAgent 항목. 접히지 않고 ⌘+드래그로도 옮겨지지 않는다
--- (macOS 27.0 실측). 떠 있는 동안 시스템이 구분자를 접어 자리를 내고 사라지면 배치를 스스로
--- 되돌리므로, 판독 목록에서 빼고 pinned 로만 알려 탐색이 폭을 건드리지 않게 한다.
local PINNED_IDS = {
  ["com.apple.menuextra.audiovideo"] = true,   -- 카메라·마이크 사용 중 인디케이터
}

--- 폭 w 의 거의 투명한 이미지. 알파 0 이면 항목이 그려지지 않으므로 0.001 을 쓴다.
--- badge 가 참이면 오른쪽 끝에 폰 글리프를 그린다. 이미지 폭은 그대로다 — w 가 글리프보다 좁을 때만 글리프
--- 폭으로 넓어진다. 글리프는 검정으로 그리고 template 로 올려 시스템이 메뉴바 밝기에 맞게 색을 입힌다.
local function sepImage(w, badge)
  local width = math.max(w, badge and BADGE_WIDTH or 1)
  local canvas = hs.canvas.new({ x = 0, y = 0, w = width, h = ICON_HEIGHT })
  canvas[1] = { type = "rectangle", action = "fill", fillColor = { alpha = 0.001 } }
  if badge then
    local x = width - BADGE_WIDTH
    canvas[2] = {
      type = "rectangle", action = "stroke",
      frame = { x = x + 3.5, y = 4.5, w = 9, h = 13 },
      roundedRectRadii = { xRadius = 2, yRadius = 2 },
      strokeColor = { white = 0 }, strokeWidth = 1.2,
    }
    canvas[3] = {
      type = "segments", action = "stroke",
      coordinates = { { x = x + 6.5, y = 6.5 }, { x = x + 9.5, y = 6.5 } },
      strokeColor = { white = 0 }, strokeWidth = 1,
    }
  end
  local img = canvas:imageFromCanvas()
  canvas:delete()
  return img
end

--- 코루틴 안에서만 쓴다. 메인 스레드를 막지 않고 기다린다 —
--- 메뉴바 재배치는 런루프가 돌아야 일어나므로 usleep 으로 막으면 안 된다.
--- 타이머를 self 에 붙들어 둔다. 참조를 잃은 hs.timer 는 GC 가 수거해 콜백이 영영 오지 않고,
--- 그러면 코루틴이 깨어나지 못해 running 이 참인 채로 굳는다.
local function sleep(self, seconds)
  local co = coroutine.running()
  local timer
  timer = hs.timer.doAfter(seconds, function()
    -- 뒤이어 시작된 탐색이 자리를 차지했으면 그쪽 타이머를 지우지 않는다
    if self.settleTimer == timer then self.settleTimer = nil end
    coroutine.resume(co)
  end)
  self.settleTimer = timer
  coroutine.yield()
end

--- 세대가 바뀐 탐색을 끊을 때 던지는 값. pcall 로 받아 조용히 삼킨다.
local ABORTED = "bartender:aborted"

--- 탐색 상한. 주 화면 폭이면 어떤 배치에서도 구분자가 메뉴바를 다 덮을 수 있다.
local function searchLimit()
  local screen = hs.screen.mainScreen()
  return screen and screen:frame().w or fit.MAX_WIDTH
end

--- 지금 앞에 있는 앱 이름. 잠금 화면이면 loginwindow 다.
local function focusedAppName()
  local window = hs.window.focusedWindow()
  local app = window and window:application()
  return app and app:name() or nil
end

--------------------------------------------------------------------------
-- 판독기
--------------------------------------------------------------------------

--- MenuBarAgent 항목(AXHostingView 그룹)이 고정 항목인가. 식별자는 안쪽 AXMenuBarItem 에 실린다.
local function isPinned(child)
  for _, inner in ipairs(child:attributeValue("AXChildren") or {}) do
    if PINNED_IDS[inner:attributeValue("AXIdentifier")] then return true end
  end
  return false
end

--- 모든 실행 중 앱의 AXExtrasMenuBar 자식을 모아 fit.decide 가 쓰는 스냅샷으로 만든다.
--- key 는 pid 와 앱 안에서의 순서로 만든다 — 제목은 시계처럼 매 초 바뀌는 것이 있어 못 쓴다.
function obj:probe()
  local snap = { items = {}, chevronX = nil, expanded = false, sep = nil, pinned = false }
  for _, app in ipairs(hs.application.runningApplications()) do
    local ok, element = pcall(hs.axuielement.applicationElement, app)
    if ok and element then
      local extras = element:attributeValue("AXExtrasMenuBar")
      if extras then
        local systemAgent = app:name() == "MenuBarAgent"
        local children = extras:attributeValue("AXChildren") or {}
        for index, child in ipairs(children) do
          local position = child:attributeValue("AXPosition")
          local size = child:attributeValue("AXSize")
          -- 메뉴바 줄 밖(y 가 메뉴바 높이를 넘는 것)에 있는 항목은 시스템이 치워 둔 것이다 — 배치에
          -- 참여하지 않으므로 없는 것으로 본다. 세어 넣으면 접히지 않는 항목을 접으려 헛탐색한다.
          if position and position.y >= 0 and position.y < MENUBAR_ROW_HEIGHT then
            local description = child:attributeValue("AXDescription")
            if description == CHEVRON_HIDDEN then
              snap.chevronX = position.x
            elseif description == CHEVRON_EXPANDED then
              snap.expanded = true
            elseif systemAgent and isPinned(child) then
              snap.pinned = true
            else
              local entry = { key = string.format("%d:%d", app:pid(), index), x = position.x,
                              w = size and size.w or 0 }
              if child:attributeValue("AXHelp") == SEP_TOOLTIP then
                snap.sep = entry
              else
                snap.items[#snap.items + 1] = entry
              end
            end
          end
        end
      end
    end
  end
  return snap
end

--------------------------------------------------------------------------
-- 구분자
--------------------------------------------------------------------------

--- 구분자 폭을 w 로 맞춘다. 실제 항목 폭은 시스템 여백 때문에 w + 18pt 가 된다.
--- w = 0 이면 폭 1pt 이미지 — 항목은 남지만 사실상 보이지 않고 ⌘+드래그로 잡을 수는 있다.
--- 핸드오프 배지가 켜져 있으면 같은 폭 안에 글리프를 함께 그린다.
function obj:setWidth(w)
  if not self.sep then return end
  self.width = w
  self.sep:setIcon(sepImage(w, self.handoff), self.handoff == true)
end

--------------------------------------------------------------------------
-- 메뉴
--------------------------------------------------------------------------

--- 구분자를 클릭했을 때 뜨는 메뉴. 여는 시점의 상태를 보여주려고 함수형으로 단다.
function obj:menuItems()
  local state = {
    suspended = guard.isSuspended(self.suspended, focusedAppName()),
    width = self.width,
    battery = self.extras.Battery,
    batteryThreshold = self.extras.batteryThreshold,
    handoff = self.handoff,
  }
  if not state.suspended then
    local snap = self:probe()
    state.expanded = snap.expanded
    state.hidden = 0
    for _, item in ipairs(snap.items) do
      if snap.chevronX ~= nil and item.x < snap.chevronX then
        state.hidden = state.hidden + 1
      end
    end
  end
  return menu.build(state, {
    fit = function()
      -- 구분자를 옮긴 직후 누르는 용도다. 기억한 실패 서명을 버리고 다시 잰다.
      self.failSignature = nil
      self:fit()
    end,
    setBatteryThreshold = function(t) self:setBatteryThreshold(t) end,
    fetchHandoff = function() self:fetchHandoff() end,
  })
end

--------------------------------------------------------------------------
-- 탐색
--------------------------------------------------------------------------

--- 판독 결과를 정착 비교용 문자열로 줄인다. 구분자·« 위치와 항목 수만 본다.
local function layoutKey(s)
  return string.format("%s|%s|%d", tostring(s.sep and s.sep.x), tostring(s.chevronX), #s.items)
end

--- 코루틴 안에서만 쓴다. 폭을 바꾼 뒤 메뉴바가 자리를 잡을 때까지 기다린다.
--- 100ms 마다 판독해, 바꾸기 전 판독(before)과 달라진 뒤 두 번 연속 같으면 안정으로 본다.
--- 재배치가 시작되기 전의 옛 좌표는 before 와 같으므로 안정으로 오인하지 않는다.
--- 폭이 배치에 반영되지 않는 구간에서는 끝까지 before 와 같아 SETTLE_MAX 를 다 쓰고 나온다 —
--- 그 판독을 fit 이 "반영 안 됨"으로 읽는 것이 맞다.
--- 판독마다 세대를 확인해 끊긴 탐색이 계속 읽지 않게 한다.
function obj:settle(generation, before)
  local last = nil
  for _ = 1, math.floor(SETTLE_MAX / SETTLE_STEP) do
    sleep(self, SETTLE_STEP)
    if self.generation ~= generation then error(ABORTED, 0) end
    local key = layoutKey(self:probe())
    if key == last and key ~= before then return end
    last = key
  end
end

--- 같은 말을 연달아 찍지 않는다. 앱 전환마다 트리거가 도는데 상태는 대개 그대로다.
function obj:log(fmt, ...)
  local message = string.format(fmt, ...)
  if message ~= self.lastLog then
    self.lastLog = message
    hs.printf("[Bartender] %s", message)
  end
end

--- 폭을 한 번 맞춘다. 지금 상태가 이미 목표면 아무것도 바꾸지 않는다.
--- 실행 중이면 끝난 뒤 한 번만 더 돌도록 예약한다.
function obj:fit()
  if guard.isSuspended(self.suspended, focusedAppName()) then
    self:log("잠금·절전 중 — 탐색하지 않는다")
    return self
  end
  if self.running then
    self.pending = true
    return self
  end
  if not self.sep then return self end
  self.running = true

  -- 이 탐색의 세대. stop()/start() 가 세대를 올리면 기다리던 코루틴이 스스로 끊는다.
  local generation = self.generation

  -- 탐색이 어떤 이유로든 멈추면 running 이 참인 채로 굳어 이후 트리거가 전부 막힌다.
  self.watchdog = hs.timer.doAfter(SEARCH_TIMEOUT, function()
    self.watchdog = nil
    self:log("탐색이 %d초 안에 끝나지 않았다 — 폭 0 으로 되돌리고 상태를 초기화한다", SEARCH_TIMEOUT)
    self.generation = self.generation + 1   -- 낡은 코루틴을 끊는다
    self.running = false
    self.pending = false
    -- 탐색 도중의 폭이 남으면 항목이 노치·앱 메뉴 뒤로 밀린 채 굳는다. 안전한 값으로 되돌린다.
    self:setWidth(0)
    self:schedule()
  end)

  local function apply(w)
    if self.generation ~= generation then error(ABORTED, 0) end
    local before = layoutKey(self:probe())
    self:setWidth(w)
    self:settle(generation, before)
    if self.generation ~= generation then error(ABORTED, 0) end
  end

  local co = coroutine.create(function()
    local ok, result, failSignature = pcall(function()
      local keyset = fit.keyset(self:probe())
      local width, failSig = fit.decide(apply, function() return self:probe() end, {
        maxWidth = searchLimit(),
        currentWidth = self.width,
        lastFailSig = self.failSignature,
        hint = keyset and self.widthCache[keyset] or nil,
        log = function(fmt, ...) self:log(fmt, ...) end,
      })
      -- 성공한 폭을 항목 구성별로 기억한다. 같은 구성이 돌아오면 탐색 없이 한 걸음에 맞춘다.
      if keyset and width > 0 and failSig == nil then self.widthCache[keyset] = width end
      return width, failSig
    end)

    -- 세대가 바뀌었으면 이 탐색은 이미 주인이 아니다. 상태를 건드리지 않고 사라진다.
    if self.generation ~= generation then return end

    if self.watchdog then self.watchdog:stop(); self.watchdog = nil end
    self.running = false
    if ok then
      self.lastWidth = result
      -- 실패한 배치의 서명을 들고 있다가 다음 호출에 돌려준다. 성공하면 nil 이 되어 기억이 지워진다.
      self.failSignature = failSignature
    elseif result ~= ABORTED then
      hs.printf("[Bartender] 탐색 실패: %s", tostring(result))
    end
    if self.pending then
      self.pending = false
      self:fit()   -- 코루틴 안에서 새 코루틴을 만드는 것은 안전하다
    end
  end)

  local ok, err = coroutine.resume(co)
  if not ok then
    if self.watchdog then self.watchdog:stop(); self.watchdog = nil end
    self.running = false
    hs.printf("[Bartender] 탐색 시작 실패: %s", tostring(err))
  end
  return self
end

--- 트리거들이 공유하는 입구. 연달아 불려도 마지막 것만 살아남는다.
function obj:schedule()
  if self.debounce then self.debounce:stop() end
  self.debounce = hs.timer.doAfter(DEBOUNCE, function() self:fit() end)
  return self
end

--------------------------------------------------------------------------
-- 옮기기 — 다른 Spoon 이 쓰는 작업
--------------------------------------------------------------------------

--- MenuBarAgent 가 띄운 시스템 항목의 프레임. AXHostingView 그룹 안의 AXMenuBarItem 이 가진
--- AXIdentifier 로 찾는다. 없으면 nil — 접힌 시스템 항목은 AX 목록에서 아예 사라진다.
local function menuExtraFrame(identifier)
  for _, app in ipairs(hs.application.runningApplications()) do
    if app:name() == "MenuBarAgent" then
      local element = hs.axuielement.applicationElement(app)
      local extras = element and element:attributeValue("AXExtrasMenuBar")
      for _, child in ipairs(extras and extras:attributeValue("AXChildren") or {}) do
        for _, inner in ipairs(child:attributeValue("AXChildren") or {}) do
          if inner:attributeValue("AXIdentifier") == identifier then
            return child:attributeValue("AXFrame")
          end
        end
      end
    end
  end
  return nil
end

--- ⌘ 를 누른 채 from 에서 to 로 끄는 마우스 이벤트를 합성한다. 마우스 위치는 끝나면 되돌린다.
--- usleep 으로 잠깐 막지만 이벤트는 다른 프로세스(MenuBarAgent)가 받으므로 전달에는 지장이 없다.
local function commandDrag(from, to)
  local saved = hs.mouse.absolutePosition()
  local ev = hs.eventtap.event
  local mods = { "cmd" }
  ev.newMouseEvent(ev.types.leftMouseDown, from, mods):post()
  hs.timer.usleep(DRAG_STEP_US * 4)
  local steps = 12
  for i = 1, steps do
    local t = i / steps
    ev.newMouseEvent(ev.types.leftMouseDragged,
      { x = from.x + (to.x - from.x) * t, y = from.y + (to.y - from.y) * t }, mods):post()
    hs.timer.usleep(DRAG_STEP_US)
  end
  ev.newMouseEvent(ev.types.leftMouseUp, to, mods):post()
  hs.timer.usleep(DRAG_STEP_US * 4)
  hs.mouse.absolutePosition(saved)
end

--- 진행 중인 탐색과 예약을 모두 끊는다. 세대를 올리므로 기다리던 코루틴은 깨어나서 스스로 끝난다.
function obj:abort()
  self.generation = self.generation + 1
  if self.debounce then self.debounce:stop(); self.debounce = nil end
  if self.settleTimer then self.settleTimer:stop(); self.settleTimer = nil end
  if self.watchdog then self.watchdog:stop(); self.watchdog = nil end
  self.running = false
  self.pending = false
  self.placing = false
  return self
end

--- 시스템 항목을 구분자 오른쪽으로 옮긴다. applyExtras 가 항목을 켰을 때 부른다.
--- 켜진 항목은 시스템이 저장해 둔 자리에 놓이는데, 그 자리가 구분자 왼쪽이면 나타나자마자 접히고
--- 접힌 시스템 항목은 AX 목록에서 사라져 그 상태로는 찾을 수도 끌 수도 없다. 그래서 탐색을 끊고
--- 폭을 0 으로 내려 항목을 드러낸 뒤 ⌘+드래그로 옮기고, 폭을 되돌려 다시 맞춘다.
--- 옮긴 자리는 시스템이 저장하므로 보통 처음 한 번만 움직인다.
--- 연달아 부르면 순서대로 처리한다. 구분자가 없거나 잠금·절전 중이면 아무것도 하지 않는다.
--- @param identifier string 항목의 AXIdentifier (예: "com.apple.menuextra.battery")
function obj:placeRight(identifier)
  if not self.sep then return self end
  if guard.isSuspended(self.suspended, focusedAppName()) then
    self:log("잠금·절전 중 — %s 항목을 옮기지 않는다", identifier)
    return self
  end
  self.placeQueue[#self.placeQueue + 1] = identifier
  if self.placing then return self end
  -- 탐색 중이면 끊는다. 끝나기를 기다리면 폭이 자라 항목이 더 깊이 접힐 뿐이다.
  self:abort()
  -- 큐를 다 비운 뒤에 되돌릴 폭. 항목마다 되돌리면 두 번째 항목이 폭 0 을 저장해 버린다.
  self.placeSaved = self.width
  self.placeTouched = false
  self:place()
  return self
end

--- 코루틴 안에서만 쓴다. 시스템 항목의 프레임이 두 번 연속 같을 때까지 기다렸다 돌려준다.
--- 막 나타났거나 폭을 바꾼 직후의 항목은 아직 움직이는 중이라 그 좌표를 잡으면 드래그가 빗나간다.
--- 끝까지 안정되지 않으면 마지막 판독을, 항목이 없으면 nil 을 돌려준다.
function obj:stableExtraFrame(identifier, generation)
  local last = nil
  for _ = 1, math.floor(SETTLE_MAX / SETTLE_STEP) do
    sleep(self, SETTLE_STEP)
    if self.generation ~= generation then error(ABORTED, 0) end
    local frame = menuExtraFrame(identifier)
    if frame and last and frame.x == last.x then return frame end
    last = frame
  end
  return last
end

--- placeQueue 의 첫 항목을 옮기고, 남은 것이 있으면 이어서 옮긴다. 옮기는 동안 running 을 잡아
--- 트리거가 fit 을 끼워 넣지 못하게 하고, 큐를 다 비우면 schedule() 로 넘긴다. 폭을 건드렸으면
--- 되돌려 둔다 — 항목이 오른쪽으로 갔으면 그 폭이 그대로 만족하므로 탐색 없이 끝나고, 아니면 평소대로 탐색한다.
function obj:place()
  local identifier = table.remove(self.placeQueue, 1)
  if not identifier then return self end
  self.running = true
  self.placing = true
  local generation = self.generation

  self.watchdog = hs.timer.doAfter(PLACE_TIMEOUT, function()
    self.watchdog = nil
    self:log("%s 항목 옮기기가 %d초 안에 끝나지 않았다 — 상태를 초기화한다", identifier, PLACE_TIMEOUT)
    self:abort()
    self.placeQueue = {}
    self:setWidth(self.placeSaved)
    self:schedule()
  end)

  local co = coroutine.create(function()
    local ok, err = pcall(function()
      -- 1. 막 켜진 항목이 나타나기를 기다렸다가 지금 폭에서 먼저 본다. 보이는 데다 구분자 오른쪽이면
      --    손댈 것이 없다 — 폭 0 을 거치면 메뉴바가 1~2초 깜빡이므로 저장된 자리가 맞는 보통의 경우는 건너뛴다.
      sleep(self, APPEAR_DELAY)
      if self.generation ~= generation then error(ABORTED, 0) end
      local item = menuExtraFrame(identifier)
      if place.isRightOf(item, self.sep:frame()) then
        self:log("%s 항목은 이미 구분자 오른쪽에 있다", identifier)
        return
      end
      -- 2. 접혔거나 구분자 왼쪽이다. 폭 0 으로 내려 드러낸다
      self.placeTouched = true
      local before = layoutKey(self:probe())
      self:setWidth(0)
      self:settle(generation, before)
      item = self:stableExtraFrame(identifier, generation)
      if item == nil then
        self:log("%s 항목이 메뉴바에 나타나지 않아 옮기지 못함", identifier)
        return
      end
      -- 3. 구분자 오른쪽으로 끈다. 빗나가면 한 번 더 끈다
      for _ = 1, 2 do
        local drag = place.dragToRightOf(item, self.sep:frame())
        if drag == nil then
          self:log("%s 항목은 이미 구분자 오른쪽에 있다", identifier)
          return
        end
        before = layoutKey(self:probe())
        commandDrag(drag.from, drag.to)
        self:settle(generation, before)
        item = self:stableExtraFrame(identifier, generation)
        if place.isRightOf(item, self.sep:frame()) then
          self:log("%s 항목을 구분자 오른쪽으로 옮김", identifier)
          return
        end
        if item == nil then break end
      end
      self:log("%s 항목을 구분자 오른쪽으로 옮기지 못함", identifier)
    end)

    -- 세대가 바뀌었으면 abort 나 감시견이 이미 상태를 정리했다
    if self.generation ~= generation then return end

    if self.watchdog then self.watchdog:stop(); self.watchdog = nil end
    self.running = false
    self.placing = false
    if not ok and err ~= ABORTED then
      hs.printf("[Bartender] %s 항목 옮기기 실패: %s", identifier, tostring(err))
    end
    if #self.placeQueue > 0 then
      self:place()   -- 코루틴 안에서 새 코루틴을 만드는 것은 안전하다
      return
    end
    -- 폭을 건드렸으면 되돌린다 — 그 폭이면 만족 점검이 폭 0 을 거치지 않는다. 배치가 달라졌으니
    -- 실패 기억은 버린다. 어느 쪽이든 끊었던 탐색을 대신해 한 번 맞춘다.
    if self.placeTouched then
      self.failSignature = nil
      self:setWidth(self.placeSaved)
    end
    self.pending = false
    self:schedule()
  end)

  local ok, err = coroutine.resume(co)
  if not ok then
    if self.watchdog then self.watchdog:stop(); self.watchdog = nil end
    self.running = false
    self.placing = false
    hs.printf("[Bartender] %s 항목 옮기기 시작 실패: %s", identifier, tostring(err))
  end
  return self
end

--------------------------------------------------------------------------
-- 시스템 항목 켜고 끄기 — 배터리·Wi-Fi 를 필요할 때만
--------------------------------------------------------------------------

--- defaults 에 저장된 스위치 값을 읽는다. 키가 없으면 nil(= 보임).
local function readVisible(name)
  local out, ok = hs.execute(string.format('defaults -currentHost read %s %s 2>/dev/null', CC_DOMAIN, name))
  if not ok then return nil end
  return rules.flagToVisible(tonumber((out:gsub("%s+$", ""))))
end

local function writeVisible(name, visible)
  hs.execute(string.format('defaults -currentHost write %s %s -int %d', CC_DOMAIN, name, rules.visibleToFlag(visible)))
end

--- 지금 상태를 읽어 규칙과 다른 스위치만 고친다.
--- 켠 항목은 시스템이 저장해 둔 자리에 놓이는데 그 자리가 구분자 왼쪽이면 바로 접히므로 placeRight 로 옮긴다 —
--- 끝나면 스스로 다시 맞춘다. 옮길 항목이 없는데 바뀐 것이 있으면 배치가 달라졌으니 다시 맞추라고만 예약한다.
--- @param opts table|nil {placeAll = true} 면 막 켠 항목만이 아니라 켜져 있는 항목을 모두 확인한다 —
---                       start() 때 쓴다. 구분자를 다시 만들면(Hammerspoon 리로드) 켜져 있던 항목이 접혀 있을 수 있다
function obj:applyExtras(opts)
  if not (self.extras.Battery or self.extras.WiFi) then return self end
  local state = {
    onBattery = rules.onBattery(hs.battery.powerSource()),
    batteryPercent = hs.battery.percentage(),
    wifiConnected = rules.wifiConnected(hs.wifi.interfaceDetails()),
  }
  local want = rules.wanted(state, self.extras)
  local current = {}
  for name in pairs(want) do current[name] = readVisible(name) end
  local changes = rules.changes(want, current)
  for _, change in ipairs(changes) do
    writeVisible(change.name, change.visible)
    self:log("%s 항목을 %s (%s)", change.name, change.visible and "켬" or "끔",
             change.name == "Battery" and rules.batteryReason(state)
                                      or (state.wifiConnected and "Wi-Fi 연결" or "Wi-Fi 끊김"))
  end
  local names = rules.toPlace(want, changes, opts and opts.placeAll)
  for _, name in ipairs(names) do self:placeRight(rules.MENU_EXTRA_ID[name]) end
  if #names == 0 and #changes > 0 then self:schedule() end
  return self
end

--- 배터리 임계값을 바꾸고 저장한 뒤 바로 반영한다. 구분자 메뉴의 "배터리 표시"가 부른다.
--- @param threshold number|nil nil 이면 배터리로 돌 때만 보인다
function obj:setBatteryThreshold(threshold)
  self.extras.batteryThreshold = threshold
  hs.settings.set(SETTINGS_THRESHOLD, threshold or false)
  self:log("배터리 임계값을 %s 로 바꿈", threshold and (threshold .. "%") or "배터리로 돌 때만")
  return self:applyExtras()
end

--- 규칙을 적용하던 시스템 항목을 모두 다시 보이게 한다. 이 기능을 그만 쓸 때 부른다.
--- stop() 은 감시만 멈추고 스위치는 마지막 상태 그대로 둔다.
function obj:restoreExtras()
  for name, enabled in pairs(self.extras) do
    if enabled == true and readVisible(name) == false then
      writeVisible(name, true)
      self:log("%s 항목을 켬 (복원)", name)
    end
  end
  return self
end

--------------------------------------------------------------------------
-- 핸드오프 (iPhone Universal Clipboard)
--------------------------------------------------------------------------

--- 클립보드에 iPhone 항목이 있는지 보고, 바뀌었으면 배지를 다시 그린다.
--- 타입 목록만 조회한다 — 데이터를 읽으면 그 순간 iPhone 에서 전송이 일어난다.
--- 탐색·옮기기가 도는 동안은 미룬다. 그 사이 이미지를 다시 그리면 정착 판정을 흔들 수 있다.
function obj:checkHandoff()
  if self.running then return end
  local remote = handoff.isRemote(hs.pasteboard.allContentTypes())
  if remote == self.handoff then return end
  self.handoff = remote
  self:setWidth(self.width)
  -- 구분자가 글리프보다 좁으면 배지가 항목 폭을 바꾼다. 그 배치는 다시 맞춰야 한다
  if self.width < BADGE_WIDTH then self:schedule() end
end

--- iPhone 항목을 실제로 받아(이때 시스템 진행창이 뜰 수 있다) 마커 없는 로컬 항목으로 다시 쓴다.
--- changeCount 가 바뀌므로 클립보드 매니저가 저장하고, 마커가 사라져 배지가 내려간다.
function obj:fetchHandoff()
  local data = handoff.strip(hs.pasteboard.readAllData())
  if not data then
    self:log("핸드오프 가져오기: 받은 데이터가 없다 (만료?)")
    hs.alert.show("가져올 iPhone 클립보드가 없다")
    return
  end
  local before = hs.pasteboard.changeCount()
  local ok = hs.pasteboard.writeAllData(data)
  local kinds = {}
  for t, bytes in pairs(data) do kinds[#kinds + 1] = string.format("%s %dB", t, #bytes) end
  table.sort(kinds)
  self:log("핸드오프 가져옴 (ok=%s, changeCount %d→%d): %s", tostring(ok), before, hs.pasteboard.changeCount(),
    table.concat(kinds, ", "))
  self:checkHandoff()
end

--------------------------------------------------------------------------
-- Spoon 수명주기
--------------------------------------------------------------------------

function obj:init()
  self.width = 0
  self.lastWidth = 0
  self.running = false
  self.pending = false
  self.generation = 0
  self.widthCache = {}
  self.lastLog = nil
  self.failSignature = nil
  self.suspended = false
  self.placing = false
  self.placeQueue = {}
  self.placeSaved = 0
  self.placeTouched = false
  self.handoff = false
  return self
end

function obj:start()
  if self.sep then return self end
  self.generation = self.generation + 1
  self.lastLog = nil
  self.failSignature = nil

  -- autosaveName 을 주면 ⌘+드래그로 정한 자리가 재시작 후에도 유지된다.
  self.sep = hs.menubar.new(true, SEP_AUTOSAVE)
  if not self.sep then
    hs.printf("[Bartender] 메뉴바 항목을 만들지 못했다")
    return self
  end
  self.sep:setTooltip(SEP_TOOLTIP)
  self.sep:setMenu(function() return self:menuItems() end)
  self:setWidth(0)

  self.screenWatcher = hs.screen.watcher.new(function() self:schedule() end)
  self.screenWatcher:start()

  local watcher = hs.application.watcher
  self.appWatcher = watcher.new(function(_, event)
    if event == watcher.launched or event == watcher.terminated
      or event == watcher.activated then
      self:schedule()
    end
  end)
  self.appWatcher:start()

  -- 잠금·절전 중에는 메뉴바가 접히지 않아 탐색이 반드시 실패한다. 그 구간에는 손대지 않고,
  -- 돌아올 때 잘못 남은 실패 기억을 버리고 다시 맞춘다.
  local caffeinate = hs.caffeinate.watcher
  self.powerWatcher = caffeinate.new(function(event)
    if event == caffeinate.screensDidLock or event == caffeinate.screensDidSleep
      or event == caffeinate.systemWillSleep then
      self.suspended = true
    elseif event == caffeinate.screensDidUnlock or event == caffeinate.screensDidWake
      or event == caffeinate.systemDidWake or event == caffeinate.sessionDidBecomeActive then
      self.suspended = false
      self.failSignature = nil
      self:schedule()
    end
  end)
  self.powerWatcher:start()

  -- 메뉴로 고른 배터리 임계값이 있으면 init.lua 의 기본값보다 우선한다
  local saved = hs.settings.get(SETTINGS_THRESHOLD)
  if saved ~= nil then self.extras.batteryThreshold = saved or nil end

  self.batteryWatcher = hs.battery.watcher.new(function() self:applyExtras() end)
  self.batteryWatcher:start()
  self.wifiWatcher = hs.wifi.watcher.new(function() self:applyExtras() end)
  self.wifiWatcher:watchingFor({ "SSIDChange", "linkChange", "powerChange" })
  self.wifiWatcher:start()

  -- 앱이 제 항목 폭을 바꾸면 어떤 이벤트도 오지 않는다. 그 경우의 보정. 전원·Wi-Fi 이벤트를 놓친 경우도 같이 잡는다.
  self.correctiveTimer = hs.timer.doEvery(CORRECTIVE, function()
    self:applyExtras()
    self:schedule()
  end)

  self.handoffTimer = hs.timer.doEvery(HANDOFF_POLL, function() self:checkHandoff() end)
  self:checkHandoff()

  -- 켜져 있는 시스템 항목도 확인한다. 구분자를 다시 만들었으니 접혀 있을 수 있다.
  self:applyExtras({ placeAll = true })
  self:schedule()
  return self
end

function obj:stop()
  self:abort()
  self.placeQueue = {}
  -- 타이머는 참조를 잃으면 GC 로 사라지므로 전부 self 에 붙들어 두고 여기서 거둔다
  if self.correctiveTimer then self.correctiveTimer:stop(); self.correctiveTimer = nil end
  if self.handoffTimer then self.handoffTimer:stop(); self.handoffTimer = nil end
  self.handoff = false
  if self.batteryWatcher then self.batteryWatcher:stop(); self.batteryWatcher = nil end
  if self.wifiWatcher then self.wifiWatcher:stop(); self.wifiWatcher = nil end
  if self.screenWatcher then self.screenWatcher:stop(); self.screenWatcher = nil end
  if self.appWatcher then self.appWatcher:stop(); self.appWatcher = nil end
  if self.powerWatcher then self.powerWatcher:stop(); self.powerWatcher = nil end
  if self.sep then self.sep:delete(); self.sep = nil end
  return self
end

return obj
