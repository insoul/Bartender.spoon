--- 항목을 구분자 오른쪽으로 옮기는 ⌘+드래그의 계획과 결과 판정.
--- hs.* 를 쓰지 않는 순수 Lua 다 — 프레임 테이블만 받는다.
---
--- 항목의 저장 위치를 직접 쓰지 않고 드래그를 합성하는 이유: `NSStatusItem Preferred Position` 은
--- 켤 때 읽히지 않는다(2026-09-17 실측, macOS 27.0 — 값을 바꾸고 켜도, ControlCenter 를 다시 띄워도
--- 항목은 저장된 옛 자리에 놓인다). 드래그는 시스템이 알아서 저장하므로 좌표계를 몰라도 된다.

local place = {}

--- 항목을 구분자 오른쪽으로 옮기는 ⌘+드래그의 시작점과 끝점.
--- 이미 구분자 오른쪽에 있으면 nil. 끝점은 구분자 오른쪽 가장자리에서 gap 만큼 떨어진 항목 중심이다.
--- @param item table {x, y, w, h} 항목 프레임
--- @param sep table {x, y, w, h} 구분자 프레임
--- @param gap number|nil 기본 4
--- @return table|nil {from = {x, y}, to = {x, y}}
function place.dragToRightOf(item, sep, gap)
  if item == nil or sep == nil then return nil end
  if item.x > sep.x then return nil end
  gap = gap or 4
  local y = item.y + item.h / 2
  return {
    from = { x = item.x + item.w / 2, y = y },
    to = { x = sep.x + sep.w + gap + item.w / 2, y = y },
  }
end

--- 항목이 구분자 오른쪽 끝을 넘어 있는가. 드래그 뒤 결과를 확인할 때 쓴다.
--- @param item table|nil {x, w} 항목 프레임
--- @param sep table {x, w} 구분자 프레임
--- @return boolean
function place.isRightOf(item, sep)
  return item ~= nil and item.x >= sep.x + sep.w
end

return place
