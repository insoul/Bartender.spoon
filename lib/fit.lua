--- 구분자 폭 탐색의 결정 로직.
--- hs.* 를 쓰지 않는 순수 Lua 다 — 판독 함수와 폭 설정 함수를 인자로 받으므로
--- 가짜 좌표 표를 주입해 단위 테스트할 수 있다.

local fit = {}

--- 판독 결과(스냅샷)의 형태
---   {
---     sep      = {key = <string>, x = <number>} 또는 nil,
---     chevronX = <number> 또는 nil,   -- « 의 x. 접힌 항목이 없으면 nil
---     expanded = <boolean>,           -- » 버튼이 있다. 사용자가 펼쳐 둔 상태다
---     items    = { {key = <string>, x = <number>}, ... },  -- 구분자를 뺀 나머지
---   }
--- 메뉴바 버튼은 세 상태를 가진다:
---   « 있음(chevronX)      — 접힌 항목이 있다
---   » 있음(expanded)      — 사용자가 펼쳐 두었다
---   버튼 없음(둘 다 없음) — 여유가 많아 접힌 것이 없을 뿐이다. 폭을 키우면 « 가 생긴다
--- 접힘 판정은 좌표 자체가 아니라 반드시 « 와의 비교로 한다.
--- 접힌 항목의 x 는 옛 값이거나 « 쪽으로 몰린 값이라 절대 좌표로는 판정할 수 없다.

--- 주 화면 폭을 모를 때 쓰는 탐색 상한. 실제로는 opts.maxWidth 로 주 화면 폭을 넘겨받는다.
fit.MAX_WIDTH = 600
fit.TOLERANCE = 1

local function isHidden(snap, x)
  return snap.chevronX ~= nil and x < snap.chevronX
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

--- 지금 폭이 이미 목표 상태인가: 구분자가 보이고, 구분자 왼쪽에 보이는 항목이 없다.
--- 폭이 필요 이상으로 넓어도 만족으로 본다 — 구분자 오른쪽은 먼저 접히지 않으므로 무해하고,
--- 굳이 다시 탐색하면 폭 0 을 거치면서 메뉴바가 깜빡인다.
--- @param snap table|nil
--- @return boolean
function fit.satisfied(snap)
  if snap == nil or snap.sep == nil then return false end
  if isHidden(snap, snap.sep.x) then return false end
  return findNeighbor(snap) == nil
end

--- 메뉴바 배치의 서명. 항목과 구분자를 x 순으로 늘어놓은 key 목록이다.
--- 항목이 생기고 사라지는 것도, 구분자가 자리를 옮긴 것도 이 문자열이 달라지는 것으로 잡힌다.
--- 상한이 달라지면 탐색 결과도 달라질 수 있으므로 함께 넣는다.
--- @param snap table|nil
--- @param maxWidth number
--- @return string|nil
function fit.signature(snap, maxWidth)
  if snap == nil or snap.sep == nil then return nil end
  local entries = { { key = snap.sep.key, x = snap.sep.x } }
  for _, item in ipairs(snap.items) do
    entries[#entries + 1] = item
  end
  -- x 가 같은 항목이 흔하다(접힌 항목은 « 쪽으로 몰린다). key 로 순서를 못박아 서명을 고정한다.
  table.sort(entries, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.key < b.key
  end)
  local keys = {}
  for i, entry in ipairs(entries) do keys[i] = entry.key end
  return table.concat(keys, ",") .. "|" .. tostring(maxWidth)
end

--- 구분자 바로 왼쪽 항목은 접히고 구분자 자신은 보이는, 가장 작은 폭을 찾는다.
--- 지금 상태가 이미 목표면 폭을 건드리지 않는다.
--- @param setWidth function(w) 폭을 적용한다. 실제 구현은 메뉴바가 자리를 잡을 때까지 기다린다.
--- @param probe function() -> snapshot
--- @param opts table|nil {maxWidth=, tolerance=, currentWidth=, lastFailSig=, log=function(fmt, ...)}
--- @return number 적용한 폭
--- @return string|nil 탐색이 실패한 배치의 서명. 다음 호출에 opts.lastFailSig 로 돌려주면
---                    같은 배치에서 같은 탐색을 되풀이하지 않는다. nil 이면 기억을 지운다.
---                    판단이 선 경로(만족·수렴)만 nil 을 돌려주고, 아무것도 알아내지 못한
---                    경로는 받은 opts.lastFailSig 를 그대로 되돌려 기억을 유지한다
function fit.decide(setWidth, probe, opts)
  opts = opts or {}
  local maxWidth = opts.maxWidth or fit.MAX_WIDTH
  local tolerance = opts.tolerance or fit.TOLERANCE
  local currentWidth = opts.currentWidth or 0
  local log = opts.log or function() end

  -- 아무것도 판단하지 못한 경로는 기억한 실패 서명을 그대로 돌려준다.
  -- 여기서 nil 을 돌려주면 기억이 지워져, 상황이 돌아왔을 때 같은 헛탐색을 다시 돈다.
  local snap = probe()
  if snap == nil or snap.sep == nil then
    log("구분자를 메뉴바에서 찾지 못했다")
    return currentWidth, opts.lastFailSig
  end

  -- 사용자가 « 를 눌러 펼쳐 둔 동안은 개입하지 않는다. 다시 접으면 다음 트리거가 처리한다.
  -- 버튼이 아예 없는 상태는 여기에 해당하지 않는다 — 접힌 것이 없을 뿐이고, 폭을 키우면 접힌다.
  if snap.expanded then
    log("메뉴바가 펼쳐진 상태다 — 폭을 그대로 둔다")
    return currentWidth, opts.lastFailSig
  end

  -- 목표에 닿았으면 기억을 지운다. 배치가 달라졌다는 뜻이다.
  if fit.satisfied(snap) then
    return currentWidth
  end

  -- 같은 배치에서 이미 탐색이 실패했으면 또 돌지 않는다. 배치가 바뀌어야 결과가 달라진다.
  if opts.lastFailSig ~= nil and fit.signature(snap, maxWidth) == opts.lastFailSig then
    log("같은 배치에서 이미 실패 — 배치가 바뀔 때까지 건너뜀")
    return currentWidth, opts.lastFailSig
  end

  setWidth(0)
  snap = probe()
  if snap == nil or snap.sep == nil then
    log("구분자를 메뉴바에서 찾지 못했다")
    return 0, opts.lastFailSig
  end
  -- 탐색이 실패하면 폭 0 으로 끝나므로, 다음 호출의 판독도 이 상태에서 시작한다.
  local zeroSig = fit.signature(snap, maxWidth)

  if findNeighbor(snap) == nil then
    log("구분자 왼쪽에 보이는 항목이 없다 — 접을 것이 없다")
    return 0
  end
  local baseX = snap.sep.x

  -- 폭이 커질수록 왼쪽 항목이 순서대로 접히므로 "구분자 왼쪽에 보이는 항목이 없다"는
  -- 폭에 대해 단조다. 그 술어가 처음 참이 되는 폭 T 를 이분 탐색으로 짚는다.
  -- 만족 구간은 T 부터 구분자 자신이 접히는 폭 직전까지인데, 메뉴바가 빡빡하면 이 구간이
  -- 몇 pt 에 불과하다(« 는 항목 경계 단위로만 움직여서, 왼쪽이 다 접힌 다음 경계가 구분자
  -- 오른쪽 끝이다). 그래서 구간을 더듬지 않고 T 를 정확히 찾은 뒤 그 자리에서 구분자가
  -- 보이는지만 확인한다.
  local function leftCleared(s)
    if s.sep == nil or isHidden(s, s.sep.x) then return true end
    return findNeighbor(s) == nil
  end

  local lo, hi = 0, maxWidth
  while hi - lo > tolerance do
    local mid = (lo + hi) // 2
    setWidth(mid)
    snap = probe()

    -- 여유를 넘는 폭을 주면 시스템이 메뉴바를 다시 배치하지 않는다. 항목 폭만 커지고
    -- 구분자는 제자리에 남아, 판독값이 폭 0 일 때와 같아진다. 왼쪽으로 요청한 만큼
    -- 움직였는지로 이 상태를 가려내고 "너무 넓다"로 취급한다. 아주 작은 폭은 움직임이
    -- 판독 오차 안이라 검사하지 않는다.
    local applied = mid < 8 or (snap.sep ~= nil and snap.sep.x <= baseX - mid / 2)

    if not applied or leftCleared(snap) then
      hi = mid            -- 왼쪽이 다 접혔다(또는 폭이 반영되지 않는다). 더 작은 값을 본다
    else
      lo = mid            -- 아직 왼쪽에 보이는 항목이 있다
    end
  end

  -- T 에서 구분자가 살아 있어야 한다. 마지막 왼쪽 항목과 함께 접혔으면 만족 구간이 없다.
  setWidth(hi)
  snap = probe()
  local ok = snap.sep ~= nil and not isHidden(snap, snap.sep.x) and findNeighbor(snap) == nil
  if not ok then
    log("조건을 만족하는 폭이 없다 (0..%d) — 폭 0 으로 둔다", maxWidth)
    setWidth(0)
    return 0, zeroSig
  end

  return hi
end

return fit
