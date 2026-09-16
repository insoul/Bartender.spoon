--- 탐색을 돌려도 되는 상태인지 가리는 판정.
--- hs.* 를 쓰지 않는 순수 Lua 다 — 상태와 앱 이름만 받는다.

local guard = {}

--- 잠금 화면을 그리는 프로세스. 이 앱이 앞에 있으면 화면이 잠겨 있다.
guard.LOGIN_WINDOW = "loginwindow"

--- 잠금·절전 중에는 메뉴바에 « 가 생기지 않는다. 구분자를 아무리 키워도 아무것도 접히지
--- 않으므로 탐색은 반드시 "만족하는 폭 없음"으로 끝나고, 그 실패가 기억으로 남으면
--- 잠금을 푼 뒤에도 같은 배치에서 탐색을 건너뛰어 접기가 풀린 채로 남는다.
--- @param suspended boolean|nil 전원·세션 이벤트로 알아낸 중단 상태
--- @param focusedAppName string|nil 지금 앞에 있는 앱 이름. 이벤트를 놓쳤을 때의 방어선이다
--- @return boolean
function guard.isSuspended(suspended, focusedAppName)
  if suspended then return true end
  return focusedAppName == guard.LOGIN_WINDOW
end

return guard
