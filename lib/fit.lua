--- 구분자 폭 탐색의 결정 로직.
--- hs.* 를 쓰지 않는 순수 Lua 다 — 판독 함수와 폭 설정 함수를 인자로 받으므로
--- 가짜 좌표 표를 주입해 단위 테스트할 수 있다.

local fit = {}

--- 판독 결과(스냅샷)의 형태
---   {
---     sep      = {key = <string>, x = <number>} 또는 nil,
---     chevronX = <number> 또는 nil,   -- « 의 x. 접힌 항목이 없으면 nil
---     items    = { {key = <string>, x = <number>}, ... },  -- 구분자를 뺀 나머지
---   }
--- 접힘 판정은 좌표 자체가 아니라 반드시 « 와의 비교로 한다.
--- 접힌 항목의 x 는 옛 값이거나 « 쪽으로 몰린 값이라 절대 좌표로는 판정할 수 없다.

fit.MAX_WIDTH = 600
fit.TOLERANCE = 4

local function isHidden(snap, x)
  return snap.chevronX ~= nil and x < snap.chevronX
end

local function findByKey(snap, key)
  for _, item in ipairs(snap.items) do
    if item.key == key then return item end
  end
  return nil
end

--- 구분자 왼쪽에서 지금 보이는 항목 중 가장 오른쪽 것.
--- 이미 접혀 있는 항목은 어차피 접힌 채로 둘 것이므로 후보에서 뺀다.
local function findNeighbor(snap)
  local best = nil
  for _, item in ipairs(snap.items) do
    if item.x < snap.sep.x and not isHidden(snap, item.x) then
      if best == nil or item.x > best.x then best = item end
    end
  end
  return best
end

--- 구분자 바로 왼쪽 항목은 접히고 구분자 자신은 보이는, 가장 작은 폭을 찾는다.
--- @param setWidth function(w) 폭을 적용한다. 실제 구현은 메뉴바가 자리를 잡을 때까지 기다린다.
--- @param probe function() -> snapshot
--- @param opts table|nil {maxWidth=, tolerance=, log=function(fmt, ...)}
--- @return number 적용한 폭 (조건을 만족하는 값이 없으면 0)
function fit.decide(setWidth, probe, opts)
  opts = opts or {}
  local maxWidth = opts.maxWidth or fit.MAX_WIDTH
  local tolerance = opts.tolerance or fit.TOLERANCE
  local log = opts.log or function() end

  setWidth(0)
  local snap = probe()
  if snap == nil or snap.sep == nil then
    log("구분자를 메뉴바에서 찾지 못했다")
    return 0
  end

  local neighbor = findNeighbor(snap)
  if neighbor == nil then
    log("구분자 왼쪽에 보이는 항목이 없다 — 접을 것이 없다")
    return 0
  end

  -- 폭이 커질수록 (1) 이웃이 접히고 (2) 더 커지면 구분자까지 접힌다.
  -- 그 사이 구간의 왼쪽 끝을 이분 탐색으로 찾는다.
  local lo, hi, best = 0, maxWidth, nil
  while hi - lo > tolerance do
    local mid = (lo + hi) // 2
    setWidth(mid)
    snap = probe()

    local sepHidden = snap.sep == nil or isHidden(snap, snap.sep.x)
    local nb = findByKey(snap, neighbor.key)
    local neighborHidden = nb == nil or isHidden(snap, nb.x)

    if sepHidden then
      hi = mid            -- 너무 넓다. 구분자 자신이 밀려났다
    elseif not neighborHidden then
      lo = mid            -- 너무 좁다. 이웃이 아직 보인다
    else
      best = mid          -- 조건 만족. 더 작은 값이 있는지 계속 본다
      hi = mid
    end
  end

  if best == nil then
    log("조건을 만족하는 폭이 없다 (0..%d) — 폭 0 으로 둔다", maxWidth)
    setWidth(0)
    return 0
  end

  setWidth(best)
  return best
end

return fit
