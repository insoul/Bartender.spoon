--- === Bartender ===
---
--- macOS 27 의 메뉴바 오버플로(`«`)를 이용해 고른 항목만 접는다.
--- 투명한 구분자 항목 하나를 메뉴바에 두고, 그 폭을 조절해 왼쪽 항목들을 오버플로로 밀어낸다.
--- 구분자 왼쪽 = 접힘, 오른쪽 = 표시. 접힌 항목은 시스템 `«` 로 본다.
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
local menu = dofile(spoonPath .. "lib/menu.lua")
local autoshow = dofile(spoonPath .. "lib/autoshow.lua")

--- 상태에 따라 켜고 끌 시스템 항목. false 로 두면 그 항목은 건드리지 않는다.
--- Battery 는 배터리로 돌 때만, WiFi 는 연결이 끊겼을 때만 보인다.
--- 시스템 설정 → Menu Bar 의 해당 스위치를 이 Spoon 이 소유하게 된다 — 손으로 바꿔도 다음 상태
--- 변화 때 규칙대로 되돌아간다.
obj.autoShow = { Battery = true, WiFi = true }

--- 시스템 항목 스위치가 저장되는 defaults 도메인. per-host(-currentHost) 이고 키는 항목 이름(Battery, WiFi),
--- 값은 정수 플래그(lib/autoshow.lua 의 FLAG_*)다.
local CC_DOMAIN = "com.apple.controlcenter"

--- 구분자 식별: setTooltip 이 AX 의 AXHelp 로 실린다 (macOS 27.0 에서 실측 확인).
--- 툴팁은 항목 폭에 영향을 주지 않으므로 탐색을 방해하지 않는다.
local SEP_TOOLTIP = "bartender_sep"
local SEP_AUTOSAVE = "bartender_sep"

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
--- 아이콘 높이. 메뉴바 항목의 표준 높이다
local ICON_HEIGHT = 22

--- 폭 w 의 거의 투명한 이미지. 알파 0 이면 항목이 그려지지 않으므로 0.001 을 쓴다.
local function blankImage(w)
  local canvas = hs.canvas.new({ x = 0, y = 0, w = math.max(w, 1), h = ICON_HEIGHT })
  canvas[1] = { type = "rectangle", action = "fill", fillColor = { alpha = 0.001 } }
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

--- 모든 실행 중 앱의 AXExtrasMenuBar 자식을 모아 fit.decide 가 쓰는 스냅샷으로 만든다.
--- key 는 pid 와 앱 안에서의 순서로 만든다 — 제목은 시계처럼 매 초 바뀌는 것이 있어 못 쓴다.
function obj:probe()
  local snap = { items = {}, chevronX = nil, expanded = false, sep = nil }
  for _, app in ipairs(hs.application.runningApplications()) do
    local ok, element = pcall(hs.axuielement.applicationElement, app)
    if ok and element then
      local extras = element:attributeValue("AXExtrasMenuBar")
      if extras then
        local children = extras:attributeValue("AXChildren") or {}
        for index, child in ipairs(children) do
          local position = child:attributeValue("AXPosition")
          local size = child:attributeValue("AXSize")
          if position then
            local description = child:attributeValue("AXDescription")
            if description == CHEVRON_HIDDEN then
              snap.chevronX = position.x
            elseif description == CHEVRON_EXPANDED then
              snap.expanded = true
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
function obj:setWidth(w)
  if not self.sep then return end
  self.width = w
  self.sep:setIcon(blankImage(w), false)
end

--------------------------------------------------------------------------
-- 상태별 시스템 항목 켜기·끄기
--------------------------------------------------------------------------

--- defaults 에 저장된 스위치 값을 읽는다. 키가 없으면 nil(= 보임).
local function readVisible(name)
  local out, ok = hs.execute(string.format('defaults -currentHost read %s %s 2>/dev/null', CC_DOMAIN, name))
  if not ok then return nil end
  return autoshow.flagToVisible(tonumber((out:gsub("%s+$", ""))))
end

local function writeVisible(name, visible)
  hs.execute(string.format('defaults -currentHost write %s %s -int %d', CC_DOMAIN, name, autoshow.visibleToFlag(visible)))
end

--- 지금 상태를 읽어 규칙과 다른 스위치만 고친다. 바뀐 것이 있으면 배치가 달라졌으니 다시 맞춘다.
function obj:applyAutoShow()
  local state = {
    onBattery = autoshow.onBattery(hs.battery.powerSource()),
    wifiConnected = autoshow.wifiConnected(hs.wifi.interfaceDetails()),
  }
  local want = autoshow.wanted(state, self.autoShow)
  local current = {}
  for name in pairs(want) do current[name] = readVisible(name) end
  local changes = autoshow.changes(want, current)
  for _, change in ipairs(changes) do
    writeVisible(change.name, change.visible)
    self:log("%s 항목을 %s (%s)", change.name, change.visible and "켬" or "끔",
             change.name == "Battery" and (state.onBattery and "배터리 구동" or "전원 연결")
                                      or (state.wifiConnected and "Wi-Fi 연결" or "Wi-Fi 끊김"))
  end
  if #changes > 0 then self:schedule() end
  return self
end

--------------------------------------------------------------------------
-- 메뉴
--------------------------------------------------------------------------

--- 구분자를 클릭했을 때 뜨는 메뉴. 여는 시점의 상태를 보여주려고 함수형으로 단다.
function obj:menuItems()
  local state = {
    suspended = guard.isSuspended(self.suspended, focusedAppName()),
    width = self.width,
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
  return menu.build(state, function()
    -- 구분자를 옮긴 직후 누르는 용도다. 기억한 실패 서명을 버리고 다시 잰다.
    self.failSignature = nil
    self:fit()
  end)
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

  -- 앱이 제 항목 폭을 바꾸면 어떤 이벤트도 오지 않는다. 그 경우의 보정.
  self.correctiveTimer = hs.timer.doEvery(CORRECTIVE, function() self:schedule() end)

  -- 전원·Wi-Fi 상태가 바뀌면 시스템 항목 스위치를 규칙대로 맞춘다. 이벤트를 놓친 경우를 위해
  -- 60초 보정에서도 한 번씩 본다.
  if self.autoShow.Battery or self.autoShow.WiFi then
    self.batteryWatcher = hs.battery.watcher.new(function() self:applyAutoShow() end)
    self.batteryWatcher:start()
    self.wifiWatcher = hs.wifi.watcher.new(function() self:applyAutoShow() end)
    self.wifiWatcher:watchingFor({ "SSIDChange", "linkChange", "powerChange" })
    self.wifiWatcher:start()
    self.autoShowTimer = hs.timer.doEvery(CORRECTIVE, function() self:applyAutoShow() end)
    self:applyAutoShow()
  end

  self:schedule()
  return self
end

function obj:stop()
  self.generation = self.generation + 1
  -- 타이머는 참조를 잃으면 GC 로 사라지므로 전부 self 에 붙들어 두고 여기서 거둔다
  if self.debounce then self.debounce:stop(); self.debounce = nil end
  if self.settleTimer then self.settleTimer:stop(); self.settleTimer = nil end
  if self.watchdog then self.watchdog:stop(); self.watchdog = nil end
  if self.correctiveTimer then self.correctiveTimer:stop(); self.correctiveTimer = nil end
  if self.autoShowTimer then self.autoShowTimer:stop(); self.autoShowTimer = nil end
  if self.batteryWatcher then self.batteryWatcher:stop(); self.batteryWatcher = nil end
  if self.wifiWatcher then self.wifiWatcher:stop(); self.wifiWatcher = nil end
  if self.screenWatcher then self.screenWatcher:stop(); self.screenWatcher = nil end
  if self.appWatcher then self.appWatcher:stop(); self.appWatcher = nil end
  if self.powerWatcher then self.powerWatcher:stop(); self.powerWatcher = nil end
  if self.sep then self.sep:delete(); self.sep = nil end
  self.running = false
  self.pending = false
  return self
end

return obj
