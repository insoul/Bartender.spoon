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

--- 구분자 식별: setTooltip 이 AX 의 AXHelp 로 실린다 (macOS 27.0 에서 실측 확인).
--- 툴팁은 항목 폭에 영향을 주지 않으므로 탐색을 방해하지 않는다.
local SEP_TOOLTIP = "bartender_sep"
local SEP_AUTOSAVE = "bartender_sep"

--- 접힌 항목이 있을 때만 MenuBarAgent 의 버튼 설명이 이 값이 된다.
--- 접힌 것이 없으면 같은 버튼이 "Hide Menu Bar Items" 로 바뀐다 — 그 상태는 « 없음으로 본다.
local CHEVRON_DESC = "Show Hidden Menu Bar Items"

--- 폭을 바꾼 뒤 메뉴바가 다시 배치될 때까지 기다리는 시간
local SETTLE = 0.15
--- 트리거가 몰릴 때 마지막 것만 살리는 디바운스
local DEBOUNCE = 0.5
--- 앱이 제 항목 폭을 바꾼 경우를 위한 보정 주기
local CORRECTIVE = 60
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
local function settle(seconds)
  local co = coroutine.running()
  hs.timer.doAfter(seconds, function() coroutine.resume(co) end)
  coroutine.yield()
end

--------------------------------------------------------------------------
-- 판독기
--------------------------------------------------------------------------

--- 모든 실행 중 앱의 AXExtrasMenuBar 자식을 모아 fit.decide 가 쓰는 스냅샷으로 만든다.
--- key 는 pid 와 앱 안에서의 순서로 만든다 — 제목은 시계처럼 매 초 바뀌는 것이 있어 못 쓴다.
function obj:probe()
  local snap = { items = {}, chevronX = nil, sep = nil }
  for _, app in ipairs(hs.application.runningApplications()) do
    local ok, element = pcall(hs.axuielement.applicationElement, app)
    if ok and element then
      local extras = element:attributeValue("AXExtrasMenuBar")
      if extras then
        local children = extras:attributeValue("AXChildren") or {}
        for index, child in ipairs(children) do
          local position = child:attributeValue("AXPosition")
          if position then
            if child:attributeValue("AXDescription") == CHEVRON_DESC then
              snap.chevronX = position.x
            else
              local entry = { key = string.format("%d:%d", app:pid(), index), x = position.x }
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
-- 탐색
--------------------------------------------------------------------------

--- 이분 탐색을 한 번 돌린다. 실행 중이면 끝난 뒤 한 번만 더 돌도록 예약한다.
function obj:fit()
  if self.running then
    self.pending = true
    return self
  end
  if not self.sep then return self end
  self.running = true

  local co = coroutine.create(function()
    local ok, result = pcall(function()
      return fit.decide(
        function(w)
          self:setWidth(w)
          settle(SETTLE)
        end,
        function() return self:probe() end,
        { log = function(fmt, ...) hs.printf("[Bartender] " .. fmt, ...) end }
      )
    end)
    self.running = false
    if ok then
      self.lastWidth = result
    else
      hs.printf("[Bartender] 탐색 실패: %s", tostring(result))
    end
    if self.pending then
      self.pending = false
      hs.timer.doAfter(0, function() self:fit() end)
    end
  end)

  local ok, err = coroutine.resume(co)
  if not ok then
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
  return self
end

function obj:start()
  if self.sep then return self end

  -- autosaveName 을 주면 ⌘+드래그로 정한 자리가 재시작 후에도 유지된다.
  self.sep = hs.menubar.new(true, SEP_AUTOSAVE)
  if not self.sep then
    hs.printf("[Bartender] 메뉴바 항목을 만들지 못했다")
    return self
  end
  self.sep:setTooltip(SEP_TOOLTIP)
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

  -- 앱이 제 항목 폭을 바꾸면 어떤 이벤트도 오지 않는다. 그 경우의 보정.
  self.correctiveTimer = hs.timer.doEvery(CORRECTIVE, function() self:schedule() end)

  self:schedule()
  return self
end

function obj:stop()
  if self.debounce then self.debounce:stop(); self.debounce = nil end
  if self.correctiveTimer then self.correctiveTimer:stop(); self.correctiveTimer = nil end
  if self.screenWatcher then self.screenWatcher:stop(); self.screenWatcher = nil end
  if self.appWatcher then self.appWatcher:stop(); self.appWatcher = nil end
  if self.sep then self.sep:delete(); self.sep = nil end
  self.running = false
  self.pending = false
  return self
end

return obj
