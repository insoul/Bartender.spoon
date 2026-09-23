--- Bartender.spoon 단위 테스트.
--- 독립 lua 인터프리터가 없으므로 Hammerspoon 의 Lua 로 돌린다:
---   osascript -e 'tell application "Hammerspoon" to execute lua code
---     "return dofile(\"<spoon>/tests/run.lua\")"'
--- 통과하면 요약 문자열을 돌려주고, 하나라도 실패하면 error 로 올린다.
--- 이 파일과 fake_bar, lib/fit, lib/place, lib/rules, lib/handoff, lib/settings 는 hs.* 를 쓰지 않는다.

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local fit = dofile(here .. "../lib/fit.lua")
local guard = dofile(here .. "../lib/guard.lua")
local handoff = dofile(here .. "../lib/handoff.lua")
local settings = dofile(here .. "../lib/settings.lua")
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
  local fired, opened = false, false
  local actions = {
    fit = function() fired = true end,
    openSettings = function() opened = true end,
  }

  local normal = menuBuilder.build({ width = 144, hidden = 9 }, actions)
  eq("메뉴: 항목 네 개", #normal, 4)
  eq("메뉴: 첫 항목은 다시 맞추기", normal[1].title, "다시 맞추기")
  check("메뉴: 다시 맞추기에 동작이 달려 있다", type(normal[1].fn) == "function")
  eq("메뉴: 둘째는 설정…", normal[2].title, "설정…")
  eq("메뉴: 셋째는 구분선", normal[3].title, "-")
  eq("메뉴: 정상 상태 표시", normal[4].title, "폭 144 · 접힘 9개")
  check("메뉴: 상태 표시는 누를 수 없다", normal[4].disabled == true)
  normal[1].fn()
  check("메뉴: 다시 맞추기가 넘겨받은 동작을 부른다", fired)
  normal[2].fn()
  check("메뉴: 설정… 이 설정창 열기를 부른다", opened)

  eq("메뉴: 펼침 상태 표시",
     menuBuilder.build({ width = 144, hidden = 0, expanded = true }, actions)[4].title, "펼침 상태")
  eq("메뉴: 잠금·절전 표시",
     menuBuilder.build({ width = 144, suspended = true }, actions)[4].title, "잠금·절전 중")
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
-- 34. 핸드오프: 클립보드 타입 목록으로 iPhone 항목을 알아본다
--------------------------------------------------------------------------
do
  eq("마커 타입", handoff.MARKER, "com.apple.is-remote-clipboard")
  check("마커가 있으면 핸드오프", handoff.isRemote({ { "public.png", "com.apple.is-remote-clipboard" } }))
  check("마커가 없으면 아니다", not handoff.isRemote({ { "public.png", "public.utf8-plain-text" } }))
  check("항목이 없으면 아니다", not handoff.isRemote({}))
  check("nil 이면 아니다", not handoff.isRemote(nil))
  check("둘째 항목에 있어도 핸드오프", handoff.isRemote({ { "public.png" }, { "com.apple.is-remote-clipboard" } }))
end

--------------------------------------------------------------------------
-- 35. 핸드오프: 다시 쓸 데이터에서 마커만 뺀다
--------------------------------------------------------------------------
do
  local src = { ["public.png"] = "PNG", ["public.utf8-plain-text"] = "글", ["com.apple.is-remote-clipboard"] = "" }
  local got = handoff.strip(src)
  eq("마커는 빠진다", got["com.apple.is-remote-clipboard"], nil)
  eq("이미지는 남는다", got["public.png"], "PNG")
  eq("텍스트는 남는다", got["public.utf8-plain-text"], "글")
  eq("원본은 건드리지 않는다", src["com.apple.is-remote-clipboard"], "")
  eq("마커만 있으면 가져올 것이 없다", handoff.strip({ ["com.apple.is-remote-clipboard"] = "" }), nil)
  eq("빈 데이터는 버린다 (만료된 항목)", handoff.strip({ ["public.png"] = "", ["com.apple.is-remote-clipboard"] = "" }), nil)
  eq("빈 데이터만 버리고 나머지는 남긴다", handoff.strip({ ["public.png"] = "", ["public.utf8-plain-text"] = "글" })["public.utf8-plain-text"], "글")
  eq("빈 테이블이면 가져올 것이 없다", handoff.strip({}), nil)
  eq("nil 이면 가져올 것이 없다", handoff.strip(nil), nil)
end

--------------------------------------------------------------------------
-- 35b. 핸드오프: 참조만 온 항목은 file-url 의 파일을 읽어 콘텐츠 타입으로 채운다
--------------------------------------------------------------------------
do
  local ITEMS = "file:///Users/me/Library/Group%20Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/384741C3/IMG_1254.jpeg"
  local files = { ["/Users/me/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/384741C3/IMG_1254.jpeg"] = "JPEGBYTES" }
  local function readFile(path) return files[path] end

  -- (a) 사진 앱 복사: file-url + 사진 라이브러리 ID 만 온다. 파일을 읽어 public.jpeg 를 채우고 ID 는 버린다
  local src = { ["public.file-url"] = ITEMS, ["com.apple.mobileslideshow.asset.localidentifier"] = "A96/L0/001",
                ["com.apple.is-remote-clipboard"] = "" }
  local got = handoff.strip(src, readFile)
  check("사진 복사: 결과가 있다", got ~= nil)
  eq("사진 복사: file-url 의 파일이 public.jpeg 로 실린다", got and got["public.jpeg"], "JPEGBYTES")
  eq("사진 복사: 곧 지워질 file-url 은 뺀다", got and got["public.file-url"], nil)
  eq("사진 복사: 사진 라이브러리 ID 는 버린다", got and got["com.apple.mobileslideshow.asset.localidentifier"], nil)
  eq("사진 복사: 마커는 빠진다", got and got["com.apple.is-remote-clipboard"], nil)

  -- (b) 확장자별 UTI
  eq("UTI: png", handoff.utiForPath("/a/b/IMG.PNG"), "public.png")
  eq("UTI: jpg", handoff.utiForPath("/a/b/x.jpg"), "public.jpeg")
  eq("UTI: heic", handoff.utiForPath("/a/b/x.heic"), "public.heic")
  eq("UTI: gif", handoff.utiForPath("/a/b/x.gif"), "com.compuserve.gif")
  eq("UTI: mov", handoff.utiForPath("/a/b/x.mov"), "com.apple.quicktime-movie")
  eq("UTI: mp4", handoff.utiForPath("/a/b/x.mp4"), "public.mpeg-4")
  eq("UTI: pdf", handoff.utiForPath("/a/b/x.pdf"), "com.adobe.pdf")
  eq("UTI: 모르는 확장자는 nil", handoff.utiForPath("/a/b/x.xyz"), nil)
  eq("UTI: 확장자 없음", handoff.utiForPath("/a/b/noext"), nil)

  -- (c) 파일을 못 읽으면(만료·삭제) 참조뿐이라 가져올 것이 없다
  eq("파일 없음: nil", handoff.strip(src, function() return nil end), nil)
  -- (d) 콘텐츠 타입이 하나도 없으면 실패 — 참조 ID 만으로 성공 처리하지 않는다
  eq("ID 만 있으면 nil", handoff.strip({ ["com.apple.mobileslideshow.asset.localidentifier"] = "A" }, readFile), nil)
  -- (e) 이미지 바이트가 이미 있으면 파일을 읽지 않는다
  local direct = handoff.strip({ ["public.png"] = "PNG", ["public.file-url"] = ITEMS }, function() error("읽으면 안 된다") end)
  eq("바이트가 있으면 그대로", direct["public.png"], "PNG")
  eq("바이트가 있으면 file-url 도 그대로", direct["public.file-url"], ITEMS)
  -- (f) iPhone 내부 경로 같은 로컬이 아닌 URL 은 읽지 않는다
  eq("file 스킴이 아니면 nil", handoff.strip({ ["public.file-url"] = "https://x/y.png" }, readFile), nil)
  -- (g) 경로의 퍼센트 인코딩을 푼다
  local seen
  handoff.strip({ ["public.file-url"] = "file:///tmp/a%20b/c.png" }, function(path) seen = path; return "P" end)
  eq("퍼센트 디코딩", seen, "/tmp/a b/c.png")
  -- (h) readFile 없이 부르면 예전처럼 마커·빈 데이터만 뺀다 (텍스트 복사)
  eq("readFile 없음: 텍스트", handoff.strip({ ["public.utf8-plain-text"] = "글", ["com.apple.is-remote-clipboard"] = "" })["public.utf8-plain-text"], "글")
end

--------------------------------------------------------------------------
-- 36. 구분자 메뉴: 핸드오프가 있을 때만 가져오기 항목이 맨 위에 붙는다
--------------------------------------------------------------------------
do
  local fetched = false
  local actions = {
    fit = function() end,
    setBatteryThreshold = function() end,
    fetchHandoff = function() fetched = true end,
  }
  local base = { width = 144, hidden = 9, battery = true, batteryThreshold = 80 }

  local with = menuBuilder.build({ width = 144, hidden = 9, battery = true, batteryThreshold = 80, handoff = true }, actions)
  eq("핸드오프 메뉴: 항목 여섯 개", #with, 6)
  eq("핸드오프 메뉴: 첫 항목", with[1].title, "📱 iPhone 클립보드 가져오기")
  eq("핸드오프 메뉴: 둘째는 구분선", with[2].title, "-")
  eq("핸드오프 메뉴: 그 아래는 평소 메뉴", with[3].title, "다시 맞추기")
  with[1].fn()
  check("핸드오프 메뉴: 가져오기가 넘겨받은 동작을 부른다", fetched)

  local without = menuBuilder.build(base, actions)
  eq("핸드오프 없음: 평소 메뉴 그대로", #without, 4)
  eq("핸드오프 없음: 첫 항목은 다시 맞추기", without[1].title, "다시 맞추기")
end

--------------------------------------------------------------------------
-- 37. 설정창 — HTML 렌더와 메시지 해석
--------------------------------------------------------------------------
do
  local html = settings.html({ batteryThreshold = 80 })
  check("설정 HTML: 제목", html:find("Bartender 설정", 1, true) ~= nil)
  check("설정 HTML: 임계값 라디오에 체크", html:find('id="mode%-threshold"[^>]*checked', 1) ~= nil)
  check("설정 HTML: 배터리로 돌 때만 라디오는 체크 없음", html:find('id="mode%-onbattery"[^>]*checked', 1) == nil)
  check("설정 HTML: 입력값 80", html:find('id="threshold"[^>]*value="80"', 1) ~= nil)
  check("설정 HTML: 메시지 핸들러 이름", html:find("messageHandlers." .. settings.HANDLER, 1, true) ~= nil)

  local none = settings.html({ batteryThreshold = nil })
  check("설정 HTML: 임계값 없음이면 배터리로 돌 때만에 체크", none:find('id="mode%-onbattery"[^>]*checked', 1) ~= nil)
  check("설정 HTML: 임계값 없음이면 임계값 라디오는 체크 없음", none:find('id="mode%-threshold"[^>]*checked', 1) == nil)
  check("설정 HTML: 임계값 없음이면 입력값은 기본 80", none:find('id="threshold"[^>]*value="80"', 1) ~= nil)

  local ok, t = settings.parse({ batteryThreshold = 70 })
  check("메시지: 숫자", ok and t == 70, tostring(t))
  ok, t = settings.parse({ batteryThreshold = "65" })
  check("메시지: 숫자 문자열도 받는다", ok and t == 65, tostring(t))
  ok, t = settings.parse({ batteryThreshold = 72.9 })
  check("메시지: 소수는 내림", ok and t == 72, tostring(t))
  ok, t = settings.parse({ batteryThreshold = false })
  check("메시지: false 는 배터리로 돌 때만(nil)", ok and t == nil, tostring(t))
  check("메시지: 0 은 거부", not settings.parse({ batteryThreshold = 0 }))
  check("메시지: 101 은 거부", not settings.parse({ batteryThreshold = 101 }))
  check("메시지: 숫자 아닌 문자열은 거부", not settings.parse({ batteryThreshold = "abc" }))
  check("메시지: 키가 없으면 거부", not settings.parse({}))
  check("메시지: 테이블이 아니면 거부", not settings.parse("x"))
  check("메시지: nil 이면 거부", not settings.parse(nil))
end

--------------------------------------------------------------------------
-- 38. 앱 전환으로 예산이 줄어 구분자가 접혀도, 왼쪽 항목이 안 보이면 만족이다
--------------------------------------------------------------------------
do
  -- 구분자가 보일 때: 왼쪽 항목 목록을 알려 준다
  local setWidth, probe, trace = fakeBar.new({
    order = { "H", "A", "B", "SEP", "R" },
    hiddenFor = function() return { "H", "A", "B" } end,
    width = 147,
  })
  local w, sig, leftKeys = fit.decide(setWidth, probe, { currentWidth = 147 })
  eq("구분자 보임: 만족, 폭 그대로", w, 147)
  eq("구분자 보임: setWidth 안 부름", #trace, 0)
  table.sort(leftKeys or {})
  eq("구분자 보임: 왼쪽 항목 목록을 돌려준다", table.concat(leftKeys or {}, ","), "A,B,H")

  -- Xcode 앞: 시스템이 구분자까지 접었다. 왼쪽은 여전히 접힌 채 → 손대지 않는다
  local setWidth2, probe2, trace2 = fakeBar.new({
    order = { "H", "A", "B", "SEP", "R" },
    hiddenFor = function() return { "H", "A", "B", "SEP" } end,
    width = 147,
  })
  local w2, sig2, left2 = fit.decide(setWidth2, probe2, { currentWidth = 147, leftKeys = { "H", "A", "B" } })
  eq("구분자 접힘·왼쪽 접힘: 폭 그대로", w2, 147)
  eq("구분자 접힘·왼쪽 접힘: setWidth 안 부름 (폭 0 으로 내리지 않는다)", #trace2, 0)
  eq("구분자 접힘·왼쪽 접힘: 실패 서명 없음", sig2, nil)
  table.sort(left2 or {})
  eq("구분자 접힘: 기억한 왼쪽 목록을 그대로 돌려준다", table.concat(left2 or {}, ","), "A,B,H")

  -- 구분자가 너무 넓어 혼자 빠지고 왼쪽 항목이 되살아난 경우 → 불만족, 다시 잰다
  local setWidth3, probe3, trace3 = fakeBar.new({
    order = { "H", "A", "B", "SEP", "R" },
    hiddenFor = thresholds({
      { from = 300, hidden = { "H", "SEP" } },       -- 넓으면 구분자만 빠지고 A·B 가 돌아온다
      { from = 100, hidden = { "H", "A", "B" } },
    }),
    width = 400,
  })
  local w3 = fit.decide(setWidth3, probe3, { currentWidth = 400, leftKeys = { "H", "A", "B" } })
  check("구분자 접힘·왼쪽 노출: 다시 재서 [100,300) 을 고른다", w3 >= 100 and w3 < 300, "폭 " .. tostring(w3))
  check("구분자 접힘·왼쪽 노출: setWidth 를 불렀다", #trace3 > 0)

  -- 왼쪽 목록을 모르면(시작 직후) 예전처럼 잰다
  local setWidth4, probe4, trace4 = fakeBar.new({
    order = { "H", "A", "SEP", "R" },
    hiddenFor = thresholds({
      { from = 300, hidden = { "H", "A", "SEP" } },
      { from = 100, hidden = { "H", "A" } },
    }),
    width = 400,
  })
  local w4 = fit.decide(setWidth4, probe4, { currentWidth = 400 })
  check("왼쪽 목록 모름: 잰다", #trace4 > 0)
  check("왼쪽 목록 모름: 결과 [100,300)", w4 >= 100 and w4 < 300, "폭 " .. tostring(w4))

  -- satisfied 단독
  local snapHidden = { sep = { key = "SEP", x = 914 }, chevronX = 1061, expanded = false,
                       items = { { key = "A", x = 1043 }, { key = "B", x = 1045 }, { key = "R", x = 1085 } } }
  check("satisfied: 구분자 접힘 + 왼쪽 전부 접힘 + 목록 앎 → 참", fit.satisfied(snapHidden, { "A", "B" }))
  check("satisfied: 구분자 접힘 + 목록 모름 → 거짓", not fit.satisfied(snapHidden))
  local snapBack = { sep = { key = "SEP", x = 914 }, chevronX = 1000, expanded = false,
                     items = { { key = "A", x = 1043 }, { key = "B", x = 1045 }, { key = "R", x = 1085 } } }
  check("satisfied: 구분자 접힘 + 왼쪽 하나가 보임 → 거짓", not fit.satisfied(snapBack, { "A", "B" }))
  check("satisfied: 구분자 접힘 + 목록의 항목이 사라짐(앱 종료) → 참", fit.satisfied(snapHidden, { "A", "B", "gone" }))
end

--------------------------------------------------------------------------

local summary = string.format("%d passed, %d failed", passed, #failures)
if #failures > 0 then
  error(summary .. "\n  " .. table.concat(failures, "\n  "), 0)
end
return summary
