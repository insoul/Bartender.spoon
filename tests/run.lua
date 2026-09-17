--- Bartender.spoon 단위 테스트.
--- 독립 lua 인터프리터가 없으므로 Hammerspoon 의 Lua 로 돌린다:
---   osascript -e 'tell application "Hammerspoon" to execute lua code
---     "return dofile(\"<spoon>/tests/run.lua\")"'
--- 통과하면 요약 문자열을 돌려주고, 하나라도 실패하면 error 로 올린다.
--- 이 파일과 fake_bar, lib/fit, lib/place, lib/rules 는 hs.* 를 쓰지 않는다.

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local fit = dofile(here .. "../lib/fit.lua")
local guard = dofile(here .. "../lib/guard.lua")
local menuBuilder = dofile(here .. "../lib/menu.lua")
local place = dofile(here .. "../lib/place.lua")
local rules = dofile(here .. "../lib/rules.lua")
local fakeBar = dofile(here .. "fake_bar.lua")

local passed, failures = 0, {}

local function check(name, ok, detail)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = string.format("%s: %s", name, detail or "거짓")
  end
end

local function eq(name, got, want)
  check(name, got == want, string.format("기대 %s, 실제 %s", tostring(want), tostring(got)))
end

local function last(t) return t[#t] end

local function contains(t, v)
  for _, x in ipairs(t) do if x == v then return true end end
  return false
end

--- 임계 폭을 구간으로 표현하는 hiddenFor. 폭 내림차순으로 준다.
--- "H" 는 항상 접혀 있는 항목이다 — 이게 있어야 « 가 존재하는 상태가 된다.
local function thresholds(spec)
  return function(w)
    for _, rule in ipairs(spec) do
      if w >= rule.from then return rule.hidden end
    end
    return { "H" }
  end
end

--------------------------------------------------------------------------
-- 1. 정상 수렴: 이웃만 접히는 최소 폭을 찾는다
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "SEP", "B" },
    hiddenFor = thresholds({
      { from = 300, hidden = { "H", "A", "SEP" } },
      { from = 100, hidden = { "H", "A" } },
    }),
  })
  local w = fit.decide(setWidth, probe)
  check("정상 수렴: 결과가 [100,300) 안", w >= 100 and w < 300, "폭 " .. tostring(w))
  check("정상 수렴: 허용 오차 안에서 최소값", w < 100 + fit.TOLERANCE, "폭 " .. tostring(w))
  eq("정상 수렴: 마지막에 적용한 폭 = 결과", last(trace), w)
  check("정상 수렴: 구분자가 보이므로 폭 0 을 거치지 않는다", not contains(trace, 0), table.concat(trace, ","))
end

--------------------------------------------------------------------------
-- 2. 구분자가 먼저 접히면 폭을 줄인다
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "SEP", "B" },
    hiddenFor = thresholds({
      { from = 200, hidden = { "H", "SEP" } },   -- 구분자 혼자 너무 넓어 자기만 접힌다
      { from = 60, hidden = { "H", "A" } },
    }),
  })
  local w = fit.decide(setWidth, probe)
  check("구분자 선접힘: 결과가 [60,200) 안", w >= 60 and w < 200, "폭 " .. tostring(w))
  check("구분자 선접힘: 넓은 폭으로 끝나지 않았다", last(trace) < 200,
        "마지막 " .. tostring(last(trace)))
end

--------------------------------------------------------------------------
-- 3. 이미 목표 상태면 폭을 건드리지 않는다
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "SEP", "A" },
    hiddenFor = function() return { "H" } end,
    width = 145,
  })
  local w = fit.decide(setWidth, probe, { currentWidth = 145 })
  eq("이미 만족: 현재 폭을 그대로 돌려준다", w, 145)
  eq("이미 만족: setWidth 를 부르지 않는다", #trace, 0)
end

--------------------------------------------------------------------------
-- 4. 왼쪽에 보이는 항목이 생기면 다시 탐색한다
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "SEP", "B" },
    hiddenFor = thresholds({
      { from = 400, hidden = { "H", "A", "SEP" } },
      { from = 200, hidden = { "H", "A" } },
    }),
    width = 145,
  })
  local w = fit.decide(setWidth, probe, { currentWidth = 145 })
  check("만족 깨짐: 탐색에 들어갔다", #trace > 0, "setWidth 호출 " .. #trace .. "회")
  check("만족 깨짐: 결과가 [200,400) 안", w >= 200 and w < 400, "폭 " .. tostring(w))
  eq("만족 깨짐: 마지막에 적용한 폭 = 결과", last(trace), w)
end

--------------------------------------------------------------------------
-- 5. 사용자가 펼쳐 둔 상태면 개입하지 않는다
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "A", "SEP", "B" },
    hiddenFor = function() return nil end,   -- 접힌 것 없음 → »
    width = 145,
  })
  local logged = false
  local w = fit.decide(setWidth, probe, { currentWidth = 145, log = function() logged = true end })
  eq("펼침 상태: 현재 폭을 그대로 돌려준다", w, 145)
  eq("펼침 상태: setWidth 를 부르지 않는다", #trace, 0)
  check("펼침 상태: 로그를 남겼다", logged)
end

--------------------------------------------------------------------------
-- 6. 탐색에 들어갔는데 구분자 왼쪽에 보이는 항목이 없으면 폭 0
--------------------------------------------------------------------------
do
  -- 지금 폭에서는 구분자가 접혀 있어 만족이 아니지만, 폭 0 에서는 접을 것이 없다
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "SEP", "A" },
    hiddenFor = thresholds({ { from = 100, hidden = { "H", "SEP" } } }),
    width = 200,
  })
  local logged = false
  local w = fit.decide(setWidth, probe, { currentWidth = 200, log = function() logged = true end })
  eq("이웃 없음: 폭 0", w, 0)
  eq("이웃 없음: 폭 0 만 적용했다", #trace, 1)
  eq("이웃 없음: 적용값 0", trace[1], 0)
  check("이웃 없음: 로그를 남겼다", logged)
end

--------------------------------------------------------------------------
-- 7. 만족하는 폭이 없으면 폭 0 으로 되돌린다
--------------------------------------------------------------------------
do
  -- 어떤 폭에서도 구분자가 이웃보다 먼저 접힌다
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "SEP", "B" },
    hiddenFor = thresholds({ { from = 1, hidden = { "H", "A", "SEP" } } }),
  })
  local logged = false
  local w = fit.decide(setWidth, probe, { log = function() logged = true end })
  eq("만족값 없음: 폭 0", w, 0)
  eq("만족값 없음: 폭 0 으로 되돌렸다", last(trace), 0)
  check("만족값 없음: 로그를 남겼다", logged)
end

--------------------------------------------------------------------------
-- 8. 버튼이 아예 없어도(여유가 많은 화면) 왼쪽에 보이는 항목이 있으면 탐색한다
--------------------------------------------------------------------------
do
  -- 접힌 것이 없을 뿐이다. 폭을 키우면 « 가 생기고 왼쪽부터 접힌다.
  local setWidth, probe, trace = fakeBar.new({
    order = { "A", "SEP", "B" },
    noChevron = true,
    hiddenFor = function(w)
      if w >= 300 then return { "A", "SEP" } end
      if w >= 100 then return { "A" } end
      return nil
    end,
  })
  local w = fit.decide(setWidth, probe)
  check("버튼 부재: 탐색에 들어갔다", #trace > 0, "setWidth 호출 " .. #trace .. "회")
  check("버튼 부재: 결과가 [100,300) 안", w >= 100 and w < 300, "폭 " .. tostring(w))
  eq("버튼 부재: 마지막에 적용한 폭 = 결과", last(trace), w)
end

--------------------------------------------------------------------------
-- 9. 판독에서 구분자가 사라지면 즉시 포기한다
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "SEP", "B" },
    hiddenFor = function() return { "H" } end,
    noSep = true,
    width = 77,
  })
  local logged = false
  local w = fit.decide(setWidth, probe, { currentWidth = 77, log = function() logged = true end })
  eq("구분자 유실: 현재 폭을 그대로 돌려준다", w, 77)
  eq("구분자 유실: setWidth 를 부르지 않는다", #trace, 0)
  check("구분자 유실: 로그를 남겼다", logged)
end

--------------------------------------------------------------------------
-- 10. 이웃은 구분자 왼쪽에서 가장 오른쪽 항목이다
--------------------------------------------------------------------------
do
  -- B 가 구분자 바로 왼쪽. A 만 접힌 구간은 조건을 만족하지 않는다.
  local setWidth, probe = fakeBar.new({
    order = { "H", "A", "B", "SEP", "C" },
    widths = { A = 150, B = 120 },
    hiddenFor = thresholds({
      { from = 400, hidden = { "H", "A", "B", "SEP" } },
      { from = 250, hidden = { "H", "A", "B" } },
      { from = 120, hidden = { "H", "A" } },
    }),
  })
  local w = fit.decide(setWidth, probe)
  check("이웃 선택: 결과가 [250,400) 안", w >= 250 and w < 400, "폭 " .. tostring(w))
end

--------------------------------------------------------------------------
-- 11. 탐색 상한·오차는 opts 로 바꾼다 (상한은 주 화면 폭이 들어온다)
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "SEP" },
    hiddenFor = thresholds({ { from = 40, hidden = { "H", "A" } } }),
  })
  local w = fit.decide(setWidth, probe, { maxWidth = 200, tolerance = 1 })
  check("opts: 상한 안에서 수렴", w >= 40 and w <= 41, "폭 " .. tostring(w))
  for _, v in ipairs(trace) do
    check("opts: 상한을 넘지 않았다", v <= 200, "폭 " .. tostring(v))
  end
end

--------------------------------------------------------------------------
-- 12. 반영되지 않는 폭 구간이 있어도 수렴한다
--------------------------------------------------------------------------
do
  -- 상한(주 화면 폭)이 여유보다 훨씬 크면 탐색은 먼저 반영 안 되는 구간을 밟는다.
  -- 그 구간의 판독값은 폭 0 과 같으므로, 걸러내지 않으면 "이웃이 보인다"로 읽고 폭만 키운다.
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "SEP", "B" },
    hiddenFor = thresholds({
      { from = 300, hidden = { "H", "A", "SEP" } },
      { from = 100, hidden = { "H", "A" } },
    }),
    deadZone = 400,
  })
  local w = fit.decide(setWidth, probe, { maxWidth = 1512 })
  check("반영 안 되는 구간: 결과가 [100,300) 안", w >= 100 and w < 300, "폭 " .. tostring(w))
  check("반영 안 되는 구간: 허용 오차 안에서 최소값", w < 100 + fit.TOLERANCE, "폭 " .. tostring(w))
  eq("반영 안 되는 구간: 마지막에 적용한 폭 = 결과", last(trace), w)
end

--------------------------------------------------------------------------
-- 13. 같은 배치에서 실패하면 다시 탐색하지 않는다
--------------------------------------------------------------------------
do
  -- 어떤 폭에서도 구분자가 이웃보다 먼저 접히는 배치
  local order = { "H", "A", "SEP", "B" }
  local setWidth, probe, trace = fakeBar.new({
    order = order,
    hiddenFor = thresholds({ { from = 1, hidden = { "H", "A", "SEP" } } }),
  })

  local w, sig = fit.decide(setWidth, probe)
  eq("실패 서명: 첫 호출은 탐색하고 폭 0", w, 0)
  check("실패 서명: 첫 호출이 탐색을 돌았다", #trace > 1, "setWidth 호출 " .. #trace .. "회")
  check("실패 서명: 서명을 돌려준다", sig ~= nil and #sig > 0, tostring(sig))

  local before = #trace
  local w2, sig2 = fit.decide(setWidth, probe, { currentWidth = 0, lastFailSig = sig })
  eq("실패 서명: 같은 배치면 setWidth 를 부르지 않는다", #trace, before)
  eq("실패 서명: 현재 폭을 그대로 돌려준다", w2, 0)
  eq("실패 서명: 서명을 계속 들고 있는다", sig2, sig)

  -- 항목이 하나 늘면 배치가 달라진 것이므로 다시 탐색한다
  table.insert(order, "C")
  local before2 = #trace
  fit.decide(setWidth, probe, { currentWidth = 0, lastFailSig = sig })
  check("실패 서명: 배치가 바뀌면 다시 탐색한다", #trace > before2,
        "setWidth 호출 " .. (#trace - before2) .. "회")
end

--------------------------------------------------------------------------
-- 14. 판단이 서지 않은 경로는 기억한 서명을 지우지 않는다
--------------------------------------------------------------------------
do
  local SIG = "기억해 둔 실패 서명"

  -- (a) 사용자가 펼쳐 둔 상태
  local setWidth, probe, trace = fakeBar.new({
    order = { "A", "SEP", "B" },
    hiddenFor = function() return nil end,   -- 접힌 것 없음 → »
    width = 145,
  })
  local w, sig = fit.decide(setWidth, probe, { currentWidth = 145, lastFailSig = SIG })
  eq("펼침 상태: 기억한 서명을 그대로 돌려준다", sig, SIG)
  eq("펼침 상태: 폭도 그대로", w, 145)
  eq("펼침 상태: setWidth 를 부르지 않는다", #trace, 0)

  -- (b) 구분자를 찾지 못한 상태
  local setWidth2, probe2, trace2 = fakeBar.new({
    order = { "H", "A", "SEP", "B" },
    hiddenFor = function() return { "H" } end,
    noSep = true,
    width = 77,
  })
  local w2, sig2 = fit.decide(setWidth2, probe2, { currentWidth = 77, lastFailSig = SIG })
  eq("구분자 유실: 기억한 서명을 그대로 돌려준다", sig2, SIG)
  eq("구분자 유실: 폭도 그대로", w2, 77)
  eq("구분자 유실: setWidth 를 부르지 않는다", #trace2, 0)

  -- (c) 목표에 닿은 상태 — 기억을 지운다
  local setWidth3, probe3, trace3 = fakeBar.new({
    order = { "H", "SEP", "A" },
    hiddenFor = function() return { "H" } end,
    width = 145,
  })
  local w3, sig3 = fit.decide(setWidth3, probe3, { currentWidth = 145, lastFailSig = SIG })
  check("이미 만족: 기억을 지운다", sig3 == nil, tostring(sig3))
  eq("이미 만족: 폭은 그대로", w3, 145)
  eq("이미 만족: setWidth 를 부르지 않는다", #trace3, 0)
end

--------------------------------------------------------------------------
-- 15. 서명은 항목 구성과 구분자 위치를 반영한다
--------------------------------------------------------------------------
do
  local function snapshot(order)
    local snap = { items = {}, chevronX = nil, expanded = false }
    for i, key in ipairs(order) do
      if key == "SEP" then snap.sep = { key = key, x = i * 10 }
      else snap.items[#snap.items + 1] = { key = key, x = i * 10 } end
    end
    return snap
  end
  local base = fit.signature(snapshot({ "A", "B", "SEP", "C" }), 600)
  eq("서명: 같은 배치면 같다", fit.signature(snapshot({ "A", "B", "SEP", "C" }), 600), base)
  check("서명: 구분자가 움직이면 달라진다",
        fit.signature(snapshot({ "A", "SEP", "B", "C" }), 600) ~= base)
  check("서명: 항목이 늘면 달라진다",
        fit.signature(snapshot({ "A", "B", "SEP", "C", "D" }), 600) ~= base)
  check("서명: 상한이 달라지면 달라진다",
        fit.signature(snapshot({ "A", "B", "SEP", "C" }), 1512) ~= base)
  check("서명: 구분자가 없으면 nil", fit.signature({ items = {} }, 600) == nil)
end

--------------------------------------------------------------------------
-- 16. 잠금·절전 중에는 탐색하지 않는다
--------------------------------------------------------------------------
do
  check("중단 판정: 전원·세션 이벤트로 중단된 상태", guard.isSuspended(true, "Finder"))
  check("중단 판정: 앞에 loginwindow 가 있으면 중단으로 본다",
        guard.isSuspended(false, guard.LOGIN_WINDOW))
  check("중단 판정: 평소에는 탐색한다", not guard.isSuspended(false, "Finder"))
  check("중단 판정: 앞선 앱을 모를 때도 평소로 본다", not guard.isSuspended(false, nil))
  check("중단 판정: 상태를 모를 때도 평소로 본다", not guard.isSuspended(nil, "Finder"))
end

--------------------------------------------------------------------------
-- 17. 구분자 메뉴 구성
--------------------------------------------------------------------------
do
  local fired, chosen = false, "안 불림"
  local actions = {
    fit = function() fired = true end,
    setBatteryThreshold = function(t) chosen = t end,
  }

  local normal = menuBuilder.build({ width = 144, hidden = 9, battery = true, batteryThreshold = 80 }, actions)
  eq("메뉴: 항목 네 개", #normal, 4)
  eq("메뉴: 첫 항목은 다시 맞추기", normal[1].title, "다시 맞추기")
  check("메뉴: 다시 맞추기에 동작이 달려 있다", type(normal[1].fn) == "function")
  eq("메뉴: 둘째는 배터리 표시 서브메뉴", normal[2].title, "배터리 표시")
  eq("메뉴: 셋째는 구분선", normal[3].title, "-")
  eq("메뉴: 정상 상태 표시", normal[4].title, "폭 144 · 접힘 9개")
  check("메뉴: 상태 표시는 누를 수 없다", normal[4].disabled == true)
  normal[1].fn()
  check("메뉴: 다시 맞추기가 넘겨받은 동작을 부른다", fired)

  local sub = normal[2].menu
  eq("서브메뉴: 배터리로 돌 때만 + 임계값 다섯", #sub, 1 + #menuBuilder.THRESHOLDS)
  eq("서브메뉴: 첫 항목", sub[1].title, "배터리로 돌 때만")
  eq("서브메뉴: 임계값 항목 제목", sub[2].title, "50% 이하")
  eq("서브메뉴: 마지막 임계값", sub[#sub].title, "90% 이하")
  local checkedTitles = {}
  for _, item in ipairs(sub) do if item.checked then checkedTitles[#checkedTitles + 1] = item.title end end
  eq("서브메뉴: 현재 값 하나에만 체크", table.concat(checkedTitles, ","), "80% 이하")
  sub[1].fn()
  eq("서브메뉴: 배터리로 돌 때만 → nil 을 넘긴다", chosen, nil)
  sub[3].fn()
  eq("서브메뉴: 60% 이하 → 60 을 넘긴다", chosen, 60)

  local none = menuBuilder.build({ width = 144, hidden = 0, battery = true, batteryThreshold = nil }, actions)
  check("서브메뉴: 임계값 없음이면 첫 항목에 체크", none[2].menu[1].checked == true)
  check("서브메뉴: 임계값 없음이면 나머지는 체크 없음", not none[2].menu[2].checked)

  local off = menuBuilder.build({ width = 144, hidden = 0, battery = false }, actions)
  eq("메뉴: 배터리 규칙을 껐으면 서브메뉴가 없다", #off, 3)
  eq("메뉴: 배터리 규칙을 껐을 때 둘째는 구분선", off[2].title, "-")

  eq("메뉴: 펼침 상태 표시",
     menuBuilder.build({ width = 144, hidden = 0, expanded = true }, actions)[3].title, "펼침 상태")
  eq("메뉴: 잠금·절전 표시",
     menuBuilder.build({ width = 144, suspended = true }, actions)[3].title, "잠금·절전 중")
  eq("메뉴: 중단이 펼침보다 앞선다",
     menuBuilder.statusTitle({ suspended = true, expanded = true }), "잠금·절전 중")
  eq("메뉴: 폭이 소수여도 적는다", menuBuilder.statusTitle({ width = 144.0, hidden = 2 }),
     "폭 144 · 접힘 2개")
  eq("메뉴: 값이 없으면 0 으로 적는다", menuBuilder.statusTitle({}), "폭 0 · 접힘 0개")
end

--------------------------------------------------------------------------
-- 19. 만족 구간이 몇 pt 뿐이어도 찾는다
--------------------------------------------------------------------------
do
  -- 빡빡한 메뉴바: 120 에서 왼쪽이 다 접히고 125 에서 구분자까지 접힌다 (실측 배치)
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "B", "SEP", "C" },
    hiddenFor = thresholds({
      { from = 125, hidden = { "H", "A", "B", "SEP" } },
      { from = 120, hidden = { "H", "A", "B" } },
      { from = 70, hidden = { "H", "A" } },
    }),
  })
  local w, sig = fit.decide(setWidth, probe, { maxWidth = 1512 })
  check("좁은 구간: 결과가 [120,125) 안", w >= 120 and w < 125, "폭 " .. tostring(w))
  eq("좁은 구간: 마지막에 적용한 폭 = 결과", last(trace), w)
  eq("좁은 구간: 실패 서명이 없다", sig, nil)
end

--------------------------------------------------------------------------
-- 20. 마지막 왼쪽 항목과 구분자가 함께 접히면 만족 구간이 없다
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "SEP", "B" },
    hiddenFor = thresholds({
      { from = 90, hidden = { "H", "A", "SEP" } },
      { from = 40, hidden = { "H" } },
    }),
  })
  local logged = false
  local w, sig = fit.decide(setWidth, probe, { maxWidth = 1512, log = function() logged = true end })
  eq("동시 접힘: 폭 0", w, 0)
  eq("동시 접힘: 폭 0 으로 되돌렸다", last(trace), 0)
  check("동시 접힘: 실패 서명을 돌려준다", sig ~= nil)
  check("동시 접힘: 로그를 남겼다", logged)
end

--------------------------------------------------------------------------
-- 21. 시스템 항목은 접히면 판독 목록에서 사라진다 — 이름 없이도 수렴한다
--------------------------------------------------------------------------
do
  -- 배터리(MenuBarAgent)는 접히는 순간 AXChildren 에서 빠진다. 이웃 key 에 기대면 흔들린다.
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "BAT", "SEP", "C" },
    vanish = { BAT = true },
    hiddenFor = thresholds({
      { from = 200, hidden = { "H", "A", "BAT", "SEP" } },
      { from = 120, hidden = { "H", "A", "BAT" } },
      { from = 60, hidden = { "H", "A" } },
    }),
  })
  local w = fit.decide(setWidth, probe, { maxWidth = 1512 })
  check("사라지는 항목: 결과가 [120,200) 안", w >= 120 and w < 200, "폭 " .. tostring(w))
  eq("사라지는 항목: 마지막에 적용한 폭 = 결과", last(trace), w)
end

--------------------------------------------------------------------------
-- 22. 추정이 맞으면 한 걸음에 끝난다
--------------------------------------------------------------------------
do
  -- 왼쪽에 보이는 항목 폭 합 118, 여유 36 → 답 82 (실측 배치). 추정 78 → 82 로 두 걸음 안.
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "B", "C", "D", "SEP", "E" },
    widths = { A = 36, B = 26, C = 34, D = 22 },
    hiddenFor = thresholds({
      { from = 87, hidden = { "H", "A", "B", "C", "D", "SEP" } },
      { from = 82, hidden = { "H", "A", "B", "C", "D" } },
      { from = 60, hidden = { "H", "A", "B", "C" } },
      { from = 30, hidden = { "H", "A" } },
    }),
  })
  local w = fit.decide(setWidth, probe, { maxWidth = 1512 })
  check("추정 출발: 결과가 [82,87) 안", w >= 82 and w < 87, "폭 " .. tostring(w))
  check("추정 출발: 여덟 걸음 이내", #trace <= 8, "setWidth 호출 " .. #trace .. "회: " .. table.concat(trace, ","))
  check("추정 출발: 폭 0 을 거치지 않는다", not contains(trace, 0), table.concat(trace, ","))
end

--------------------------------------------------------------------------
-- 23. 구분자가 보이는 채로 왼쪽 항목이 생기면 지금 폭에서 더한다
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "N", "SEP", "B" },
    widths = { N = 50 },
    hiddenFor = thresholds({
      { from = 260, hidden = { "H", "A", "N", "SEP" } },
      { from = 150, hidden = { "H", "A", "N" } },
      { from = 100, hidden = { "H", "A" } },
    }),
    width = 145,
  })
  local w = fit.decide(setWidth, probe, { currentWidth = 145, maxWidth = 1512 })
  check("증분 탐색: 결과가 [150,260) 안", w >= 150 and w < 260, "폭 " .. tostring(w))
  check("증분 탐색: 폭 0 을 거치지 않는다", not contains(trace, 0), table.concat(trace, ","))
  check("증분 탐색: 현재 폭보다 작은 값을 시도하지 않는다", (function() for _, v in ipairs(trace) do if v < 145 then return false end end return true end)(), table.concat(trace, ","))
end

--------------------------------------------------------------------------
-- 24. 지난 답(hint)이 맞으면 한 걸음에 끝나고, 틀리면 탐색으로 넘어간다
--------------------------------------------------------------------------
do
  local spec = {
    order = { "H", "A", "B", "SEP", "C" },
    widths = { A = 120, B = 120 },
    hiddenFor = thresholds({
      { from = 300, hidden = { "H", "A", "B", "SEP" } },
      { from = 149, hidden = { "H", "A", "B" } },
      { from = 60, hidden = { "H", "A" } },
    }),
  }
  local setWidth, probe, trace = fakeBar.new(spec)
  local w = fit.decide(setWidth, probe, { maxWidth = 1512, hint = 149 })
  eq("hint 적중: 지난 답 그대로", w, 149)
  eq("hint 적중: 한 걸음", #trace, 1)

  local setWidth2, probe2, trace2 = fakeBar.new(spec)
  local w2 = fit.decide(setWidth2, probe2, { maxWidth = 1512, hint = 350 })   -- 구분자까지 접히는 값
  check("hint 오답(넓음): 그래도 수렴", w2 >= 149 and w2 < 300, "폭 " .. tostring(w2))
  eq("hint 오답(넓음): 첫 시도는 hint", trace2[1], 350)

  local setWidth3, probe3, trace3 = fakeBar.new(spec)
  local w3 = fit.decide(setWidth3, probe3, { maxWidth = 1512, hint = 100 })   -- 아직 안 접히는 값
  check("hint 오답(좁음): 그래도 수렴", w3 >= 149 and w3 < 300, "폭 " .. tostring(w3))

  local snapA = { sep = { key = "SEP", x = 900 }, items = { { key = "b", x = 1 }, { key = "a", x = 2 } } }
  local snapB = { sep = { key = "SEP", x = 500 }, items = { { key = "a", x = 9 }, { key = "b", x = 1 } } }
  eq("keyset: 순서·좌표가 달라도 구성이 같으면 같다", fit.keyset(snapA), fit.keyset(snapB))
  check("keyset: 항목이 늘면 다르다", fit.keyset(snapA) ~= fit.keyset({ sep = snapA.sep, items = { { key = "a", x = 1 }, { key = "b", x = 2 }, { key = "c", x = 3 } } }))
  eq("keyset: 구분자가 없으면 nil", fit.keyset({ items = {} }), nil)
end

--------------------------------------------------------------------------
-- 26. 시스템이 접지 않으면(« 없음, 항목이 뒤로 밀리기만 함) 폭 합 + 여유에서 포기한다
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "A", "B", "SEP", "C" },
    noChevron = true,
    widths = { A = 40, B = 30 },
    hiddenFor = function() return nil end,   -- 어떤 폭에서도 아무것도 접히지 않는다
  })
  local w, sig = fit.decide(setWidth, probe, { maxWidth = 1512 })
  eq("폭주 방지: 폭 0 으로 끝난다", w, 0)
  check("폭주 방지: 실패 서명을 돌려준다", sig ~= nil)
  local maxTried = 0
  for _, v in ipairs(trace) do if v > maxTried then maxTried = v end end
  check("폭주 방지: 폭 합(70) + 여유 안에서 멈춘다", maxTried <= 70 + fit.MAX_OVERSHOOT, "최대 " .. maxTried)
end

--------------------------------------------------------------------------
-- 18. 상태 점검 함수 자체
--------------------------------------------------------------------------
do
  local function snapshot(sepX, itemXs, chevronX)
    local snap = { sep = sepX and { key = "SEP", x = sepX } or nil, chevronX = chevronX, items = {} }
    for i, x in ipairs(itemXs) do snap.items[i] = { key = "I" .. i, x = x } end
    return snap
  end
  check("satisfied: 왼쪽이 전부 접혔으면 참", fit.satisfied(snapshot(920, { 810, 815 }, 900)))
  check("satisfied: 왼쪽에 보이는 항목이 있으면 거짓",
        not fit.satisfied(snapshot(960, { 810, 940 }, 900)))
  check("satisfied: 구분자가 접혔으면 거짓", not fit.satisfied(snapshot(880, { 810 }, 900)))
  check("satisfied: 구분자 오른쪽 항목은 상관없다", fit.satisfied(snapshot(920, { 810, 980 }, 900)))
  check("satisfied: 스냅샷이 없으면 거짓", not fit.satisfied(nil))
  check("satisfied: 구분자가 없으면 거짓", not fit.satisfied(snapshot(nil, { 810 }, 900)))
end

--------------------------------------------------------------------------
-- 27. 항목을 구분자 오른쪽으로 옮기는 ⌘+드래그 계획
--------------------------------------------------------------------------
do
  local sep = { x = 900, y = 0, w = 150, h = 24 }
  local d = place.dragToRightOf({ x = 700, y = 0, w = 26, h = 24 }, sep)
  check("드래그: 왼쪽에 있으면 계획이 나온다", d ~= nil)
  eq("드래그: 시작은 항목 중심", d.from.x, 713)
  eq("드래그: 끝은 구분자 오른쪽 + 여백 + 반폭", d.to.x, 900 + 150 + 4 + 13)
  eq("드래그: y 는 항목 중심", d.to.y, 12)
  eq("드래그: 이미 오른쪽이면 nil", place.dragToRightOf({ x = 1100, y = 0, w = 26, h = 24 }, sep), nil)
  eq("드래그: 항목이 없으면 nil", place.dragToRightOf(nil, sep), nil)
  eq("드래그: 구분자가 없으면 nil", place.dragToRightOf({ x = 700, y = 0, w = 26, h = 24 }, nil), nil)
  check("옮겨짐 판정: 구분자 오른쪽 끝을 넘으면 참", place.isRightOf({ x = 1060, w = 26 }, { x = 1040, w = 18 }))
  check("옮겨짐 판정: 구분자와 겹치거나 왼쪽이면 거짓", not place.isRightOf({ x = 1027, w = 22 }, { x = 1040, w = 18 }))
  check("옮겨짐 판정: 항목이 없으면 거짓", not place.isRightOf(nil, { x = 1040, w = 18 }))
end

--------------------------------------------------------------------------
-- 28. 카메라·마이크 인디케이터가 떠 있으면 폭을 건드리지 않는다
--------------------------------------------------------------------------
do
  local SIG = "기억해 둔 실패 서명"

  -- (a) 시스템이 인디케이터 자리를 내느라 구분자를 접은 상태 — 만족은 아니지만 탐색하지 않는다
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "SEP", "B" },
    hiddenFor = function() return { "H", "A", "SEP" } end,
    width = 160,
    pinned = true,
  })
  local logged = false
  local w, sig = fit.decide(setWidth, probe, {
    currentWidth = 160, lastFailSig = SIG, log = function() logged = true end,
  })
  eq("인디케이터: 현재 폭을 그대로 돌려준다", w, 160)
  eq("인디케이터: setWidth 를 부르지 않는다", #trace, 0)
  eq("인디케이터: 기억한 서명을 그대로 돌려준다", sig, SIG)
  check("인디케이터: 로그를 남겼다", logged)

  -- (b) 인디케이터가 떠 있는데 왼쪽에 보이는 항목이 있어도 탐색하지 않는다
  local setWidth2, probe2, trace2 = fakeBar.new({
    order = { "H", "A", "SEP", "B" },
    hiddenFor = function() return { "H" } end,
    width = 0,
    pinned = true,
  })
  local w2 = fit.decide(setWidth2, probe2, { currentWidth = 0 })
  eq("인디케이터+왼쪽 노출: 폭 0 그대로", w2, 0)
  eq("인디케이터+왼쪽 노출: setWidth 를 부르지 않는다", #trace2, 0)

  -- (c) 인디케이터가 사라지면 평소대로 탐색한다
  local setWidth3, probe3, trace3 = fakeBar.new({
    order = { "H", "A", "SEP", "B" },
    hiddenFor = thresholds({
      { from = 300, hidden = { "H", "A", "SEP" } },
      { from = 100, hidden = { "H", "A" } },
    }),
    pinned = false,
  })
  local w3 = fit.decide(setWidth3, probe3)
  check("인디케이터 없음: 탐색해서 [100,300) 안을 고른다", w3 >= 100 and w3 < 300, "폭 " .. tostring(w3))
  check("인디케이터 없음: setWidth 를 불렀다", #trace3 > 0)
end

--------------------------------------------------------------------------
-- 29. 시스템 항목 규칙: 원하는 표시 여부
--------------------------------------------------------------------------
do
  local both = { Battery = true, WiFi = true }
  local w = rules.wanted({ onBattery = false, wifiConnected = true }, both)
  eq("전원 연결이면 배터리 끔", w.Battery, false)
  eq("Wi-Fi 연결이면 Wi-Fi 끔", w.WiFi, false)
  w = rules.wanted({ onBattery = true, wifiConnected = false }, both)
  eq("배터리 구동이면 배터리 켬", w.Battery, true)
  eq("Wi-Fi 끊기면 Wi-Fi 켬", w.WiFi, true)
  w = rules.wanted({ onBattery = true, wifiConnected = false }, { Battery = true, WiFi = false })
  eq("규칙을 끈 항목은 건드리지 않는다", w.WiFi, nil)

  local th = { Battery = true, WiFi = true, batteryThreshold = 80 }
  eq("전원 연결·81% 이면 끔", rules.wanted({ onBattery = false, batteryPercent = 81, wifiConnected = true }, th).Battery, false)
  eq("전원 연결·80% 이면 켬", rules.wanted({ onBattery = false, batteryPercent = 80, wifiConnected = true }, th).Battery, true)
  eq("전원 연결·50% 이면 켬", rules.wanted({ onBattery = false, batteryPercent = 50, wifiConnected = true }, th).Battery, true)
  eq("배터리 구동이면 잔량과 무관하게 켬", rules.wanted({ onBattery = true, batteryPercent = 100, wifiConnected = true }, th).Battery, true)
  eq("임계값 없으면 잔량 무시", rules.wanted({ onBattery = false, batteryPercent = 10, wifiConnected = true }, both).Battery, false)
  eq("잔량 모르면 전원 연결로만 판단", rules.wanted({ onBattery = false, batteryPercent = nil, wifiConnected = true }, th).Battery, false)
  eq("이유: 배터리 구동", rules.batteryReason({ onBattery = true, batteryPercent = 42.7 }), "배터리 구동 42%")
  eq("이유: 전원 연결", rules.batteryReason({ onBattery = false, batteryPercent = 100 }), "전원 연결 100%")
  eq("이유: 잔량 없음", rules.batteryReason({ onBattery = false }), "전원 연결")
end

--------------------------------------------------------------------------
-- 30. 시스템 항목 규칙: 실제로 써야 할 변경만 고른다
--------------------------------------------------------------------------
do
  local c = rules.changes({ Battery = false, WiFi = false }, { Battery = nil, WiFi = false })
  eq("키 없음은 보임으로 보고 끈다", #c, 1)
  eq("바꿀 항목 이름", c[1].name, "Battery")
  eq("바꿀 값", c[1].visible, false)
  c = rules.changes({ Battery = true }, { Battery = true })
  eq("같은 값은 다시 쓰지 않는다", #c, 0)
  c = rules.changes({}, { Battery = false })
  eq("원하는 값이 없으면 건드리지 않는다", #c, 0)
end

--------------------------------------------------------------------------
-- 31. 시스템 항목 규칙: 플래그 변환
--------------------------------------------------------------------------
do
  eq("플래그 8 은 숨김", rules.flagToVisible(8), false)
  eq("플래그 2 는 표시", rules.flagToVisible(2), true)
  eq("키 없음은 표시", rules.flagToVisible(nil), true)
  eq("표시 → 2", rules.visibleToFlag(true), 2)
  eq("숨김 → 8", rules.visibleToFlag(false), 8)
end

--------------------------------------------------------------------------
-- 32. 시스템 항목 규칙: 상태 판독
--------------------------------------------------------------------------
do
  check("rssi 가 있으면 연결", rules.wifiConnected({ power = true, rssi = -48 }))
  check("rssi 0 이면 끊김", not rules.wifiConnected({ power = true, rssi = 0 }))
  check("전원 꺼짐이면 끊김", not rules.wifiConnected({ power = false, rssi = -48 }))
  check("정보 없음이면 끊김", not rules.wifiConnected(nil))
  check("Battery Power 면 배터리 구동", rules.onBattery("Battery Power"))
  check("AC Power 면 아님", not rules.onBattery("AC Power"))
  check("nil(배터리 없음)이면 아님", not rules.onBattery(nil))
end

--------------------------------------------------------------------------
-- 33. 시스템 항목 규칙: 구분자 오른쪽으로 옮길 항목
--------------------------------------------------------------------------
do
  eq("식별자: Battery", rules.MENU_EXTRA_ID.Battery, "com.apple.menuextra.battery")
  eq("식별자: WiFi", rules.MENU_EXTRA_ID.WiFi, "com.apple.menuextra.wifi")

  local want = { Battery = true, WiFi = true }
  local on = { { name = "WiFi", visible = true } }
  eq("옮길 항목: 막 켠 것만", table.concat(rules.toPlace(want, on), ","), "WiFi")
  eq("옮길 항목: 끈 것은 아니다", #rules.toPlace(want, { { name = "Battery", visible = false } }), 0)
  eq("옮길 항목: 바뀐 게 없으면 없다", #rules.toPlace(want, {}), 0)
  eq("옮길 항목: all 이면 켜져 있는 것 전부, Battery 먼저", table.concat(rules.toPlace(want, {}, true), ","), "Battery,WiFi")
  eq("옮길 항목: all 이어도 꺼진 항목은 아니다", table.concat(rules.toPlace({ Battery = false, WiFi = true }, {}, true), ","), "WiFi")
  eq("옮길 항목: all 이어도 규칙을 끈 항목은 아니다", table.concat(rules.toPlace({ Battery = true }, {}, true), ","), "Battery")
end

--------------------------------------------------------------------------

local summary = string.format("%d passed, %d failed", passed, #failures)
if #failures > 0 then
  error(summary .. "\n  " .. table.concat(failures, "\n  "), 0)
end
return summary
