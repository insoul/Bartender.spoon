--- 구분자 폭 탐색의 결정 로직.
--- hs.* 를 쓰지 않는 순수 Lua 다 — 판독 함수와 폭 설정 함수를 인자로 받으므로
--- 가짜 좌표 표를 주입해 단위 테스트할 수 있다.

local fit = {}

--- 판독 결과(스냅샷)의 형태
---   {
---     sep      = {key = <string>, x = <number>} 또는 nil,
---     chevronX = <number> 또는 nil,   -- « 의 x. 접힌 항목이 없으면 nil
---     expanded = <boolean>,           -- » 버튼이 있다. 사용자가 펼쳐 둔 상태다
---     pinned   = <boolean>,           -- 카메라·마이크 인디케이터처럼 접히지도 옮겨지지도 않는 시스템 항목이 떠 있다
---     items    = { {key = <string>, x = <number>, w = <number>}, ... },  -- 구분자·고정 항목을 뺀 나머지. w 는 항목 폭
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
--- 추정치는 "구분자 왼쪽에 보이는 항목 폭의 합"에서 이 값을 뺀 것이다. 메뉴바의 여유 공간만큼
--- 덜 필요한데, 여유는 읽을 수 없고 배치마다 0~40pt 로 달라(실측 36, 3) 중간값을 잡는다.
--- 어긋나면 탐색이 고친다. 같은 배치가 되풀이될 때는 opts.hint 로 지난 답을 받아 이 추정을 건너뛴다.
fit.ESTIMATE_OFFSET = 20
--- 추정에서 시작해 브래킷을 잡기까지의 첫 걸음. 실패할 때마다 두 배로 늘린다.
fit.FIRST_STEP = 4
--- 한 번의 탐색에서 폭을 바꿔 보는 최대 횟수
fit.MAX_STEPS = 24
--- 탐색 상한의 여유. 구분자는 밀어낼 항목 폭 합에 메뉴바의 빈 공간을 더한 만큼 넓어져야 왼쪽이 접히는데,
--- 빈 공간은 앱 메뉴 길이와 항목 구성에 따라 수백 pt 까지 벌어진다 (실측: 1512pt 화면, Safari 앞,
--- 항목 폭 합 104 에 답이 224~320 사이). 이 값이 그보다 작으면 답이 있어도 상한에서 끊겨 폭 0 으로 끝난다.
--- « 가 없는 상태에서 시스템이 접지 않고 항목을 노치·앱 메뉴 뒤로 밀어내기만 하면 "아직 보인다"
--- 판정이 끝나지 않는데, 이 상한이 그 폭주를 막는다. 폭주해도 걸음이 두 배씩 늘어 몇 걸음 안에 닿는다.
fit.MAX_OVERSHOOT = 400

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

--- 구분자가 보일 때, 구분자 왼쪽에 있는 항목들의 key 목록. 구분자가 없거나 접혀 있으면 nil.
--- 구분자가 접히면 좌표로는 왼쪽 항목을 가릴 수 없으므로(접힌 항목 좌표는 옛값), 보일 때 기억해 두었다가 쓴다.
--- @param snap table|nil
--- @return table|nil
function fit.leftKeys(snap)
  if snap == nil or snap.sep == nil or isHidden(snap, snap.sep.x) then return nil end
  local keys = {}
  for _, item in ipairs(snap.items) do
    if item.x < snap.sep.x then keys[#keys + 1] = item.key end
  end
  return keys
end

--- 지금 폭이 이미 목표 상태인가: 구분자 왼쪽에 보이는 항목이 없다.
--- 폭이 필요 이상으로 넓어도 만족으로 본다 — 구분자 오른쪽은 먼저 접히지 않으므로 무해하고,
--- 굳이 다시 탐색하면 폭 0 을 거치면서 메뉴바가 깜빡인다.
--- 구분자 자신이 접혀 있어도 만족일 수 있다: 메뉴가 넓은 앱(Xcode)이 앞에 오면 예산이 줄어 시스템이
--- 왼쪽 항목 다음으로 구분자를 접는데, 왼쪽 항목은 접힌 채 그대로라 손댈 것이 없다. 앱이 바뀌면 시스템이
--- 배치를 되돌린다 (실측). 이때 왼쪽 항목은 기억한 leftKeys 로 가린다 — 목록을 모르면 판단할 수 없어 거짓이다.
--- 구분자가 예산보다 넓어 혼자 빠지고 왼쪽 항목이 되살아난 경우는 목록의 항목이 보이므로 거짓이 된다.
--- @param snap table|nil
--- @param leftKeys table|nil 구분자가 마지막으로 보였을 때의 왼쪽 항목 key 목록 (fit.leftKeys)
--- @return boolean
function fit.satisfied(snap, leftKeys)
  if snap == nil or snap.sep == nil then return false end
  if isHidden(snap, snap.sep.x) then
    if leftKeys == nil then return false end
    local byKey = {}
    for _, item in ipairs(snap.items) do byKey[item.key] = item end
    for _, key in ipairs(leftKeys) do
      local item = byKey[key]
      if item ~= nil and not isHidden(snap, item.x) then return false end
    end
    return true
  end
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

--- 항목 구성만 담은 서명. 순서·좌표를 보지 않으므로 접힌 상태와 무관하게 같은 값이 나온다.
--- 호출자가 성공한 폭을 이 서명으로 기억해 두었다가 같은 구성에서 opts.hint 로 돌려준다.
--- 구분자 이동은 잡지 못하지만, 틀린 hint 는 검증에서 걸려 한 걸음만 낭비된다.
--- @param snap table|nil
--- @return string|nil
function fit.keyset(snap)
  if snap == nil or snap.sep == nil then return nil end
  local keys = {}
  for i, item in ipairs(snap.items) do keys[i] = item.key end
  table.sort(keys)
  return table.concat(keys, ",")
end

--- 구분자 왼쪽에서 보이는 항목들의 폭 합. 탐색의 출발점을 추정하는 데 쓴다.
local function visibleLeftWidth(snap)
  local sum = 0
  for _, item in ipairs(snap.items) do
    if item.x < snap.sep.x and not isHidden(snap, item.x) then
      sum = sum + (item.w or 0)
    end
  end
  return sum
end

--- 구분자 왼쪽 항목은 모두 접히고 구분자 자신은 보이는 폭을 찾는다.
--- 지금 상태가 이미 목표면 폭을 건드리지 않는다.
--- @param setWidth function(w) 폭을 적용한다. 실제 구현은 메뉴바가 자리를 잡을 때까지 기다린다.
--- @param probe function() -> snapshot
--- @param opts table|nil {maxWidth=, tolerance=, currentWidth=, lastFailSig=, hint=, leftKeys=, log=function(fmt, ...)}
---                    hint 는 같은 항목 구성(fit.keyset)에서 지난번 성공한 폭. 있으면 먼저 시도한다.
---                    leftKeys 는 지난 호출이 돌려준 왼쪽 항목 목록 — 구분자가 접혀 있을 때 만족 판정에 쓴다
--- @return number 적용한 폭
--- @return string|nil 탐색이 실패한 배치의 서명. 다음 호출에 opts.lastFailSig 로 돌려주면
---                    같은 배치에서 같은 탐색을 되풀이하지 않는다. nil 이면 기억을 지운다.
---                    판단이 선 경로(만족·수렴)만 nil 을 돌려주고, 아무것도 알아내지 못한
---                    경로는 받은 opts.lastFailSig 를 그대로 되돌려 기억을 유지한다
--- @return table|nil 왼쪽 항목 key 목록. 구분자가 보였으면 지금 판독에서 새로 만들고, 아니면 받은 것을 되돌린다.
---                    다음 호출에 opts.leftKeys 로 돌려준다
function fit.decide(setWidth, probe, opts)
  opts = opts or {}
  local maxWidth = opts.maxWidth or fit.MAX_WIDTH
  local tolerance = opts.tolerance or fit.TOLERANCE
  local currentWidth = opts.currentWidth or 0
  local log = opts.log or function() end
  local leftKeys = opts.leftKeys

  -- 아무것도 판단하지 못한 경로는 기억한 실패 서명을 그대로 돌려준다.
  -- 여기서 nil 을 돌려주면 기억이 지워져, 상황이 돌아왔을 때 같은 헛탐색을 다시 돈다.
  local snap = probe()
  if snap == nil or snap.sep == nil then
    log("구분자를 메뉴바에서 찾지 못했다")
    return currentWidth, opts.lastFailSig, leftKeys
  end
  leftKeys = fit.leftKeys(snap) or leftKeys

  -- 사용자가 « 를 눌러 펼쳐 둔 동안은 개입하지 않는다. 다시 접으면 다음 트리거가 처리한다.
  -- 버튼이 아예 없는 상태는 여기에 해당하지 않는다 — 접힌 것이 없을 뿐이고, 폭을 키우면 접힌다.
  if snap.expanded then
    log("메뉴바가 펼쳐진 상태다 — 폭을 그대로 둔다")
    return currentWidth, opts.lastFailSig, leftKeys
  end

  -- 고정 항목이 떠 있는 동안도 개입하지 않는다. 시스템이 그 자리를 내느라 구분자를 접어 두는데,
  -- 폭을 바꿔도 고정 항목은 접히지 않아 탐색이 헛돌고, 항목이 사라지면 시스템이 배치를 스스로
  -- 되돌린다. 만족 판정도 미룬다 — 이 상태에서 내린 판단은 항목이 사라지면 틀린 것이 된다.
  if snap.pinned then
    log("카메라·마이크 인디케이터가 떠 있다 — 폭을 그대로 둔다")
    return currentWidth, opts.lastFailSig, leftKeys
  end

  -- 목표에 닿았으면 기억을 지운다. 배치가 달라졌다는 뜻이다.
  if fit.satisfied(snap, leftKeys) then
    return currentWidth, nil, leftKeys
  end

  -- 같은 배치에서 이미 탐색이 실패했으면 또 돌지 않는다. 배치가 바뀌어야 결과가 달라진다.
  if opts.lastFailSig ~= nil and fit.signature(snap, maxWidth) == opts.lastFailSig then
    log("같은 배치에서 이미 실패 — 배치가 바뀔 때까지 건너뜀")
    return currentWidth, opts.lastFailSig, leftKeys
  end

  -- 출발점. 구분자가 보이면 지금 폭에 "왼쪽에 보이는 항목 폭 합"을 더한 근처가 답이다 —
  -- 폭 0 을 거치지 않으므로 메뉴바가 덜 흔들린다. 구분자가 접혀 있으면 어디까지 접혔는지
  -- 읽을 수 없으니(접힌 항목 좌표는 옛 값) 폭 0 으로 내려가 다시 잰다.
  local lo = nil          -- 아직 왼쪽에 보이는 항목이 있던 폭 중 가장 큰 값
  local hi = nil          -- 구분자가 접혔거나 폭이 반영되지 않던 폭 중 가장 작은 값
  local baseX, zeroSig
  local start
  if not isHidden(snap, snap.sep.x) then
    baseX = snap.sep.x + currentWidth   -- 폭 0 일 때의 자리로 환산
    lo = currentWidth
    start = currentWidth + visibleLeftWidth(snap) - fit.ESTIMATE_OFFSET
  else
    setWidth(0)
    snap = probe()
    if snap == nil or snap.sep == nil then
      log("구분자를 메뉴바에서 찾지 못했다")
      return 0, opts.lastFailSig, leftKeys
    end
    leftKeys = fit.leftKeys(snap) or leftKeys
    if findNeighbor(snap) == nil then
      log("구분자 왼쪽에 보이는 항목이 없다 — 접을 것이 없다")
      return 0, nil, leftKeys
    end
    baseX = snap.sep.x
    lo = 0
    start = visibleLeftWidth(snap) - fit.ESTIMATE_OFFSET
  end
  -- 탐색이 실패하면 폭 0 으로 끝나므로, 다음 호출의 판독도 그 상태에서 시작한다.
  -- 서명은 항목 순서만 담으므로 지금 판독으로 만들어도 같다.
  zeroSig = fit.signature(snap, maxWidth)

  -- 밀어낼 항목 폭 합에 여유를 더한 값이 실질 상한이다. 화면 폭까지 올라갈 이유가 없다.
  local ceiling = lo + visibleLeftWidth(snap) + fit.MAX_OVERSHOOT
  if ceiling < maxWidth then maxWidth = ceiling end

  -- 폭이 커질수록 왼쪽 항목이 순서대로 접히므로 "구분자 왼쪽에 보이는 항목이 없다"는
  -- 폭에 대해 단조다. 만족 구간은 그 술어가 참이 되는 폭부터 구분자 자신이 접히는 폭
  -- 직전까지인데, 메뉴바가 빡빡하면 몇 pt 에 불과하다(« 는 항목 경계 단위로만 움직여서,
  -- 왼쪽이 다 접힌 다음 경계가 구분자 오른쪽 끝이다). 추정치에서 출발해 어긋난 방향으로
  -- 걸음을 두 배씩 늘리며 브래킷을 잡고, 잡히면 그 안을 이분한다. 보통 한두 걸음에 끝난다.
  local function leftCleared(s)
    if s.sep == nil or isHidden(s, s.sep.x) then return true end
    return findNeighbor(s) == nil
  end

  local function judge(width)
    setWidth(width)
    snap = probe()
    -- 여유를 넘는 폭을 주면 시스템이 메뉴바를 다시 배치하지 않는다. 항목 폭만 커지고
    -- 구분자는 제자리에 남아, 판독값이 폭 0 일 때와 같아진다. 왼쪽으로 요청한 만큼
    -- 움직였는지로 이 상태를 가려내고 "너무 넓다"로 취급한다. 아주 작은 폭은 움직임이
    -- 판독 오차 안이라 검사하지 않는다.
    local moved = width < 8 or (snap.sep ~= nil and snap.sep.x <= baseX - width / 2)
    if not moved or snap.sep == nil or isHidden(snap, snap.sep.x) then return "wide" end
    if not leftCleared(snap) then return "narrow" end
    return "ok"
  end

  -- 만족한 폭 best 에서 출발해 더 작은 만족값을 찾는다. 아래로 걸음을 두 배씩 늘리다가
  -- 처음 실패한 자리와 마지막 성공 사이만 이분한다. 답이 가까이 있을수록 싸다.
  local function shrink(best, floor)
    local d = fit.FIRST_STEP
    local low = floor
    while best - low > tolerance do
      local cand = best - d
      if cand <= low then cand = (low + best) // 2 end
      local r = judge(cand)
      if r == "ok" then
        best = cand
        d = d * 2
      elseif r == "narrow" then
        low = cand
        d = tolerance   -- 브래킷이 잡혔다. 이제부터는 이분만 한다
      else
        break           -- 단조성이 깨졌다. 확인된 값으로 돌아간다
      end
    end
    setWidth(best)
    return best
  end

  local step = fit.FIRST_STEP
  local loProbed = false   -- lo 가 실제 판독으로 확인된 값인가 (처음엔 하한일 뿐이다)
  local w = math.max(lo + 1, math.min(math.floor(start), maxWidth))
  -- 같은 구성에서 성공했던 폭이 있으면 그것부터 본다. 맞으면 한 걸음에 끝난다.
  local hint = opts.hint
  if hint ~= nil and hint > lo and hint <= maxWidth then w = hint end
  for _ = 1, fit.MAX_STEPS do
    local r = judge(w)
    if r == "ok" then
      if w == hint then return w, nil, leftKeys end        -- 지난 답이 그대로 맞는다. 더 줄이지 않는다
      return shrink(w, lo), nil, leftKeys
    elseif r == "wide" then
      hi = w
    else
      lo = w
      loProbed = true
    end

    if hi ~= nil and loProbed then
      if hi - lo <= tolerance then break end
      w = (lo + hi) // 2
    elseif hi ~= nil then
      w = hi - step                          -- 위로 벗어났다. 아래로 걸음을 늘리며 내려온다
      step = step * 2
      if w <= lo then
        if hi - lo <= tolerance then break end
        loProbed = true
        w = (lo + hi) // 2
      end
    else
      w = lo + step                          -- 아직 좁다. 위로 걸음을 늘리며 올라간다
      step = step * 2
      if w > maxWidth then break end
    end
  end

  log("조건을 만족하는 폭이 없다 (0..%d) — 폭 0 으로 둔다", maxWidth)
  setWidth(0)
  return 0, zeroSig, leftKeys
end

return fit
