--- 구분자를 클릭했을 때 뜨는 메뉴의 구성.
--- hs.* 를 쓰지 않는 순수 Lua 다 — 상태 테이블을 받아 메뉴 테이블을 만든다.

local menu = {}

--- "배터리 표시" 서브메뉴에 늘어놓는 임계값(%). 전원이 연결돼 있어도 잔량이 이 값 이하면 배터리 항목을 보인다.
menu.THRESHOLDS = { 50, 60, 70, 80, 90 }

--- 여는 시점의 상태를 한 줄로 적는다. 손댈 수 없는 상태면 그 이유를 보여준다.
--- @param state table {suspended=boolean, expanded=boolean, width=number, hidden=number}
--- @return string
function menu.statusTitle(state)
  if state.suspended then return "잠금·절전 중" end
  if state.expanded then return "펼침 상태" end
  return string.format("폭 %d · 접힘 %d개", math.floor(state.width or 0), state.hidden or 0)
end

--- "배터리 표시" 서브메뉴. 지금 값 하나에만 체크가 붙는다. 고르면 onChoose(임계값 또는 nil) 을 부른다.
--- @param threshold number|nil 지금 임계값. nil 이면 배터리로 돌 때만 보인다
--- @param onChoose function(number|nil)
--- @return table
function menu.batterySubmenu(threshold, onChoose)
  local items = {
    { title = "배터리로 돌 때만", checked = threshold == nil, fn = function() onChoose(nil) end },
  }
  for _, t in ipairs(menu.THRESHOLDS) do
    items[#items + 1] = {
      title = string.format("%d%% 이하", t),
      checked = threshold == t,
      fn = function() onChoose(t) end,
    }
  end
  return items
end

--- 핸드오프 항목이 있을 때 맨 위에 붙는 가져오기 항목의 제목
menu.HANDOFF_TITLE = "📱 iPhone 클립보드 가져오기"

--- hs.menubar:setMenu 에 넘길 메뉴 테이블.
--- @param state table menu.statusTitle 이 받는 것에 더해 {battery=boolean, batteryThreshold=number|nil, handoff=boolean}.
---                    battery 가 참일 때만 "배터리 표시" 서브메뉴를 단다 — 규칙을 껐으면 바꿀 것이 없다.
---                    handoff 가 참이면 iPhone 클립보드 가져오기를 맨 위에 단다
--- @param actions table {fit=function, setBatteryThreshold=function(number|nil), fetchHandoff=function}
--- @return table
function menu.build(state, actions)
  local items = {}
  if state.handoff then
    items[#items + 1] = { title = menu.HANDOFF_TITLE, fn = actions.fetchHandoff }
    items[#items + 1] = { title = "-" }
  end
  items[#items + 1] = { title = "다시 맞추기", fn = actions.fit }
  if state.battery then
    items[#items + 1] = {
      title = "배터리 표시",
      menu = menu.batterySubmenu(state.batteryThreshold, actions.setBatteryThreshold),
    }
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = menu.statusTitle(state), disabled = true }
  return items
end

return menu
