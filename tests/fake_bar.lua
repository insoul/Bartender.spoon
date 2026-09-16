--- fit.decide 에 주입할 가짜 메뉴바.
--- 실제 좌표 배치를 흉내낸다: 접힌 항목은 « 왼쪽에, 보이는 항목은 « 오른쪽에 순서대로 놓인다.
--- 순수 Lua — hs.* 를 쓰지 않는다.

local CHEVRON_X = 900
local STEP = 20

local fakeBar = {}

--- @param opts table
---   order      왼쪽→오른쪽 key 목록. 구분자는 "SEP".
---   hiddenFor  function(width) -> key 목록 또는 nil. nil/빈 목록이면 « 가 없는 상태.
---   noSep      true 면 판독 결과에서 구분자를 뺀다 (구분자 유실 상황)
--- @return setWidth, probe, trace  trace 는 setWidth 로 적용된 폭의 기록
function fakeBar.new(opts)
  local width = 0
  local trace = {}

  local function setWidth(w)
    width = w
    trace[#trace + 1] = w
  end

  local function probe()
    local hidden = {}
    local anyHidden = false
    for _, key in ipairs(opts.hiddenFor(width) or {}) do
      hidden[key] = true
      anyHidden = true
    end

    local snap = { items = {}, chevronX = anyHidden and CHEVRON_X or nil }
    local foldRank, showRank = 0, 0
    for _, key in ipairs(opts.order) do
      local x
      if hidden[key] then
        foldRank = foldRank + 1
        x = CHEVRON_X - 100 + foldRank            -- « 왼쪽에 순서대로 몰린다
      else
        showRank = showRank + 1
        x = CHEVRON_X + showRank * STEP         -- « 오른쪽에 순서대로
      end
      -- « 가 없으면 접힘 판정이 불가능하므로 원래 자리를 그대로 쓴다
      if not anyHidden then
        x = showRank * STEP
      end
      if key == "SEP" then
        if not opts.noSep then snap.sep = { key = key, x = x } end
      else
        snap.items[#snap.items + 1] = { key = key, x = x }
      end
    end
    return snap
  end

  return setWidth, probe, trace
end

return fakeBar
