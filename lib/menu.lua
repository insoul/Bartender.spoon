--- 구분자를 클릭했을 때 뜨는 메뉴의 구성.
--- hs.* 를 쓰지 않는 순수 Lua 다 — 상태 테이블을 받아 메뉴 테이블을 만든다.

local menu = {}

--- 여는 시점의 상태를 한 줄로 적는다. 손댈 수 없는 상태면 그 이유를 보여준다.
--- @param state table {suspended=boolean, expanded=boolean, width=number, hidden=number}
--- @return string
function menu.statusTitle(state)
  if state.suspended then return "잠금·절전 중" end
  if state.expanded then return "펼침 상태" end
  return string.format("폭 %d · 접힘 %d개", math.floor(state.width or 0), state.hidden or 0)
end

--- 핸드오프 항목이 있을 때 맨 위에 붙는 가져오기 항목의 제목
menu.HANDOFF_TITLE = "📱 iPhone 클립보드 가져오기"

--- hs.menubar:setMenu 에 넘길 메뉴 테이블.
--- @param state table menu.statusTitle 이 받는 것에 더해 {handoff=boolean}.
---                    handoff 가 참이면 iPhone 클립보드 가져오기를 맨 위에 단다
--- @param actions table {fit=function, openSettings=function, fetchHandoff=function}
--- @return table
function menu.build(state, actions)
  local items = {}
  if state.handoff then
    items[#items + 1] = { title = menu.HANDOFF_TITLE, fn = actions.fetchHandoff }
    items[#items + 1] = { title = "-" }
  end
  items[#items + 1] = { title = "다시 맞추기", fn = actions.fit }
  items[#items + 1] = { title = "설정…", fn = actions.openSettings }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = menu.statusTitle(state), disabled = true }
  return items
end

return menu
