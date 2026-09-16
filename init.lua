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

--- MenuBarAgent 의 오버플로 버튼 하나가 설명 문자열로 상태를 알린다.
--- 접힌 항목이 있으면 « / "Show Hidden…", 없으면 » / "Hide Menu Bar Items".
local CHEVRON_HIDDEN = "Show Hidden Menu Bar Items"
local CHEVRON_EXPANDED = "Hide Menu Bar Items"

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
local function sleep(seconds)
  local co = coroutine.running()
  hs.timer.doAfter(seconds, function() coroutine.resume(co) end)
  coroutine.yield()
end

--- 세대가 바뀐 탐색을 끊을 때 던지는 값. pcall 로 받아 조용히 삼킨다.
local ABORTED = "bartender:aborted"

--- 탐색 상한. 주 화면 폭이면 어떤 배치에서도 구분자가 메뉴바를 다 덮을 수 있다.
local function searchLimit()
  local screen = hs.screen.mainScreen()
  return screen and screen:frame().w or fit.MAX_WIDTH
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
          if position then
            local description = child:attributeValue("AXDescription")
            if description == CHEVRON_HIDDEN then
              snap.chevronX = position.x
            elseif description == CHEVRON_EXPANDED then
              snap.expanded = true
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
  if self.running then
    self.pending = true
    return self
  end
  if not self.sep then return self end
  self.running = true

  -- 이 탐색의 세대. stop()/start() 가 세대를 올리면 기다리던 코루틴이 스스로 끊는다.
  local generation = self.generation

  local function apply(w)
    if self.generation ~= generation then error(ABORTED, 0) end
    self:setWidth(w)
    sleep(SETTLE)
    if self.generation ~= generation then error(ABORTED, 0) end
  end

  local co = coroutine.create(function()
    local ok, result, failSignature = pcall(function()
      return fit.decide(apply, function() return self:probe() end, {
        maxWidth = searchLimit(),
        currentWidth = self.width,
        lastFailSig = self.failSignature,
        log = function(fmt, ...) self:log(fmt, ...) end,
      })
    end)

    -- 세대가 바뀌었으면 이 탐색은 이미 주인이 아니다. 상태를 건드리지 않고 사라진다.
    if self.generation ~= generation then return end

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
  self.generation = 0
  self.lastLog = nil
  self.failSignature = nil
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
  self.generation = self.generation + 1
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
