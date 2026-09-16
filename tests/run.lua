--- Bartender.spoon 단위 테스트.
--- 독립 lua 인터프리터가 없으므로 Hammerspoon 의 Lua 로 돌린다:
---   osascript -e 'tell application "Hammerspoon" to execute lua code
---     "return dofile(\"<spoon>/tests/run.lua\")"'
--- 통과하면 요약 문자열을 돌려주고, 하나라도 실패하면 error 로 올린다.
--- 이 파일과 fake_bar, lib/fit 은 hs.* 를 쓰지 않는다.

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local fit = dofile(here .. "../lib/fit.lua")
local guard = dofile(here .. "../lib/guard.lua")
local menuBuilder = dofile(here .. "../lib/menu.lua")
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
  eq("정상 수렴: 탐색은 폭 0 에서 시작한다", trace[1], 0)
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
  check("구분자 선접힘: 첫 시도 300 을 거쳤다", contains(trace, 300), table.concat(trace, ","))
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
  local fired = false
  local onFit = function() fired = true end

  local normal = menuBuilder.build({ width = 144, hidden = 9 }, onFit)
  eq("메뉴: 항목 세 개", #normal, 3)
  eq("메뉴: 첫 항목은 다시 맞추기", normal[1].title, "다시 맞추기")
  check("메뉴: 다시 맞추기에 동작이 달려 있다", type(normal[1].fn) == "function")
  eq("메뉴: 가운데는 구분선", normal[2].title, "-")
  eq("메뉴: 정상 상태 표시", normal[3].title, "폭 144 · 접힘 9개")
  check("메뉴: 상태 표시는 누를 수 없다", normal[3].disabled == true)
  normal[1].fn()
  check("메뉴: 다시 맞추기가 넘겨받은 동작을 부른다", fired)

  eq("메뉴: 펼침 상태 표시",
     menuBuilder.build({ width = 144, hidden = 0, expanded = true }, onFit)[3].title, "펼침 상태")
  eq("메뉴: 잠금·절전 표시",
     menuBuilder.build({ width = 144, suspended = true }, onFit)[3].title, "잠금·절전 중")
  eq("메뉴: 중단이 펼침보다 앞선다",
     menuBuilder.statusTitle({ suspended = true, expanded = true }), "잠금·절전 중")
  eq("메뉴: 폭이 소수여도 적는다", menuBuilder.statusTitle({ width = 144.0, hidden = 2 }),
     "폭 144 · 접힘 2개")
  eq("메뉴: 값이 없으면 0 으로 적는다", menuBuilder.statusTitle({}), "폭 0 · 접힘 0개")
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

local summary = string.format("%d passed, %d failed", passed, #failures)
if #failures > 0 then
  error(summary .. "\n  " .. table.concat(failures, "\n  "), 0)
end
return summary
