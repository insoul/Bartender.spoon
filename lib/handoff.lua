--- iPhone 에서 넘어온 Universal Clipboard(핸드오프) 항목의 판별과 로컬 항목으로 다시 쓰기 위한 정리.
--- hs.* 를 쓰지 않는 순수 Lua 다 — hs.pasteboard 가 돌려준 테이블을 받아 판단만 한다.

local handoff = {}

--- 핸드오프 항목에 시스템이 붙이는 타입. 이 항목은 타입 목록만 있고 실제 데이터는 어떤 앱이 읽는 순간
--- iPhone 에서 가져온다. 클립보드 매니저(Paste 등)는 이 마커를 보고 항목을 건너뛴다 — 읽으면 곧 전송이라서다.
handoff.MARKER = "com.apple.is-remote-clipboard"

--- 그 자체로는 붙여넣을 수 없는 참조 타입. iPhone 사진 앱의 "복사"는 이미지 바이트 대신 이것과 file-url 만 싣는다.
--- Mac 에서는 뜻이 없고 클립보드 매니저가 "Unknown" 항목으로 보이게 하므로 다시 쓸 때 뺀다.
handoff.REFERENCE_TYPES = {
  ["com.apple.mobileslideshow.asset.localidentifier"] = true,   -- 사진 라이브러리 자산 ID (iPhone 안에서만 유효)
}

--- file-url 의 확장자 → 실어 줄 UTI. 시스템은 file-url 항목의 파일을 Mac 의 useractivityd 캐시로 옮겨 놓고
--- URL 을 그 경로로 바꿔 준다. 그 파일을 읽어 이 타입으로 실어야 이미지·동영상으로 붙여진다.
handoff.UTI_BY_EXTENSION = {
  png = "public.png", jpg = "public.jpeg", jpeg = "public.jpeg", heic = "public.heic",
  gif = "com.compuserve.gif", tif = "public.tiff", tiff = "public.tiff", webp = "org.webmproject.webp",
  mov = "com.apple.quicktime-movie", mp4 = "public.mpeg-4", m4v = "com.apple.m4v-video",
  pdf = "com.adobe.pdf",
}

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

--- 경로의 확장자로 UTI 를 고른다. 모르는 확장자·확장자 없음은 nil.
--- @param path string
--- @return string|nil
function handoff.utiForPath(path)
  local ext = path:match("%.([%w]+)$")
  return ext and handoff.UTI_BY_EXTENSION[ext:lower()] or nil
end

--- file:// URL 을 로컬 경로로 바꾼다. file 스킴이 아니면 nil.
--- @param url string
--- @return string|nil
function handoff.localPath(url)
  local encoded = url:match("^file://(/.*)$")
  if not encoded then return nil end
  return (encoded:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

--- hs.pasteboard.readAllData() 결과를 다시 쓸 수 있는 테이블로 정리한다. 이걸 writeAllData 로 쓰면
--- 마커 없는 로컬 항목이 되어 changeCount 가 바뀌고 클립보드 매니저가 저장한다.
--- - 마커·참조 타입·빈 데이터(만료돼 못 가져온 타입)는 뺀다.
--- - 콘텐츠 바이트 타입이 없고 file-url 만 있으면 readFile 로 그 파일을 읽어 확장자에 맞는 UTI 로 싣고 file-url 은 뺀다.
---   iPhone 사진 앱의 "복사"가 이 형태다 — 시스템이 파일은 Mac 으로 옮겨 주지만 바이트 타입은 싣지 않고, 그 파일도 곧 지운다.
--- 남는 콘텐츠 타입이 없으면 nil — 가져올 것이 없다. 참조만으로는 성공이 아니다.
--- @param data table|nil 타입 → 바이트 문자열
--- @param readFile function|nil (path) -> bytes|nil. 없으면 file-url 을 풀지 않는다
--- @return table|nil
function handoff.strip(data, readFile)
  local out, content = {}, false
  for t, bytes in pairs(data or {}) do
    if t ~= handoff.MARKER and not handoff.REFERENCE_TYPES[t] and #bytes > 0 then
      out[t] = bytes
      if t ~= "public.file-url" then content = true end
    end
  end
  if not content and out["public.file-url"] and readFile then
    local path = handoff.localPath(out["public.file-url"])
    local uti = path and handoff.utiForPath(path)
    local bytes = uti and readFile(path)
    if bytes and #bytes > 0 then
      out[uti] = bytes
      -- 참조는 버린다. 이 파일은 시스템이 곧(약 2분) 지우므로, 남기면 클립보드 매니저가 죽은 경로를 파일 항목으로 저장한다
      out["public.file-url"] = nil
      content = true
    end
  end
  if not content then return nil end
  return out
end

return handoff
