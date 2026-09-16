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

--- hs.menubar:setMenu 에 넘길 메뉴 테이블.
--- @param state table menu.statusTitle 이 받는 것과 같다
--- @param onFit function "다시 맞추기" 를 눌렀을 때 실행할 것
--- @return table
function menu.build(state, onFit)
  return {
    { title = "다시 맞추기", fn = onFit },
    { title = "-" },
    { title = menu.statusTitle(state), disabled = true },
  }
end

return menu
