--- 상태에 따라 시스템 메뉴바 항목(배터리·Wi-Fi)을 켜고 끄는 규칙.
--- hs.* 를 쓰지 않는 순수 Lua 다 — 상태 테이블을 받아 바꿀 항목 목록을 돌려준다.
---
--- 항목을 옮기는 대신 시스템 설정 → Menu Bar 의 스위치를 쓴다. 스위치는 per-host 도메인의 정수 플래그다:
---   defaults -currentHost write com.apple.controlcenter <Battery|WiFi> -int 2   -- 메뉴바에 표시
---   defaults -currentHost write com.apple.controlcenter <Battery|WiFi> -int 8   -- 숨김(Control Center 에만)
--- 쓰면 재시작 없이 바로 반영된다(macOS 27.0 실측, 양방향). 키가 없으면 표시 상태다.
--- 꺼진 항목은 접힌 것이 아니라 없는 것이므로 빈칸도 « 뒤 목록도 차지하지 않는다.
--- 예전 macOS 의 `NSStatusItem Visible <이름>` 키는 27 에서 읽히지 않는다.

local autoshow = {}

--- 규칙: 필요할 때만 보인다.
---   Battery — 전원이 빠져 배터리로 돌 때만
---   WiFi    — 연결이 끊겼을 때만
--- @param state table {onBattery=boolean, wifiConnected=boolean}
--- @param enabled table {Battery=boolean, WiFi=boolean} 규칙을 적용할 항목
--- @return table {Battery=boolean|nil, WiFi=boolean|nil} 항목별 원하는 표시 여부. 규칙이 꺼진 항목은 nil
function autoshow.wanted(state, enabled)
  local want = {}
  if enabled.Battery then want.Battery = state.onBattery == true end
  if enabled.WiFi then want.WiFi = state.wifiConnected == false end
  return want
end

--- 원하는 표시 여부와 지금 값을 비교해 실제로 써야 할 것만 고른다. 같은 값을 되풀이해 쓰지 않는다.
--- @param want table autoshow.wanted 의 결과
--- @param current table {Battery=boolean|nil, WiFi=boolean|nil} 지금 defaults 값. nil 은 키 없음(= 보임)
--- @return table { {name=<string>, visible=<boolean>}, ... }
function autoshow.changes(want, current)
  local out = {}
  for _, name in ipairs({ "Battery", "WiFi" }) do
    local target = want[name]
    if target ~= nil then
      local now = current[name]
      if now == nil then now = true end
      if now ~= target then out[#out + 1] = { name = name, visible = target } end
    end
  end
  return out
end

--- 메뉴바 표시 플래그 값
autoshow.FLAG_SHOWN = 2
autoshow.FLAG_HIDDEN = 8

--- defaults 에서 읽은 플래그를 표시 여부로 바꾼다. 키가 없으면(nil) 표시로 본다.
--- @param flag number|nil
--- @return boolean
function autoshow.flagToVisible(flag)
  return flag ~= autoshow.FLAG_HIDDEN
end

--- 표시 여부를 defaults 에 쓸 플래그로 바꾼다.
--- @param visible boolean
--- @return number
function autoshow.visibleToFlag(visible)
  return visible and autoshow.FLAG_SHOWN or autoshow.FLAG_HIDDEN
end

--- Wi-Fi 연결 여부. SSID 는 위치 권한이 없으면 nil 이라 쓸 수 없고, 연결이 끊기면 rssi 가 0 이 된다.
--- @param details table|nil hs.wifi.interfaceDetails() 결과
--- @return boolean
function autoshow.wifiConnected(details)
  if details == nil or details.power == false then return false end
  local rssi = details.rssi
  return rssi ~= nil and rssi ~= 0
end

--- 배터리 구동 여부. hs.battery.powerSource() 는 "AC Power" / "Battery Power" / nil(배터리 없음).
--- @param source string|nil
--- @return boolean
function autoshow.onBattery(source)
  return source == "Battery Power"
end

return autoshow
