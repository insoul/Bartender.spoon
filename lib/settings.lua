--- 설정창의 내용(HTML)과 창에서 올라오는 메시지의 해석.
--- hs.* 를 쓰지 않는 순수 Lua 다 — 창을 띄우고 메시지를 받는 일은 init.lua 가 한다.
---
--- 창 안의 JS 는 값이 바뀔 때마다 window.webkit.messageHandlers.<HANDLER>.postMessage({ batteryThreshold = ... })
--- 를 보낸다. 저장 버튼은 없다 — 시스템 설정처럼 바꾸는 즉시 반영한다.

local settings = {}

--- hs.webview.usercontent 에 등록하는 메시지 핸들러 이름
settings.HANDLER = "bartender"
--- 임계값 라디오를 골랐는데 아직 값이 없을 때 입력란에 보이는 값
settings.DEFAULT_THRESHOLD = 80

local PAGE = [[<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<title>Bartender 설정</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; padding: 20px 24px;
    font: 13px -apple-system, "Apple SD Gothic Neo", sans-serif;
    -webkit-user-select: none; cursor: default;
  }
  h1 { margin: 0 0 14px; font-size: 13px; font-weight: 600; }
  label { display: flex; align-items: center; gap: 6px; margin: 6px 0; }
  input[type=number] { width: 52px; font: inherit; text-align: right; }
  .hint { margin: 10px 0 0; font-size: 11px; opacity: .6; }
</style>
</head>
<body>
<h1>배터리 항목 표시</h1>
<label><input type="radio" name="mode" id="mode-onbattery" value="onbattery"%ONBATTERY%> 배터리로 돌 때만</label>
<label><input type="radio" name="mode" id="mode-threshold" value="threshold"%THRESHOLD%>
  배터리로 돌 때, 또는 잔량이 <input type="number" id="threshold" min="1" max="100" step="1" value="%VALUE%">% 이하일 때</label>
<p class="hint">전원이 연결돼 있어도 잔량이 이 값 이하면 메뉴바에 배터리 항목이 보입니다. Wi-Fi 항목은 끊겼을 때만 보입니다.</p>
<script>
  var mode = document.querySelectorAll('input[name=mode]');
  var input = document.getElementById('threshold');
  function send() {
    var useThreshold = document.getElementById('mode-threshold').checked;
    var n = parseInt(input.value, 10);
    if (useThreshold && !(n >= 1 && n <= 100)) return;   // 입력 중이거나 범위 밖이면 보내지 않는다
    window.webkit.messageHandlers.%HANDLER%.postMessage({ batteryThreshold: useThreshold ? n : false });
  }
  mode.forEach(function (r) { r.addEventListener('change', send); });
  input.addEventListener('change', send);
  input.addEventListener('focus', function () { document.getElementById('mode-threshold').checked = true; });
</script>
</body>
</html>
]]

--- 설정창에 실을 HTML. 지금 값이 체크된 상태로 렌더한다.
--- @param state table {batteryThreshold=number|nil}
--- @return string
function settings.html(state)
  local threshold = state.batteryThreshold
  local vars = {
    ONBATTERY = threshold == nil and " checked" or "",
    THRESHOLD = threshold ~= nil and " checked" or "",
    VALUE = tostring(math.floor(threshold or settings.DEFAULT_THRESHOLD)),
    HANDLER = settings.HANDLER,
  }
  return (PAGE:gsub("%%(%u+)%%", vars))
end

--- 창에서 올라온 메시지 본문을 해석한다.
--- @param body any postMessage 로 보낸 값. {batteryThreshold = number|false} 를 기대한다
--- @return boolean ok 형식이 맞는가
--- @return number|nil threshold ok 일 때의 임계값. nil 이면 배터리로 돌 때만
function settings.parse(body)
  if type(body) ~= "table" then return false end
  local v = body.batteryThreshold
  if v == false then return true, nil end
  local n = tonumber(v)
  if n == nil then return false end
  n = math.floor(n)
  if n < 1 or n > 100 then return false end
  return true, n
end

return settings
