--- iPhone 에서 넘어온 Universal Clipboard(핸드오프) 항목의 판별과 로컬 항목으로 다시 쓰기 위한 정리.
--- hs.* 를 쓰지 않는 순수 Lua 다 — hs.pasteboard 가 돌려준 테이블을 받아 판단만 한다.

local handoff = {}

--- 핸드오프 항목에 시스템이 붙이는 타입. 이 항목은 타입 목록만 있고 실제 데이터는 어떤 앱이 읽는 순간
--- iPhone 에서 가져온다. 클립보드 매니저(Paste 등)는 이 마커를 보고 항목을 건너뛴다 — 읽으면 곧 전송이라서다.
handoff.MARKER = "com.apple.is-remote-clipboard"

--- hs.pasteboard.allContentTypes() 결과(항목별 타입 목록의 목록)에 마커가 있으면 참.
--- 타입 목록 조회는 전송을 일으키지 않으므로 주기적으로 불러도 된다.
--- @param allTypes table|nil
--- @return boolean
function handoff.isRemote(allTypes)
  for _, types in ipairs(allTypes or {}) do
    for _, t in ipairs(types) do
      if t == handoff.MARKER then return true end
    end
  end
  return false
end

--- hs.pasteboard.readAllData() 결과에서 마커 타입과 빈 데이터를 뺀 새 테이블. 이걸 writeAllData 로 다시 쓰면
--- 마커 없는 로컬 항목이 되어 changeCount 가 바뀌고 클립보드 매니저가 저장한다.
--- 빈 데이터는 iPhone 쪽이 이미 만료(약 2분)돼 못 가져온 타입이다 — 그대로 쓰면 빈 항목이 된다.
--- 남는 타입이 없으면 nil — 가져올 것이 없다.
--- @param data table|nil 타입 → 바이트 문자열
--- @return table|nil
function handoff.strip(data)
  local out, any = {}, false
  for t, bytes in pairs(data or {}) do
    if t ~= handoff.MARKER and #bytes > 0 then
      out[t] = bytes
      any = true
    end
  end
  if not any then return nil end
  return out
end

return handoff
