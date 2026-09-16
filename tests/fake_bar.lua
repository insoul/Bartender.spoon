--- fit.decide 에 주입할 가짜 메뉴바.
--- 실제 좌표 배치를 흉내낸다: 접힌 항목은 « 왼쪽에, 보이는 항목은 « 오른쪽에 순서대로 놓인다.
--- 접힌 항목이 없으면 같은 버튼이 » 가 되고(expanded), 여유가 아주 많으면 버튼 자체가 없다.
--- 순수 Lua — hs.* 를 쓰지 않는다.

local CHEVRON_X = 900
local STEP = 20

local fakeBar = {}

--- @param opts table
---   order      왼쪽→오른쪽 key 목록. 구분자는 "SEP".
---   hiddenFor  function(width) -> key 목록 또는 nil
---   width      시작 폭 (기본 0)
---   noSep      true 면 판독 결과에서 구분자를 뺀다 (구분자 유실 상황)
---   noChevron  true 면 접힌 항목이 없을 때 버튼 자체가 없는 것으로 본다 (여유가 많은 화면)
---   deadZone   이 폭 이상은 시스템이 배치에 반영하지 않는다 (폭 0 과 같은 판독값)
---   vanish     key 집합. 접히면 판독 목록에서 아예 빠지는 항목 (시스템 항목이 그렇다)
--- @return setWidth, probe, trace  trace 는 setWidth 로 적용된 폭의 기록
function fakeBar.new(opts)
  local width = opts.width or 0
  local trace = {}

  local function setWidth(w)
    width = w
    trace[#trace + 1] = w
  end

  local function probe()
    -- 여유를 넘는 폭은 배치에 반영되지 않는다 — 폭 0 인 것처럼 읽힌다
    local effective = width
    if opts.deadZone and width >= opts.deadZone then effective = 0 end

    local hidden = {}
    local anyHidden = false
    for _, key in ipairs(opts.hiddenFor(effective) or {}) do
      hidden[key] = true
      anyHidden = true
    end

    local snap = {
      items = {},
      chevronX = anyHidden and CHEVRON_X or nil,
      -- 접힌 것이 없을 때: 여유가 빠듯하면 » 가 있고, 아주 많으면 버튼 자체가 없다
      expanded = (not anyHidden) and not opts.noChevron,
    }
    local foldRank, showRank = 0, 0
    local passedSep = false
    for _, key in ipairs(opts.order) do
      local x
      if hidden[key] and opts.vanish and opts.vanish[key] then
        x = nil                                   -- 접히면 목록에서 사라진다
      elseif hidden[key] then
        foldRank = foldRank + 1
        x = CHEVRON_X - 100 + foldRank            -- « 왼쪽에 순서대로 몰린다
      else
        showRank = showRank + 1
        x = CHEVRON_X + 2000 + showRank * STEP    -- « 오른쪽에 순서대로
      end
      -- 구분자는 폭만큼 왼쪽으로 자라고, 그 왼쪽 항목들도 같이 밀린다.
      -- 반영되지 않은 폭에서는 아무도 움직이지 않는다.
      if x ~= nil and not passedSep then x = x - effective end
      if key == "SEP" then
        passedSep = true
        if not opts.noSep then snap.sep = { key = key, x = x } end
      elseif x ~= nil then
        snap.items[#snap.items + 1] = { key = key, x = x }
      end
    end
    return snap
  end

  return setWidth, probe, trace
end

return fakeBar
