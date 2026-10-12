-- =====================================================================
--  JD7810Seat.lua   v8.5  (FS25 - osobna upotreba, Darijan)
--  10. modul (nakon Hms): kabina - vidno polje kamera, opcija volana u postavkama igre, telemetrija (TEST redak F2)
--
--  v153: skripte SJEDALA uklonjene (Darijan 7.10.: visina / naprijed-natrag kamere, prekidac sjedala, konzola
--  jd7810Seat) dok se ne smisli bolje. Zracno sjedalo same igre (series7810.xml <suspensions>, "Indoor Camera
--  Suspension" u postavkama igre) nije skripta i ostaje.
--
--  TELEMETRIJA (konzola jd7810Tele on|off): 20x/s u log.txt: t, v km/h, rpm sirovo/filtr., gas, pitch, roll,
--  pomak sjedala igre (mm), sile kotaca, proklizavanje, vuca, skretanje. Za F2-F4 mjerenja.
-- =====================================================================

local JD = JD7810Transmission
local log = JD.U.log
local clamp = JD.U.clamp

JD.SEAT_VERSION = "8.5"

local SEAT_SETTINGS = {
    { key = "teleHz",       type = "float", default = 20,    xml = ".telemetry#hz",   desc = "telemetrija: uzorci u sekundi", min = 1, max = 60 },
    { key = "camFovIn",     type = "float", default = 65,    xml = ".camera#fovInside",  desc = "kamera: vidno polje (fov Y, stupnjevi) za svaku kameru u kabini", min = 20, max = 120 },
    { key = "camFovForce",  type = "bool",  default = false, xml = ".camera#forceFov",   desc = "v182: false = vidno polje i zoom prema postavkama igre (Darijan 9.10.); true = stalno fovInside/fovOutside" },
    { key = "camFovOut",    type = "float", default = 65,    xml = ".camera#fovOutside", desc = "kamera: vidno polje (fov Y, stupnjevi) za svaku vanjsku kameru", min = 20, max = 120 },
    { key = "teleAuto",     type = "bool",  default = false, xml = ".telemetry#autostart", desc = "telemetrija: sama se pali kad vozac sjedne u 7810 (bez konzole)" },
}
for _, s in ipairs(SEAT_SETTINGS) do
    table.insert(JD.SETTINGS, s)
    if JD.cfg[s.key] == nil then JD.cfg[s.key] = s.default end
end

local function isOursVehicle(vehicle)
    return vehicle ~= nil and vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor ~= nil and JD.U.isOurs(vehicle.spec_motorized.motor)
end
local function call(obj, fname, ...)
    if obj ~= nil and type(obj[fname]) == "function" then
        local ok, a, b, c, d = pcall(obj[fname], obj, ...)
        if ok then return a, b, c, d end
    end
    return nil
end

-- =====================================================================
--  A2) VOLAN (v153): GIANTS smanjuje BRZINU zakretanja tipkovnicom/gamepadom s brzinom voznje
--      (Drivable: min(1 / (brzina x speedRotScale + offset), 1)); analogni volan (G920) to nema.
--      ESC > Settings > General Settings > JOHN DEERE 7810 > "Speed-dependent steering" ON/OFF.
--      ON = vrijednosti iz series7810.xml (<drivable><speedRotScale scale="20" offset="1.0"/>), OFF = 0 / 1 (puna brzina).
--      Pamti se u modSettings/FS25_JohnDeere_7810_steering.xml (ne dira komentare u jd7810Settings.xml).
-- =====================================================================
JD.cfg.steerSpeedRed = false
JD.cfg.compassHud = true          -- v155: kompas gore na sredini (JD7810Display drawCompass)
JD.cfg.compassScale = 1.0         -- v155: velicina kompasa (0,75 / 1 / 1,25 / 1,5)
JD.cfg.compassAlpha = 0.8         -- v155: neprozirnost pozadine kompasa (0,2 - 1)
JD.cfg.headingStep = 1            -- v155: korak zakljucanog smjera (0,1 tocno / 1 / 5 / 15 / 45 st.)
JD.cfg.headingSnap = 25           -- v187 (bilo 10); v155: unutar toliko st. od osnovnog smjera (ili +180) -> tocno osnovni
local function steerFile()
    if getUserProfileAppPath == nil then return nil end
    return getUserProfileAppPath() .. "modSettings/FS25_JohnDeere_7810_steering.xml"
end
local function loadSteer()
    local f = steerFile()
    if f == nil or fileExists == nil or not fileExists(f) then return end
    local xml = loadXMLFile("jd7810Steer", f)
    if xml == nil or xml == 0 then return end
    local v = getXMLBool(xml, "jd7810Steering#speedReduction")
    if v ~= nil then JD.cfg.steerSpeedRed = v end
    local c = getXMLBool(xml, "jd7810Steering#compassHud")
    if c ~= nil then JD.cfg.compassHud = c end
    local cs = getXMLFloat(xml, "jd7810Steering#compassScale")
    if cs ~= nil then JD.cfg.compassScale = clamp(cs, 0.5, 2) end
    local ca = getXMLFloat(xml, "jd7810Steering#compassAlpha")
    if ca ~= nil then JD.cfg.compassAlpha = clamp(ca, 0, 1) end
    local hs = getXMLFloat(xml, "jd7810Steering#headingStep")
    if hs ~= nil then JD.cfg.headingStep = clamp(hs, 0.1, 90) end
    local ar = getXMLBool(xml, "jd7810Steering#ptoAutoRpm")   -- v178
    if ar ~= nil then JD.cfg.ptoAutoRpm = ar end
    local al = getXMLBool(xml, "jd7810Steering#ptoAutoLoad")  -- v179
    if al ~= nil then JD.cfg.ptoAutoLoad = al end
    local hn = getXMLFloat(xml, "jd7810Steering#headingSnap")
    if hn ~= nil then JD.cfg.headingSnap = clamp(hn, 0, 45) end
    if hn ~= nil and math.abs(hn - 10) < 0.01 then JD.cfg.headingSnap = 25 end   -- v187: stari zadani 10 -> 25
    delete(xml)
end
local function saveSteer()
    local f = steerFile()
    if f == nil then return end
    if createFolder ~= nil then pcall(createFolder, getUserProfileAppPath() .. "modSettings") end
    local xml = createXMLFile("jd7810Steer", f, "jd7810Steering")
    if xml == nil or xml == 0 then return end
    setXMLBool(xml, "jd7810Steering#speedReduction", JD.cfg.steerSpeedRed == true)
    setXMLBool(xml, "jd7810Steering#compassHud", JD.cfg.compassHud ~= false)
    setXMLFloat(xml, "jd7810Steering#compassScale", JD.cfg.compassScale or 1)
    setXMLFloat(xml, "jd7810Steering#compassAlpha", JD.cfg.compassAlpha or 0.8)
    setXMLFloat(xml, "jd7810Steering#headingStep", JD.cfg.headingStep or 1)
    setXMLFloat(xml, "jd7810Steering#headingSnap", JD.cfg.headingSnap or 25)
    setXMLBool(xml, "jd7810Steering#ptoAutoRpm", JD.cfg.ptoAutoRpm ~= false)
    setXMLBool(xml, "jd7810Steering#ptoAutoLoad", JD.cfg.ptoAutoLoad == true)
    saveXMLFile(xml)
    delete(xml)
end
JD.saveSteer = saveSteer   -- v155: i GreenStar stranica HDG sprema iste postavke
-- svaki frame iz updateSeatAndTele; radi samo kad se postavka promijeni
function JD.updateSteer(vehicle)
    local spec = vehicle.spec_drivable
    if spec == nil then return end
    if vehicle.jd7810SteerXml == nil then
        vehicle.jd7810SteerXml = { spec.speedRotScale or 80, spec.speedRotScaleOffset or 0.7 }
    end
    local on = JD.cfg.steerSpeedRed == true
    if vehicle.jd7810SteerOn == on then return end
    vehicle.jd7810SteerOn = on
    if on then
        spec.speedRotScale, spec.speedRotScaleOffset = vehicle.jd7810SteerXml[1], vehicle.jd7810SteerXml[2]
    else
        spec.speedRotScale, spec.speedRotScaleOffset = 0, 1
    end
    log(string.format("volan: smanjenje brzine zakretanja s brzinom %s (scale %.1f, offset %.2f)", on and "ON" or "OFF", spec.speedRotScale, spec.speedRotScaleOffset))
end

-- =====================================================================
--  B) IZBORNIK: ESC > Settings > General Settings - vlastiti odjeljak "JOHN DEERE 7810" (isti postupak kao
--     Interactive Control: kloniranje reda multiCameraSensitivity / checkActiveSuspensionCamera i zaglavlja sectionHeader)
-- =====================================================================
local MENU = { title = 'JOHN DEERE 7810 "THE LEGEND"', created = false, rows = {
    { key = "steerSpeedRed", binary = false, label = "Speed-dependent steering", tip = "Keyboard/gamepad steering gets slower at higher speed. OFF = full steering speed (wheel not affected)", texts = { "OFF", "ON" },
      get = function() return JD.cfg.steerSpeedRed == true and 2 or 1 end, set = function(i) JD.cfg.steerSpeedRed = (i == 2) end, save = saveSteer },
    { key = "ptoAutoRpm", binary = false, label = "Automatic PTO rpm", tip = "Lowering a PTO implement raises engine rpm, raising it drops to idle. Rated = always rated PTO rpm (2100). Load-based = less rpm for light implements (down to 85 %), rated for heavy ones. OFF = hand throttle only (LAlt+A / S) like the real 7810. Hand throttle always overrides", texts = { "OFF", "Rated", "Load-based" },
      get = function() if JD.cfg.ptoAutoRpm == false then return 1 end return JD.cfg.ptoAutoLoad == true and 3 or 2 end,
      set = function(i) JD.cfg.ptoAutoRpm = (i >= 2); JD.cfg.ptoAutoLoad = (i == 3) end, save = saveSteer },
    { key = "compassHud", binary = false, label = "Compass HUD", tip = "Compass tape at the top of the screen with heading lock (LAlt+F) marker", texts = { "OFF", "ON" },
      get = function() return JD.cfg.compassHud ~= false and 2 or 1 end, set = function(i) JD.cfg.compassHud = (i == 2) end, save = saveSteer },
    { key = "headingStep", binary = false, label = "Heading resolution", tip = "Heading lock (LAlt+F) rounds the heading: Exact = as you drive (0.1), or coarse steps 1 / 5 / 15 / 45 deg", texts = { "Exact", "1 deg", "5 deg", "15 deg", "45 deg" },
      get = function()
          local v, best, bd = JD.cfg.headingStep or 1, 2, math.huge
          for i, f in ipairs({ 0.1, 1, 5, 15, 45 }) do if math.abs(f - v) < bd then best, bd = i, math.abs(f - v) end end
          return best
      end, set = function(i) JD.cfg.headingStep = ({ 0.1, 1, 5, 15, 45 })[i] or 1 end, save = saveSteer },
    { key = "compassScale", binary = false, label = "Compass size", tip = "Size of the compass tape", texts = { "75 %", "100 %", "125 %", "150 %" },
      get = function()
          local v, best, bd = JD.cfg.compassScale or 1, 2, math.huge
          for i, f in ipairs({ 0.75, 1.0, 1.25, 1.5 }) do if math.abs(f - v) < bd then best, bd = i, math.abs(f - v) end end
          return best
      end, set = function(i) JD.cfg.compassScale = ({ 0.75, 1.0, 1.25, 1.5 })[i] or 1 end, save = saveSteer },
    { key = "compassAlpha", binary = false, label = "Compass background", tip = "Opacity of the compass background (lower = more transparent)", texts = { "20 %", "40 %", "60 %", "80 %", "100 %" },
      get = function() return clamp(math.floor((JD.cfg.compassAlpha or 0.8) * 5 + 0.5), 1, 5) end, set = function(i) JD.cfg.compassAlpha = i / 5 end, save = saveSteer },
} }
function MENU:onRowBinary(state, element)
    for _, r in ipairs(MENU.rows) do
        if r.el == element then r.set(element:getIsChecked()); if JD.saveSettings ~= nil then pcall(JD.saveSettings) end end
    end
end
function MENU:onRowMulti(state, element)
    for _, r in ipairs(MENU.rows) do
        if r.el == element then
            r.set(state)
            if r.save ~= nil then pcall(r.save) elseif JD.saveSettings ~= nil then pcall(JD.saveSettings) end
        end
    end
end
local function menuInit(frame)
    if MENU.created then return end
    local layout = frame.generalSettingsLayout
    if layout == nil then log("izbornik: generalSettingsLayout nije pronadjen"); MENU.created = true; return end
    local headerRef = nil
    for _, e in ipairs(layout.elements) do
        if e.name == "sectionHeader" then headerRef = e; break end
    end
    if headerRef ~= nil then
        local h = headerRef:clone()
        h.id = "jd7810Header"; h:setText(MENU.title); layout:addElement(h)
    end
    local n = 0
    for _, r in ipairs(MENU.rows) do
        local ref = r.binary and frame.checkActiveSuspensionCamera or frame.multiCameraSensitivity
        if ref ~= nil and ref.parent ~= nil then
            local box = ref.parent:clone()
            box.id = "jd7810_" .. r.key .. "Box"
            local el, title = box.elements[1], box.elements[2]
            local tip = el.elements[1]
            if title ~= nil and title.setText ~= nil then title:setText(r.label) end
            if tip ~= nil and tip.setText ~= nil then tip:setText(r.tip) end
            el.id = "jd7810_" .. r.key
            el.target = MENU
            el:setCallback("onClickCallback", r.binary and "onRowBinary" or "onRowMulti")
            el:setDisabled(false)
            if r.binary then el:setIsChecked(r.get()) else el:setTexts(r.texts); el:setState(r.get(), false) end
            box:reloadFocusHandling(true)
            layout:addElement(box)
            r.el = el; n = n + 1
        end
    end
    layout:invalidateLayout()
    MENU.created = true
    log(string.format("izbornik: odjeljak '%s' dodan u General Settings (%d redova)", MENU.title, n))
end
local function menuUpdate(frame)
    for _, r in ipairs(MENU.rows) do
        if r.el ~= nil then
            if r.binary then pcall(r.el.setIsChecked, r.el, r.get()) else pcall(r.el.setState, r.el, r.get()) end
        end
    end
end
if InGameMenuSettingsFrame ~= nil and InGameMenuSettingsFrame.onFrameOpen ~= nil then
    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function(self, element)
        local ok, err = pcall(menuInit, self)
        if not ok then log("izbornik: greska " .. tostring(err)) end
    end)
    if InGameMenuSettingsFrame.updateGeneralSettings ~= nil then
        InGameMenuSettingsFrame.updateGeneralSettings = Utils.appendedFunction(InGameMenuSettingsFrame.updateGeneralSettings, function(self) pcall(menuUpdate, self) end)
    end
else
    log("izbornik: InGameMenuSettingsFrame nije pronadjen - opcija volana nije u izborniku")
end

-- =====================================================================
--  C) TELEMETRIJA (F2): jd7810Tele on|off -> log.txt, CSV redak "TELE;..."
-- =====================================================================
JD.tele = { on = false, t = 0, acc = 0 }
local TELE_HEADER = "TELE;t_s;v_kmh;rpm_raw;rpm_filt;gas;pitch_deg;roll_deg;aSeat_g;xSeat_mm;L_FL_t;L_FR_t;L_RL_t;L_RR_t;slipL_FL;slipL_FR;slipL_RL;slipL_RR;slipLat_F;slipLat_R;draft_kN;yaw_dps;aLat_g;steer;fric_FL"
-- opterecenje i proklizavanje kotaca preko sluzbenog API-ja igre (WheelPhysics:getTireLoad u t, getWheelShapeSlip)
local function wheelData(vehicle)
    local load, slipL, slipT = {}, {}, {}
    local spec = vehicle.spec_wheels
    if spec == nil or spec.wheels == nil then return load, slipL, slipT end
    for i, w in ipairs(spec.wheels) do
        local ph = w.physics
        if ph ~= nil then
            if type(ph.getTireLoad) == "function" then
                local ok, v = pcall(ph.getTireLoad, ph)
                if ok and v ~= nil then load[i] = v end
            end
            if getWheelShapeSlip ~= nil and w.node ~= nil and ph.wheelShape ~= nil and ph.wheelShapeCreated then
                local ok, lo, la = pcall(getWheelShapeSlip, w.node, ph.wheelShape)
                if ok then slipL[i] = lo; slipT[i] = la end
            end
        end
    end
    return load, slipL, slipT
end
-- jednom na pocetku: mase, tezista, kotaci (za F3 / F4)
local function teleStatic(vehicle)
    for i, c in ipairs(vehicle.components or {}) do
        local n = c.node
        if n ~= nil and n ~= 0 then
            local m = getMass ~= nil and getMass(n) or 0
            local cx, cy, cz = 0, 0, 0
            if getCenterOfMass ~= nil then cx, cy, cz = getCenterOfMass(n) end
            log(string.format("TELESTAT;component;%d;mass_t;%.3f;com;%.3f;%.3f;%.3f;solverIt;%s", i, m, cx, cy, cz, tostring(c.solverIterationCount)))
        end
    end
    local spec = vehicle.spec_wheels
    for i, w in ipairs(spec ~= nil and spec.wheels or {}) do
        local ph = w.physics or {}
        local wx, wy, wz = 0, 0, 0
        if w.repr ~= nil then wx, wy, wz = localToLocal(w.repr, vehicle.rootNode, 0, 0, 0) end
        log(string.format("TELESTAT;wheel;%d;r;%.3f;w;%.3f;restLoad;%.2f;frictionScale;%.2f;maxLong;%.2f;maxLat;%.2f;maxLatLoad;%.2f;tireType;%s;pos;%.3f;%.3f;%.3f",
            i, ph.radius or 0, ph.width or 0, ph.restLoad or 0, ph.frictionScale or 0, ph.maxLongStiffness or 0, ph.maxLatStiffness or 0, ph.maxLatStiffnessLoad or 0, tostring(ph.tireType), wx, wy, wz))
    end
end
local function teleStart(vehicle)
    local T = JD.tele
    T.on = true; T.t = 0; T.acc = 0; T.lp = nil; T.lv = nil; T.seat0 = nil
    log(TELE_HEADER)
    if vehicle ~= nil then pcall(teleStatic, vehicle) end
end
local function avg(a, b) if a ~= nil and b ~= nil then return (a + b) * 0.5 end return a or b end
local function f2(v, fmt) return v ~= nil and string.format(fmt or "%.2f", v) or "-" end
function JD7810Transmission.updateTelemetry(vehicle, dt)
    local T = JD.tele
    if not T.on and JD.cfg.teleAuto and not T.autoDone and g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil and g_localPlayer:getCurrentVehicle() == vehicle then
        T.autoDone = true
        teleStart(vehicle)
        log("telemetrija: autostart (jd7810Settings telemetry#autostart)")
    end
    if not T.on then return end
    T.acc = T.acc + dt
    local period = 1000 / (JD.cfg.teleHz or 20)
    if T.acc < period then return end
    T.acc = T.acc - period
    T.t = T.t + period
    local motor = vehicle.spec_motorized.motor
    local v = JD.U.getSpeedKmh(motor) or 0
    local rpmRaw = call(motor, "getLastRealMotorRpm") or 0
    local rpmF = (JD.U.engineRpm ~= nil and JD.U.engineRpm(motor)) or (motor.jd7810Rpm or rpmRaw)
    local gas = vehicle.lastAcceleratorPedal or motor.lastAcceleratorPedal or 0
    local fx, fy, fz = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
    local sx, sy, sz = localDirectionToWorld(vehicle.rootNode, 1, 0, 0)
    local pitch = math.deg(math.asin(clamp(fy, -1, 1)))
    local roll = math.deg(math.asin(clamp(sy, -1, 1)))
    -- okomito ubrzanje u tocki kamere (konacne razlike) i pomak sjedala igre (Suspensions cvor 1)
    local aSeat, xSeat = 0, 0
    local cn = nil   -- v153: kamera sjedala uklonjena (aSeat = 0); pomak sjedala igre ostaje (xSeat)
    if cn ~= nil then
        local px, py, pz = getWorldTranslation(cn)
        local dts = period / 1000
        if T.lp ~= nil then
            local vy = (py - T.lp[2]) / dts
            if T.lv ~= nil then
                local ux, uy, uz = localDirectionToWorld(vehicle.rootNode, 0, 1, 0)
                local vx, vz = (px - T.lp[1]) / dts, (pz - T.lp[3]) / dts
                aSeat = ((vx - T.lv[1]) * ux + (vy - T.lv[2]) * uy + (vz - T.lv[3]) * uz) / dts / 9.81
            end
            T.lv = { (px - T.lp[1]) / dts, vy, (pz - T.lp[3]) / dts }
        end
        T.lp = { px, py, pz }
    end
    local ss = vehicle.spec_suspensions
    local list = ss ~= nil and ss.suspensionNodes or nil
    local sn = list ~= nil and list[1] or nil
    if sn ~= nil and sn.node ~= nil then
        local okT, _, ty = pcall(getTranslation, sn.node)
        if okT and ty ~= nil then
            T.seat0 = T.seat0 or ty
            xSeat = (ty - T.seat0) * 1000
        end
    end
    local L, sL, sT = wheelData(vehicle)
    local draft = motor.jd7810DraftKN or 0
    -- skretanje: kutna brzina oko okomite osi i bocno ubrzanje a = v * omega (za prag prevrtanja)
    local yaw, aLat = 0, 0
    local cnode = vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node or vehicle.rootNode
    if getAngularVelocity ~= nil and getLinearVelocity ~= nil and cnode ~= nil then
        local _, wy, _ = getAngularVelocity(cnode)
        local lvx, _, lvz = getLinearVelocity(cnode)
        local vh = math.sqrt(lvx * lvx + lvz * lvz)
        yaw = math.deg(wy or 0)
        aLat = vh * (wy or 0) / 9.81
    end
    local fric = 0
    local sw = vehicle.spec_wheels
    if sw ~= nil and sw.wheels ~= nil and sw.wheels[1] ~= nil and sw.wheels[1].physics ~= nil then fric = sw.wheels[1].physics.frictionScale or 0 end
    local steer = 0
    if vehicle.rotatedTime ~= nil then
        if vehicle.rotatedTime > 0 and (vehicle.maxRotTime or 0) ~= 0 then steer = vehicle.rotatedTime / vehicle.maxRotTime
        elseif vehicle.rotatedTime < 0 and (vehicle.minRotTime or 0) ~= 0 then steer = -vehicle.rotatedTime / vehicle.minRotTime end
    end
    log(string.format("TELE;%.2f;%.1f;%.0f;%.0f;%.2f;%.2f;%.2f;%.3f;%.1f;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%.1f;%.1f;%.3f;%.2f;%.2f",
        T.t / 1000, v, rpmRaw, rpmF, gas, pitch, roll, aSeat, xSeat,
        f2(L[1]), f2(L[2]), f2(L[3]), f2(L[4]),
        f2(sL[1], "%.3f"), f2(sL[2], "%.3f"), f2(sL[3], "%.3f"), f2(sL[4], "%.3f"),
        f2(avg(sT[1], sT[2]), "%.3f"), f2(avg(sT[3], sT[4]), "%.3f"), draft, yaw, aLat, steer, fric))
end
function JD7810Transmission:consoleTele(a)
    if a == "on" then
        local v = g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil and g_localPlayer:getCurrentVehicle() or nil
        teleStart(v)
    elseif a == "off" then JD.tele.on = false end
    return "telemetry " .. (JD.tele.on and "ON" or "OFF") .. string.format(" (%.0f Hz, log.txt redci TELE;)", JD.cfg.teleHz or 20)
end
table.insert(JD.COMMANDS, { "jd7810Tele", "telemetrija u log.txt: on | off", "consoleTele", "[on|off]" })

-- =====================================================================
--  A2) VIDNO POLJE: svaka kamera vozila dobiva fov iz jd7810Settings.xml <camera fovInside fovOutside>.
--      VehicleCamera cuva defaultFovY/fovY; postavka igre (FOV) ih preracuna -> ovdje se ponovno postavi.
-- =====================================================================
function JD7810Transmission.updateCameraFov(vehicle)
    if not vehicle.isClient then return end
    -- v187: zadani fov (65) postavi se JEDNOM po kameri; zoom i dalje radi. camera#forceFov = stalno drzi.
    local spec = vehicle.spec_enterable
    if spec == nil or spec.cameras == nil then return end
    local fin, fout = math.rad(JD.cfg.camFovIn or 45), math.rad(JD.cfg.camFovOut or 45)
    for _, c in ipairs(spec.cameras) do
        local want = c.isInside and fin or fout
        local need = JD.cfg.camFovForce and (c.fovY == nil or math.abs(c.fovY - want) > 1e-4) or (not JD.cfg.camFovForce and c.jd7810FovSet ~= want)
        if c.cameraNode ~= nil and not c.lodDebugMode and need then
            c.jd7810FovSet = want
            c.defaultFovY = want
            c.fovY = want
            setFovY(c.cameraNode, want)
            if not vehicle.jd7810FovLog then
                vehicle.jd7810FovLog = true
                log(string.format("kamere: fov unutra %.0f, vani %.0f (stupnjeva)", JD.cfg.camFovIn or 45, JD.cfg.camFovOut or 45))
            end
        end
    end
end

-- =====================================================================
--  D) petlja: iz Engine update (kao HMS) - volan, vidno polje, telemetrija
-- =====================================================================
function JD7810Transmission.updateSeatAndTele(motor, dt)
    local vehicle = motor.vehicle
    if vehicle == nil then return end
    local ok4, err4 = pcall(JD.updateSteer, vehicle)
    if not ok4 and not vehicle.jd7810SteerErr then vehicle.jd7810SteerErr = true; log("volan: greska " .. tostring(err4)) end
    local ok3, err3 = pcall(JD.updateCameraFov, vehicle)
    if not ok3 and not vehicle.jd7810FovErr then vehicle.jd7810FovErr = true; log("kamere fov: greska " .. tostring(err3)) end
    local ok2, err2 = pcall(JD.updateTelemetry, vehicle, dt)
    if not ok2 and not vehicle.jd7810TeleErr then vehicle.jd7810TeleErr = true; log("telemetrija: greska " .. tostring(err2)) end
end

pcall(JD.loadSettings)
pcall(loadSteer)
log("Seat modul v" .. JD.SEAT_VERSION .. " ucitan")
