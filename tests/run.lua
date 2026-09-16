--- Bartender.spoon 단위 테스트.
--- 독립 lua 인터프리터가 없으므로 Hammerspoon 의 Lua 로 돌린다:
---   osascript -e 'tell application "Hammerspoon" to execute lua code
---     "return dofile(\"<spoon>/tests/run.lua\")"'
--- 통과하면 요약 문자열을 돌려주고, 하나라도 실패하면 error 로 올린다.
--- 이 파일과 fake_bar, lib/fit 은 hs.* 를 쓰지 않는다.

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local fit = dofile(here .. "../lib/fit.lua")
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

-- 임계 폭을 구간으로 표현하는 hiddenFor 만들기
local function thresholds(spec)
  -- spec: {{from = <폭>, hidden = {키...}}, ...} 을 폭 내림차순으로 준다
  return function(w)
    for _, rule in ipairs(spec) do
      if w >= rule.from then return rule.hidden end
    end
    return nil
  end
end

--------------------------------------------------------------------------
-- 1. 정상 수렴: 이웃만 접히는 최소 폭을 찾는다
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "A", "SEP", "B", "C" },
    hiddenFor = thresholds({
      { from = 300, hidden = { "A", "SEP" } },
      { from = 100, hidden = { "A" } },
    }),
  })
  local w = fit.decide(setWidth, probe)
  check("정상 수렴: 결과가 [100,300) 안", w >= 100 and w < 300, "폭 " .. tostring(w))
  check("정상 수렴: 허용 오차 안에서 최소값", w < 100 + fit.TOLERANCE, "폭 " .. tostring(w))
  eq("정상 수렴: 마지막에 적용한 폭 = 결과", last(trace), w)
  check("정상 수렴: 탐색이 끝났다", #trace > 3, "시도 " .. #trace .. "회")
end

--------------------------------------------------------------------------
-- 2. 구분자가 먼저 접히면 폭을 줄인다
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "A", "SEP", "B" },
    hiddenFor = thresholds({
      { from = 200, hidden = { "SEP" } },   -- 구분자 혼자 너무 넓어 자기만 접힌다
      { from = 60, hidden = { "A" } },
    }),
  })
  local w = fit.decide(setWidth, probe)
  check("구분자 선접힘: 결과가 [60,200) 안", w >= 60 and w < 200, "폭 " .. tostring(w))
  check("구분자 선접힘: 첫 시도 300 을 거쳤다", contains(trace, 300), table.concat(trace, ","))
  check("구분자 선접힘: 300 이상을 적용한 채로 끝나지 않았다", last(trace) < 200,
        "마지막 " .. tostring(last(trace)))
end

--------------------------------------------------------------------------
-- 3. 구분자 왼쪽에 항목이 없으면 폭 0
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "SEP", "A", "B" },
    hiddenFor = thresholds({ { from = 100, hidden = { "SEP" } } }),
  })
  local w = fit.decide(setWidth, probe)
  eq("이웃 없음: 폭 0", w, 0)
  eq("이웃 없음: 폭 0 만 적용했다", #trace, 1)
  eq("이웃 없음: 적용값 0", trace[1], 0)
end

--------------------------------------------------------------------------
-- 4. 이미 접혀 있는 항목은 이웃 후보가 아니다
--------------------------------------------------------------------------
do
  -- 폭 0 에서 A 가 이미 접혀 있다. 보이는 왼쪽 항목이 없으므로 할 일이 없다.
  local setWidth, probe = fakeBar.new({
    order = { "A", "SEP", "B" },
    hiddenFor = function() return { "A" } end,
  })
  eq("이미 접힌 항목 제외: 폭 0", fit.decide(setWidth, probe), 0)
end

--------------------------------------------------------------------------
-- 5. 만족하는 폭이 없으면 폭 0 으로 되돌린다
--------------------------------------------------------------------------
do
  -- 어떤 폭에서도 구분자가 이웃보다 먼저 접힌다
  local setWidth, probe, trace = fakeBar.new({
    order = { "A", "SEP", "B" },
    hiddenFor = thresholds({ { from = 1, hidden = { "SEP" } } }),
  })
  local logged = false
  local w = fit.decide(setWidth, probe, { log = function() logged = true end })
  eq("만족값 없음: 폭 0", w, 0)
  eq("만족값 없음: 폭 0 으로 되돌렸다", last(trace), 0)
  check("만족값 없음: 로그를 남겼다", logged)
end

--------------------------------------------------------------------------
-- 6. « 가 없으면 아무것도 접히지 않은 상태로 본다
--------------------------------------------------------------------------
do
  -- 전 구간에서 « 가 없다 → 이웃이 끝까지 보이므로 만족값이 없다
  local setWidth, probe, trace = fakeBar.new({
    order = { "A", "SEP", "B" },
    hiddenFor = function() return nil end,
  })
  local w = fit.decide(setWidth, probe)
  eq("« 없음: 폭 0", w, 0)
  eq("« 없음: 폭 0 으로 되돌렸다", last(trace), 0)
  check("« 없음: 상한까지 올려봤다", contains(trace, 300), table.concat(trace, ","))
end

--------------------------------------------------------------------------
-- 7. 판독에서 구분자가 사라지면 즉시 포기한다
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "A", "SEP", "B" },
    hiddenFor = function() return nil end,
    noSep = true,
  })
  local logged = false
  eq("구분자 유실: 폭 0", fit.decide(setWidth, probe, { log = function() logged = true end }), 0)
  eq("구분자 유실: 폭 0 만 적용했다", #trace, 1)
  check("구분자 유실: 로그를 남겼다", logged)
end

--------------------------------------------------------------------------
-- 8. 이웃은 구분자 왼쪽에서 가장 오른쪽 항목이다
--------------------------------------------------------------------------
do
  -- B 가 구분자 바로 왼쪽. B 가 접히는 폭에서 멈춰야 하고, A 기준으로 가면 안 된다.
  local setWidth, probe = fakeBar.new({
    order = { "A", "B", "SEP", "C" },
    hiddenFor = thresholds({
      { from = 400, hidden = { "A", "B", "SEP" } },
      { from = 250, hidden = { "A", "B" } },
      { from = 120, hidden = { "A" } },     -- A 만 접힌 구간은 조건을 만족하지 않는다
    }),
  })
  local w = fit.decide(setWidth, probe)
  check("이웃 선택: 결과가 [250,400) 안", w >= 250 and w < 400, "폭 " .. tostring(w))
end

--------------------------------------------------------------------------
-- 9. 탐색 상한·오차는 opts 로 바꿀 수 있다
--------------------------------------------------------------------------
do
  local setWidth, probe, trace = fakeBar.new({
    order = { "A", "SEP" },
    hiddenFor = thresholds({ { from = 40, hidden = { "A" } } }),
  })
  local w = fit.decide(setWidth, probe, { maxWidth = 200, tolerance = 1 })
  check("opts: 상한 안에서 수렴", w >= 40 and w <= 41, "폭 " .. tostring(w))
  for _, v in ipairs(trace) do
    check("opts: 상한을 넘지 않았다", v <= 200, "폭 " .. tostring(v))
  end
end

--------------------------------------------------------------------------

local summary = string.format("%d passed, %d failed", passed, #failures)
if #failures > 0 then
  error(summary .. "\n  " .. table.concat(failures, "\n  "), 0)
end
return summary
