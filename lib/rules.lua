--- 상태에 따라 시스템 메뉴바 항목(배터리·Wi-Fi)을 켜고 끄는 규칙.
--- hs.* 를 쓰지 않는 순수 Lua 다 — 상태 테이블을 받아 바꿀 항목 목록을 돌려준다.
---
--- 항목을 옮기는 대신 시스템 설정 → Menu Bar 의 스위치를 쓴다. 스위치는 per-host 도메인의 정수 플래그다:
---   defaults -currentHost write com.apple.controlcenter <Battery|WiFi> -int 2   -- 메뉴바에 표시
---   defaults -currentHost write com.apple.controlcenter <Battery|WiFi> -int 8   -- 숨김(Control Center 에만)
--- 쓰면 재시작 없이 바로 반영된다(macOS 27.0 실측, 양방향). 키가 없으면 표시 상태다.
--- 꺼진 항목은 접힌 것이 아니라 없는 것이므로 빈칸도 « 뒤 목록도 차지하지 않는다.
--- 예전 macOS 의 `NSStatusItem Visible <이름>` 키는 27 에서 읽히지 않는다.

local rules = {}

--- 규칙: 필요할 때만 보인다.
---   Battery — 전원이 빠져 배터리로 돌 때, 또는 전원이 연결돼 있어도 잔량이 임계값 이하일 때
---   WiFi    — 연결이 끊겼을 때만
--- @param state table {onBattery=boolean, batteryPercent=number|nil, wifiConnected=boolean}
--- @param config table {Battery=boolean, WiFi=boolean, batteryThreshold=number|nil}
---                     Battery/WiFi 는 규칙을 적용할지, batteryThreshold 는 이 잔량(%) 이하면 보일지. nil 이면 잔량 무시
--- @return table {Battery=boolean|nil, WiFi=boolean|nil} 항목별 원하는 표시 여부. 규칙이 꺼진 항목은 nil
function rules.wanted(state, config)
  local want = {}
  if config.Battery then
    want.Battery = rules.batteryNeeded(state, config.batteryThreshold)
  end
  if config.WiFi then want.WiFi = state.wifiConnected == false end
  return want
end

--- 배터리 항목이 필요한가. 배터리로 돌거나, 잔량이 임계값 이하면 그렇다.
--- @param state table {onBattery=boolean, batteryPercent=number|nil}
--- @param threshold number|nil
--- @return boolean
function rules.batteryNeeded(state, threshold)
  if state.onBattery then return true end
  return threshold ~= nil and state.batteryPercent ~= nil and state.batteryPercent <= threshold
end

--- 로그에 적을 배터리 상태 한 마디
--- @param state table {onBattery=boolean, batteryPercent=number|nil}
--- @return string
function rules.batteryReason(state)
  local pct = state.batteryPercent and string.format(" %d%%", math.floor(state.batteryPercent)) or ""
  return (state.onBattery and "배터리 구동" or "전원 연결") .. pct
end

--- 원하는 표시 여부와 지금 값을 비교해 실제로 써야 할 것만 고른다. 같은 값을 되풀이해 쓰지 않는다.
--- @param want table rules.wanted 의 결과
--- @param current table {Battery=boolean|nil, WiFi=boolean|nil} 지금 defaults 값. nil 은 키 없음(= 보임)
--- @return table { {name=<string>, visible=<boolean>}, ... }
function rules.changes(want, current)
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
rules.FLAG_SHOWN = 2
rules.FLAG_HIDDEN = 8

--- defaults 에서 읽은 플래그를 표시 여부로 바꾼다. 키가 없으면(nil) 표시로 본다.
--- @param flag number|nil
--- @return boolean
function rules.flagToVisible(flag)
  return flag ~= rules.FLAG_HIDDEN
end

--- 표시 여부를 defaults 에 쓸 플래그로 바꾼다.
--- @param visible boolean
--- @return number
function rules.visibleToFlag(visible)
  return visible and rules.FLAG_SHOWN or rules.FLAG_HIDDEN
end

--- Wi-Fi 연결 여부. SSID 는 위치 권한이 없으면 nil 이라 쓸 수 없고, 연결이 끊기면 rssi 가 0 이 된다.
--- @param details table|nil hs.wifi.interfaceDetails() 결과
--- @return boolean
function rules.wifiConnected(details)
  if details == nil or details.power == false then return false end
  local rssi = details.rssi
  return rssi ~= nil and rssi ~= 0
end

--- 배터리 구동 여부. hs.battery.powerSource() 는 "AC Power" / "Battery Power" / nil(배터리 없음).
--- @param source string|nil
--- @return boolean
function rules.onBattery(source)
  return source == "Battery Power"
end

--- Bartender 에 구분자 오른쪽으로 옮겨 달라고 넘길 항목. 막 켠 항목이 대상이고, all 이면 켜져 있는
--- 항목 전부다 — start 때 쓴다. Bartender 가 구분자를 다시 만들면(Hammerspoon 리로드) 켜져 있던 항목이
--- 구분자 뒤로 접혀 있을 수 있다.
--- @param want table rules.wanted 의 결과
--- @param changes table rules.changes 의 결과
--- @param all boolean|nil
--- @return table 항목 이름 목록 (Battery, WiFi 순)
function rules.toPlace(want, changes, all)
  local turnedOn = {}
  for _, change in ipairs(changes) do
    if change.visible then turnedOn[change.name] = true end
  end
  local out = {}
  for _, name in ipairs({ "Battery", "WiFi" }) do
    if want[name] and (turnedOn[name] or all) then out[#out + 1] = name end
  end
  return out
end

--- 시스템 항목의 접근성 식별자. MenuBarAgent 의 항목은 AXHostingView 그룹 안에 AXMenuBarItem 을 하나 두고
--- 그 AXIdentifier 가 이 값이다 (macOS 27.0 실측: battery, wifi, controlcenter, clock 확인).
--- Bartender:placeRight 에 넘긴다.
rules.MENU_EXTRA_ID = {
  Battery = "com.apple.menuextra.battery",
  WiFi = "com.apple.menuextra.wifi",
}

return rules
