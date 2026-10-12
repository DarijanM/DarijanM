-- =====================================================================
--  JD7810Display.lua   v8.1  (FS25 - osobna upotreba, Darijan)
--  prikazi: kazaljka tlaka turbopunjaca; ucitavanje postavki
--  v8.5: uklonjen vlastiti HUD (instrument uz brzinomjer, ispis rucnog gasa, jd7810Hud) - Darijan 4.10.2026
--  v8.1: podjela JD7810Transmission.lua v8.0 na module - kod premjesten
--        bez promjene ponasanja. Redoslijed ucitavanja u modDesc.xml:
--        Core, Transmission, Engine, PTO, Display, PerformanceMonitor, AgroGsm, Cockpit
-- =====================================================================

local JD = JD7810Transmission
local clamp = JD.U.clamp
local gearText = JD.U.gearText
local getAccelerationMS2 = JD.U.getAccelerationMS2
local getOurCurrentMotor = JD.U.getOurCurrentMotor
local getShiftPoints = JD.U.getShiftPoints
local getSpeedKmh = JD.U.getSpeedKmh
local getSpeedLimitKmh = JD.U.getSpeedLimitKmh
local log = JD.U.log

-- =====================================================================
--  O) AGRO GSM: sat i datum na 7-seg zaslonu, STVARNO vrijeme s racunala.
--     Sat HH:MM (dvotocka trepce 1 Hz), datum DD.MM.YY. Pozadinsko svjetlo
--     zaslona: dashboard EMITTER "gsmLCD" u series7810.xml (sa svjetlima).
-- =====================================================================

-- ---------------------------------------------------------------------
JD7810Transmission.loadSettings()
log("v" .. JD7810Transmission.VERSION .. " ucitano (" .. tostring(JD7810Transmission.MOD_NAME) .. ")")


-- =====================================================================
--  Q) TLAK TURBOPUNJACA (BOOST, -1..2 bar) na desnom stupu - kazaljka "needleBoost".
--     Brojcanik: 0 bar = 9 sati, 1 = 12, 2 = 3 sata -> 90 st. po baru, u smjeru kazaljke.
--     Tlak ovisi o opterecenju i okretajima motora, s kasnjenjem turbine (turbo lag).
--     Motor ugasen -> 0 bar.  Pozadinsko svjetlo: dashboard EMITTER "needleBoostPart".
-- =====================================================================
local BOOST_MAX_BAR   = 1.35   -- 8,1 L, 175 KS: puni teret pri nazivnim okretajima
local BOOST_RISE_S    = 0.7    -- vremenska konstanta porasta (s)
local BOOST_FALL_S    = 1.3    -- vremenska konstanta pada (s)

local function boostNode(vehicle)
    if vehicle.jd7810BoostNode == nil then
        local ok, n = pcall(I3DUtil.indexToObject, vehicle.components, "needleBoost", vehicle.i3dMappings)
        vehicle.jd7810BoostNode = (ok and n ~= nil and n ~= 0) and n or false
        if not vehicle.jd7810BoostNode then log("JD7810: nema cvora needleBoost (i3dMapping)") end
    end
    return vehicle.jd7810BoostNode or nil
end

function JD7810Transmission.updateBoostGauge(motor, dt)
    local vehicle = motor.vehicle
    if vehicle == nil then return end
    local node = boostNode(vehicle)
    if node == nil then return end
    local started = vehicle.getIsMotorStarted ~= nil and vehicle:getIsMotorStarted()
    local target = 0
    if started then
        local rpm  = JD.U.engineRpm(motor)
        local idle = motor.minRpm or 850
        local maxr = motor.maxRpm or 2200
        local rf   = clamp((rpm - idle) / math.max(1, maxr - idle), 0, 1)
        local load = clamp(motor:getSmoothLoadPercentage() or 0, 0, 1)
        target = BOOST_MAX_BAR * (load ^ 1.25) * (0.35 + 0.65 * rf) + 0.08 * rf
    end
    local cur = motor.jd7810Turbo or 0
    local tau = (target > cur) and BOOST_RISE_S or BOOST_FALL_S
    cur = cur + (target - cur) * (1 - math.exp(-(dt / 1000) / tau))
    motor.jd7810Turbo = clamp(cur, -0.05, 1.95)
    setRotation(node, 0, 0, -(math.pi / 2) * motor.jd7810Turbo)
end


-- =====================================================================
--  R) SREDNJI LCD analogne ploce (OMAR172276 "Analog Instrument Panel" G,
--     "Changing Display Functions"): font igre DIGIT (g_materialManager / CharacterLine)
--     red B (gore, 16 mm): A okretaji motora | B PTO straga -> sprijeda | C proklizavanje % |
--                          D stvarna brzina -> izracunata brzina (s kotaca)
--     red D (12 mm): stupanj - PS "12", AQ "C3", IVT traka "1"/"2"; uz njega N / R (8 mm)
--     sati rada (red E) ostaju postojeca XML ploca numbersOperatingTime (uvijek vidljivi)
--     polozaji u metrima u odnosu na cvor numbersRPM (X desno, Y gore, Z prema vozacu)
-- =====================================================================
JD7810Transmission.LCD = {
    B  = { size = 0.016, x = 0.0018,  y = -0.0052, chars = 5 },
    D  = { size = 0.012, x = -0.0172, y = -0.0312, chars = 2 },
    DR = { size = 0.008, x = -0.0052, y = -0.0272, chars = 1 },
}
JD7810Transmission.LCD_MODE_NAMES = { RPM = "engine rpm", PTO_R = "rear PTO", PTO_F = "front PTO",
    SLIP = "wheel slip %", SPEED = "true speed km/h", SPEED_CALC = "calculated speed km/h" }
local LCD_AQ = { "A", "B", "C", "D", "E" }

local function lcdNodes(vehicle)
    if vehicle.jd7810Lcd ~= nil then return vehicle.jd7810Lcd end
    local L = { ok = false, mode = "RPM" }
    vehicle.jd7810Lcd = L
    local ok, base = pcall(I3DUtil.indexToObject, vehicle.components, "numbersRPM", vehicle.i3dMappings)
    if not ok or base == nil or base == 0 then return L end
    local font = (g_materialManager ~= nil and g_materialManager.getFontMaterial ~= nil) and g_materialManager:getFontMaterial("DIGIT", JD7810Transmission.MOD_NAME) or nil
    if font == nil or CharacterLine == nil then
        log("LCD: font DIGIT nije dostupan - srednji LCD ostaje bez dodataka")
        return L
    end
    local function line(spec)
        local tg = createTransformGroup("jd7810Lcd")
        link(base, tg)
        setTranslation(tg, spec.x, spec.y, 0.0002)
        local cl = CharacterLine.new(tg, font, spec.chars)
        cl:setSizeAndScale(spec.size, 1, 1)
        cl:setTextAlignment(RenderText.ALIGN_RIGHT)
        cl:setColor({ 0, 0, 0, 1 }, nil, 0, 0)
        cl:setText("")
        return { node = tg, cl = cl, text = "" }
    end
    L.B, L.D, L.DR = line(JD7810Transmission.LCD.B), line(JD7810Transmission.LCD.D), line(JD7810Transmission.LCD.DR)
    L.ok = true
    return L
end

-- ---------------------------------------------------------------------
--  Font igre umjesto 7-segmentnih znamenki (Performance Monitor, Agro GSM)
--  Za svaku znamenku se iz segmenata (a gore, d dolje, b/c desno, e/f lijevo)
--  izmjeri sredina, visina i ravnina (getShapeWorldBoundingSphere), na isto mjesto
--  stavi CharacterLine s 1 znakom (DIGIT), a segmenti se sakriju. Tocke i dvotocke
--  ostaju postojeci segmenti. Ako ista ne uspije, ostaju segmenti.
-- ---------------------------------------------------------------------
local function segCenter(n, parent)
    if n == nil then return nil end
    local ok, x, y, z = pcall(getShapeWorldBoundingSphere, n)
    if not ok or x == nil then return nil end
    return { worldToLocal(parent, x, y, z) }
end
local function sub3(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function mid3(a, b) return { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2, (a[3] + b[3]) / 2 } end
local function len3(a) return math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3]) end
local function cross3(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end

local function fontCfg(F)
    local cfg = JD7810Transmission.cfg
    local sc = (cfg.segFontScale or 1.0) * (F.gsm and (cfg.segFontScaleGsm or 0.85) or 1)
    return sc, cfg.segFontScaleX or 0.75, cfg.segFontYOff or 0
end
local FONT_LIFT = 0.001   -- v186: znak 1 mm ispred podloge (0,1 mm = z-fighting -> titranje PM-a)
local function placeFont(F)
    local sc, sx, yOff = fontCfg(F)
    local h = F.H * sc
    local c, u, nrm = F.c, F.u, F.n
    -- znak okomito centriran na sredinu znamenke (VERTICAL_ALIGN_MIDDLE), yOff = dodatni pomak u udjelu visine
    setTranslation(F.tg, c[1] + u[1] * h * yOff + nrm[1] * FONT_LIFT, c[2] + u[2] * h * yOff + nrm[2] * FONT_LIFT, c[3] + u[3] * h * yOff + nrm[3] * FONT_LIFT)
    F.cl:setSizeAndScale(h, sx, 1)
    F.cl:setText(F.ch or "")                                   -- velicina se primjenjuje pri setText
    F.key = string.format("%.3f/%.3f/%.3f", sc, sx, yOff)
end

local fontLogged = {}
function JD7810Transmission.U.fontDigits(list, tag)
    if list == nil or #list == 0 or CharacterLine == nil or g_materialManager == nil or g_materialManager.getFontMaterial == nil then return false end
    if JD7810Transmission.cfg.segFont == false then return false end
    local font = g_materialManager:getFontMaterial("DIGIT", JD7810Transmission.MOD_NAME)
    if font == nil then return false end
    local made = {}
    for i, dg in ipairs(list) do
        local parent = dg.a ~= nil and getParent(dg.a) or nil
        if parent == nil or parent == 0 then return false end
        local a, d = segCenter(dg.a, parent), segCenter(dg.d, parent)
        local b, cc, e, f = segCenter(dg.b, parent), segCenter(dg.c, parent), segCenter(dg.e, parent), segCenter(dg.f, parent)
        if a == nil or d == nil or b == nil or cc == nil or e == nil or f == nil then return false end
        local up = sub3(a, d); local H = len3(up)
        local right = sub3(mid3(b, cc), mid3(e, f)); local W = len3(right)
        if H < 0.0005 or W < 0.0002 then return false end
        local u = { up[1] / H, up[2] / H, up[3] / H }
        local r = { right[1] / W, right[2] / W, right[3] / W }
        local nrm = cross3(r, u)
        local tg = createTransformGroup("jd7810SegFont")
        link(parent, tg)
        setDirection(tg, nrm[1], nrm[2], nrm[3], u[1], u[2], u[3])
        local cl = CharacterLine.new(tg, font, 1)
        cl:setTextAlignment(RenderText.ALIGN_CENTER)
        if cl.setTextVerticalAlignment ~= nil and RenderText.VERTICAL_ALIGN_MIDDLE ~= nil then
            cl:setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
        end
        cl:setColor({ 0, 0, 0, 1 }, nil, 0, 0)
        cl:setText("")
        local F = { tg = tg, cl = cl, ch = "", c = mid3(a, d), u = u, n = nrm, H = H, W = W, gsm = string.sub(tag, 1, 3) == "GSM" }
        placeFont(F)
        made[i] = F
        if not fontLogged[tag] and i == 1 then
            fontLogged[tag] = true
            log(string.format("font znamenke %s: visina %.1f mm, sirina %.1f mm, %d znamenki", tag, H * 1000, W * 1000, #list))
        end
    end
    for i, dg in ipairs(list) do
        dg.font = made[i]
        for _, sg in ipairs({ "a", "b", "c", "d", "e", "f", "g" }) do
            if dg[sg] ~= nil then setVisibility(dg[sg], false) end
        end
    end
    return true
end

-- postavi znak u znamenku s fontom (true) ili vrati false (znamenka nema font)
function JD7810Transmission.U.fontDigitSet(dg, ch)
    local F = dg.font
    if F == nil then return false end
    local sc, sx, yOff = fontCfg(F)
    if F.key ~= string.format("%.3f/%.3f/%.3f", sc, sx, yOff) then placeFont(F) end   -- jd7810Reload
    if ch == " " then ch = "" end
    if F.ch ~= ch then F.ch = ch; F.cl:setText(ch) end
    return true
end

local function lcdSet(row, text)
    if row.text ~= text then row.text = text; row.cl:setText(text) end
end

function JD7810Transmission.updateCenterLcd(motor, dt)
    local vehicle = motor.vehicle
    if vehicle == nil then return end
    local L = lcdNodes(vehicle)
    if not L.ok then return end
    local on = vehicle.getIsMotorStarted ~= nil and vehicle:getIsMotorStarted() == true
    if on ~= L.on then
        L.on = on
        for _, k in ipairs({ "B", "D", "DR" }) do setVisibility(L[k].node, on) end
    end
    if not on then return end
    L.t = (L.t or 0) - dt
    if L.t > 0 then return end
    L.t = 100
    -- red B
    local m, s = L.mode, ""
    if m == "RPM" then
        -- v131: digitalni tahometar osvjezava 4x u sekundi, mijenja broj tek kad se okretaji pomaknu >= 15 o/min
        local now = g_time or 0
        local r = JD.U.engineRpm(motor)
        if motor.jd7810RpmShown == nil or (now - (motor.jd7810RpmShownT or 0) >= 250 and math.abs(r - motor.jd7810RpmShown) >= 15) then
            motor.jd7810RpmShown = math.floor(r / 10 + 0.5) * 10
            motor.jd7810RpmShownT = now
        end
        s = string.format("%d", motor.jd7810RpmShown)
    elseif m == "PTO_R" then
        s = string.format("%d", math.floor((motor.jd7810PtoRpm or 0) + 0.5))
    elseif m == "PTO_F" then
        s = string.format("%d", math.floor((motor.jd7810PtoFrontRpm or 0) + 0.5))
    elseif m == "SLIP" then
        local P = vehicle.jd7810PM
        s = string.format("%.1f", (P ~= nil and P.slip) or 0)
    elseif m == "SPEED" or m == "SPEED_CALC" then
        local v = getSpeedKmh(motor)
        if m == "SPEED_CALC" then
            local P = vehicle.jd7810PM
            local slip = (P ~= nil and P.slip) or 0
            v = v / math.max(0.01, 1 - slip / 100)
        end
        s = string.format("%.1f", v)
    end
    lcdSet(L.B, s)
    -- red D: stupanj + smjer
    local gear, dir = "", ""
    local g = motor.gear or 0
    local back = (motor.currentDirection or 1) < 0
    if JD7810Transmission.isIVT(motor) then
        local S = JD7810Transmission.ivtSet or {}
        gear = ((S.auto or 0) > 0.5 and "A" or "") .. ((S.band == 2) and "2" or "1")   -- v172: A1 / A2 u AUTO
        if getSpeedKmh(motor) < 0.3 and (motor.lastAcceleratorPedal or 0) == 0 then dir = "N" elseif back then dir = "R" end
    elseif g == 0 or (JD7810Transmission.isPowershift ~= nil and JD7810Transmission.isPowershift(motor)
            and JD7810Transmission.isStandingNeutral ~= nil and JD7810Transmission.isStandingNeutral(motor)) then
        dir = "N"                                                    -- PS stoji u automatici: rucica u N
    else
        local st = motor.activeGearGroupIndex or 1
        if JD7810Transmission.isAutoQuad ~= nil and JD7810Transmission.isAutoQuad(motor) then
            gear = (LCD_AQ[math.abs(g)] or "") .. tostring(st)                     -- raspon (brzina igre) + stupanj (grupa)
        else
            gear = tostring(back and math.min(st, 7) or st)                        -- PS: stupanj = grupa (natrag R1-R7)
        end
        if back then dir = "R" end
    end
    lcdSet(L.D, gear)
    lcdSet(L.DR, dir)
end

-- tipke na dodir lijevo od instrumenata (A/B/C/D)
function JD7810Transmission.actionLcd(vehicle, actionName, inputValue, callbackState, isAnalog)
    local L = lcdNodes(vehicle)
    if not L.ok then return end
    local k = callbackState
    if k == 1 then L.mode = "RPM"
    elseif k == 2 then L.mode = (L.mode == "PTO_R") and "PTO_F" or "PTO_R"
    elseif k == 3 then L.mode = "SLIP"
    elseif k == 4 then L.mode = (L.mode == "SPEED") and "SPEED_CALC" or "SPEED" end
    L.t = 0
    if JD7810Transmission.pmBeep ~= nil then pcall(JD7810Transmission.pmBeep) end
end

-- =====================================================================
--  H) HUD UPUTA (Darijan 5.10.2026): plocica lijevo na sredini, stil John Deere
--     (zeleno + zuto). Svaka tipka moda u jednom redu: tipka | funkcija | stanje;
--     zeleno kad je ukljuceno. Samo upute i stanja (bez instrumenata).
--     LCtrl + Num 0 = prikazi / sakrij. Crta se samo dok si u nasem 7810.
--     Igra: createImageOverlay / setOverlayColor / renderOverlay / renderText (kao FS25 HUD).
-- =====================================================================
JD7810Transmission.hudOn = true
local HUD = { white = nil }

local C = {                       -- linearne boje (FS HUD)
    bg       = { 0.004, 0.022, 0.006, 0.86 },
    stripe   = { 1.0, 0.73, 0.0, 1 },        -- JD zuta
    header   = { 1.0, 0.73, 0.0, 0.97 },
    headTxt  = { 0.006, 0.05, 0.008, 1 },    -- tamno JD zelena
    green    = { 0.037, 0.202, 0.024, 1 },   -- JD zelena
    rowAlt   = { 0.010, 0.045, 0.012, 0.55 },
    key      = { 0.0, 0.0, 0.0, 0.85 },
    keyTxt   = { 1.0, 0.80, 0.10, 1 },
    label    = { 0.85, 0.88, 0.85, 1 },
    on       = { 0.16, 0.80, 0.05, 1 },      -- svijetlo zeleno (ukljuceno)
    onBg     = { 0.04, 0.30, 0.02, 0.95 },
    off      = { 0.32, 0.34, 0.32, 1 },
    info     = { 1.0, 0.80, 0.10, 1 },
}

local function rect(x, y, w, h, c)
    if HUD.white == nil then return end
    setOverlayColor(HUD.white, c[1], c[2], c[3], c[4])
    renderOverlay(HUD.white, x, y, w, h)
end
local function text(x, y, size, s, c, align, bold)
    setTextColor(c[1], c[2], c[3], c[4])
    setTextBold(bold == true)
    setTextAlignment(align or RenderText.ALIGN_LEFT)
    renderText(x, y, size, s)
end

function JD7810Transmission.hudCreate()
    if HUD.white ~= nil or createImageOverlay == nil then return end
    local ok, id = pcall(createImageOverlay, (JD7810Transmission.MOD_DIR or "") .. "hud/white.dds")
    if ok and id ~= nil and id ~= 0 then HUD.white = id else log("HUD: ne mogu ucitati hud/white.dds") end
end
function JD7810Transmission.hudDelete()
    if HUD.white ~= nil then pcall(delete, HUD.white); HUD.white = nil end
end

local function uiScale()
    local ok, v = pcall(function()
        if g_gameSettings == nil then return nil end
        if GameSettings ~= nil and GameSettings.SETTING ~= nil and GameSettings.SETTING.UI_SCALE ~= nil then
            return g_gameSettings:getValue(GameSettings.SETTING.UI_SCALE)
        end
        return g_gameSettings:getValue("uiScale")
    end)
    return (ok and type(v) == "number" and v > 0.3 and v < 3) and v or 1
end

-- redovi: { tipka, funkcija, stanje, ukljuceno (true/false/nil = samo info) }
local SEC_H = 0.80                -- v177: visina naslova kategorije (udio reda)
local function hudRows(motor)
    -- v177: kategorije prema rasporedu tipki (lijeva ruka LAlt + lijevi blok = u voznji; numericka = kad stojis)
    local J = JD7810Transmission
    local rows = {}
    local kind = J.motorKind ~= nil and J.motorKind(motor) or "?"
    local function add(k, l, s, on) table.insert(rows, { k, l, s, on }) end
    local function sec(t) table.insert(rows, { "", t, "", nil, true }) end
    local spd = getSpeedKmh(motor)
    local veh = motor.vehicle

    -- ZASLONI (LAlt + 1-5, Q-R)
    sec("DISPLAYS")
    local Lc = veh ~= nil and veh.jd7810Lcd or nil
    if Lc ~= nil and Lc.ok then
        add("LAlt+1 2 3 4", "LCD A / B / C / D", tostring(J.LCD_MODE_NAMES[Lc.mode] or Lc.mode), nil)
    end
    local P = veh ~= nil and veh.jd7810PM or nil
    if P ~= nil and P.ok then
        local pm = J.PM_MODES ~= nil and J.PM_MODES[P.mode] or "?"
        add("LAlt+Q / W", "Perf. Monitor", tostring(pm), nil)
        add("LAlt+E", "PM zero (trip)", "", nil)
        local wl = P.widthLevel or 0
        add("LAlt+R", "PM width", string.format("+%d %%", wl), wl > 0)
    end

    -- VOZNJA (LAlt + A-G, T, 6)
    sec("DRIVING")
    local hand = motor.jd7810HandRpm or 0
    add("LAlt+A / S", "Hand throttle", hand > 0 and string.format("%.0f rpm", hand) or "off", hand > 0)
    if JD.cfg.ptoManual then
        local ar = motor.jd7810AutoRpm or 0
        local modeT = JD.cfg.ptoAutoLoad and "load" or "rated"
        local st = not JD.cfg.ptoAutoRpm and "off (menu)" or (hand > 0 and "hand thr." or (motor.jd7810AutoRpmOn and string.format("%s %.0f rpm", modeT, ar) or modeT))
        add("menu", "Auto PTO rpm", st, motor.jd7810AutoRpmOn == true)
    end
    if (motor.jd7810PtoActive or 0) > 0 and J.ptoPower ~= nil then                                  -- v179: snaga PTO-a
        local kw = J.ptoPower(motor)
        local peak = math.max(motor.peakMotorPower or 0, 1)
        add("", "PTO power", string.format("%.0f / %.0f kW (%.0f %%)", kw, peak, kw / peak * 100), nil)
    end
    if JD.getHeadingDeg ~= nil and veh ~= nil then
        local Hh = veh.jd7810Head
        local hd = JD.getHeadingDeg(veh)
        if Hh ~= nil and Hh.on then
            add("LAlt+F", "Heading lock", string.format("%.1f deg (%+.1f)", Hh.target or 0, Hh.err or 0), true)
        else
            add("LAlt+F", "Heading lock", hd ~= nil and string.format("off (%.0f deg)", hd) or "off", false)
        end
    end
    local Hm = veh ~= nil and veh.jd7810Hms or nil
    add("LAlt+G", "HMS headland", (Hm ~= nil and Hm.on) and "ON" or "off", Hm ~= nil and Hm.on == true)
    add("LAlt+T", "Both implements", "", nil)
    if J.lightsText ~= nil and veh ~= nil then                                                     -- v180
        local rl, wl = J.lightsText(veh)
        if rl ~= nil then
            add("F / Ctrl+F", "Lights", rl, rl ~= "off")
            add("Shift+F", "Work lights", wl, wl ~= "off")
        end
    end
    add("RAlt", "Park lock", motor.jd7810Park and "P" or "off", motor.jd7810Park == true)

    -- POGON (LAlt + Y-B)
    sec("DRIVETRAIN")
    if J.MFWD_NAMES ~= nil then
        add("LAlt+Y", "MFWD " .. J.MFWD_NAMES[motor.jd7810MfwdMode or 0], motor.jd7810MfwdOn and "4WD ENGAGED" or "disengaged", motor.jd7810MfwdOn == true)
    end
    add("LAlt+X", "Diff lock (rear)", motor.jd7810DiffLock and "ENGAGED" or "released", motor.jd7810DiffLock == true)
    if kind == "IVT" then
        local okS, v, d = pcall(J.ivtSetSpeed, motor)
        local band = (J.ivtSet ~= nil and J.ivtSet.band == 2) and 2 or 1
        local auto = J.ivtSet ~= nil and (J.ivtSet.auto or 0) > 0.5
        add("LAlt+C", "IVT band", auto and string.format("AUTO (%d)", band) or string.format("%d", band), auto)
        add("LAlt+V / B", "Set speed", okS and string.format("%s%d %.1f km/h", d or "F", band, v or 0) or "-", nil)
        if J.cfg.ivtRangeHud ~= false and motor.jd7810IvtRange ~= nil then
            add("", "IVT range", motor.jd7810IvtRange, nil)
        end
    end
    if J.motorTop ~= nil and J.motorTop(motor) >= 50 then
        add("", "Power boost", motor.jd7810BoostOn and "196 hp" or "off", motor.jd7810BoostOn == true)
    end

    -- MJENJAC I GUME (kad stojis: numericka)
    sec("TRANSMISSION / TYRES")
    if kind == "IVT" then
        local mode = motor.jd7810IvtMode or math.floor((J.cfg.ivtMode or 2) + 0.5)
        add("LCtrl+Num 9", "IVT selector", (J.IVT_MODE_NAMES[mode] or tostring(mode)) .. (motor.jd7810IvtUnder and mode > 0 and "  LOAD CONTROL" or ""), mode > 0)
    else
        local gi, st = motor.gear or 0, motor.activeGearGroupIndex or 0
        local back = (motor.currentDirection or 1) < 0
        local g
        if gi == 0 then
            g = "N"
        elseif kind == "AQ" then
            local gg = motor.currentGears ~= nil and motor.currentGears[gi] or nil
            g = string.format("%s%d%s", (gg ~= nil and gg.name) or "?", st, back and "  R" or "")
        else
            g = back and ("R" .. math.min(st, 7)) or (tostring(st) .. "F")
        end
        add("game keys", kind == "AQ" and "Range A-E / gear 1-4" or "Gear 1-19 / R1-R7", g, nil)
        if kind == "AQ" then
            local m = motor.jd7810AqMode or 1
            local names = { [0] = "MANUAL", [1] = "AUTO", [2] = "ECO" }
            if J.isPowrQuad ~= nil and J.isPowrQuad(motor) then
                add("", "PowrQuad", "gears 1-4 manual", nil)
            else
                add("LCtrl+Num 9", "AutoQuad", names[m] or "?", m >= 1)
            end
        end
    end
    local fc = motor.jd7810FieldCruise or 0
    if JD.cfg.fieldCruise then
        add("Num *", "Field Cruise", fc > 0 and string.format("%.0f rpm", fc) or "off", fc > 0)
    end
    if J.tyreBar ~= nil then
        add("RShift+Num +/-", "Tyre pressure", string.format("%.2f bar", J.tyreBar(veh)), nil)
    end
    return rows, kind, spd
end

function JD7810Transmission.drawHud(motor)
    if HUD.white == nil then return end
    local ok, visible = pcall(function() return g_currentMission.hud:getIsVisible() end)
    if ok and visible == false then return end
    if g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible() then return end

    local rows, kind = hudRows(motor)
    local s = uiScale()
    local aspect = g_screenAspectRatio or (16 / 9)
    local rh = 0.0215 * s                         -- visina reda (udio visine ekrana)
    local ts = 0.0125 * s                         -- velicina teksta
    local W = 0.40 * s / aspect                   -- sirina (udio sirine ekrana) = 0,40 visine
    local hx = function(u) return u * s / aspect end   -- vodoravne mjere u jedinicama visine
    local headH = rh * 1.35
    local footH = rh * 0.85
    local nSec = 0
    for _, r in ipairs(rows) do if r[5] then nSec = nSec + 1 end end
    local H = headH + (#rows - nSec) * rh + nSec * rh * SEC_H + footH
    local x = 0.012
    local y = 0.5 - H / 2

    -- okvir: tamna plocica + zuta traka lijevo + zuto zaglavlje
    rect(x, y, W, H, C.bg)
    rect(x, y, hx(0.004), H, C.stripe)
    rect(x, y + H - headH, W, headH, C.header)
    rect(x, y + H - headH - rh * 0.08, W, rh * 0.08, C.green)
    local trans = (kind == "AQ" and (JD7810Transmission.isPowrQuad ~= nil and JD7810Transmission.isPowrQuad(motor) and "PowrQuad 20/20" or "AutoQuad II 20/20")) or (kind == "PS" and "Powershift 19/7") or (kind == "IVT" and "AutoPowr IVT") or ""
    if JD7810Transmission.motorTop ~= nil and JD7810Transmission.motorTop(motor) >= 50 then trans = trans .. " 50 km/h" end      -- v173
    text(x + hx(0.014), y + H - headH + headH * 0.30, ts * 1.15, 'JOHN DEERE 7810 "THE LEGEND"', C.headTxt, RenderText.ALIGN_LEFT, true)
    text(x + W - hx(0.010), y + H - headH + headH * 0.34, ts * 0.85, trans, C.headTxt, RenderText.ALIGN_RIGHT, true)

    -- redovi
    local keyW = hx(0.118)
    local ry = y + H - headH
    local alt = 0
    for i, r in ipairs(rows) do
      if r[5] then                                                   -- v177: naslov kategorije
        local sh = rh * SEC_H
        ry = ry - sh
        rect(x + hx(0.004), ry + sh * 0.12, W - hx(0.004), sh * 0.76, C.green)
        text(x + hx(0.014), ry + sh * 0.30, ts * 0.72, r[2], C.keyTxt, RenderText.ALIGN_LEFT, true)
        alt = 0
      else
        ry = ry - rh
        alt = alt + 1
        if alt % 2 == 0 then rect(x + hx(0.004), ry, W - hx(0.004), rh, C.rowAlt) end
        -- tipka (kapica)
        if r[1] ~= "" then
            rect(x + hx(0.012), ry + rh * 0.14, keyW, rh * 0.72, C.key)
            text(x + hx(0.012) + keyW / 2, ry + rh * 0.30, ts * 0.78, r[1], C.keyTxt, RenderText.ALIGN_CENTER, true)
        end
        -- funkcija
        text(x + hx(0.012) + keyW + hx(0.010), ry + rh * 0.28, ts * 0.92, r[2], C.label, RenderText.ALIGN_LEFT, false)
        -- stanje + LED
        local ledW = hx(0.010)
        local ledX = x + W - hx(0.012) - ledW
        if r[4] == true then
            rect(ledX - hx(0.002), ry + rh * 0.22, ledW + hx(0.004), rh * 0.56, C.onBg)
            rect(ledX, ry + rh * 0.30, ledW, rh * 0.40, C.on)
            text(ledX - hx(0.008), ry + rh * 0.28, ts * 0.92, r[3], C.on, RenderText.ALIGN_RIGHT, true)
        elseif r[4] == false then
            rect(ledX, ry + rh * 0.30, ledW, rh * 0.40, C.off)
            text(ledX - hx(0.008), ry + rh * 0.28, ts * 0.92, r[3], C.off, RenderText.ALIGN_RIGHT, false)
        else
            text(ledX + ledW, ry + rh * 0.28, ts * 0.92, r[3], C.info, RenderText.ALIGN_RIGHT, true)
        end
      end
    end
    -- podnozje
    rect(x + hx(0.004), y + footH - rh * 0.06, W - hx(0.004), rh * 0.06, C.green)
    text(x + hx(0.014), y + footH * 0.30, ts * 0.75, "LAlt + 5  hide / show   |   LAlt = while driving, Num = standing", C.off, RenderText.ALIGN_LEFT, false)

    -- vrati postavke teksta
    setTextColor(1, 1, 1, 1); setTextBold(false); setTextAlignment(RenderText.ALIGN_LEFT)
end


-- =====================================================================
--  H2) KOMPAS (v155, Darijan 7.10.): vodoravna traka gore na sredini ekrana (kao VCA / avion).
--      Skala +-60 st., crtice svakih 5, brojke svakih 30 (N E S W), veliki broj smjera,
--      zeleni marker zakljucanog smjera (LCtrl+2) i odstupanje. Crta se samo u nasem 7810;
--      pali/gasi: ESC > Settings > General Settings > JOHN DEERE 7810 > Compass HUD.
-- =====================================================================
local CC = {
    bg     = { 0.004, 0.022, 0.006, 0.78 },
    tick   = { 0.85, 0.88, 0.85, 1 },
    card   = { 1.0, 0.80, 0.10, 1 },
    center = { 1.0, 0.73, 0.0, 1 },
    lock   = { 0.16, 0.80, 0.05, 1 },
    warn   = { 1.0, 0.35, 0.10, 1 },
}
local CARD = { [0] = "N", [90] = "E", [180] = "S", [270] = "W" }
local function wrap180d(a) a = (a + 180) % 360; if a < 0 then a = a + 360 end; return a - 180 end
function JD7810Transmission.drawCompass(motor)
    if HUD.white == nil or JD.getHeadingDeg == nil then return end
    if JD.cfg.compassHud == false then return end
    local ok, visible = pcall(function() return g_currentMission.hud:getIsVisible() end)
    if ok and visible == false then return end
    if g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible() then return end
    local v = motor.vehicle
    local hdg = JD.getHeadingDeg(v)
    if hdg == nil then return end
    local Hh = v.jd7810Head
    local locked = Hh ~= nil and Hh.on
    local s = uiScale() * (JD.cfg.compassScale or 1)
    local aspect = g_screenAspectRatio or (16 / 9)
    local hx = function(u) return u * s / aspect end
    local a = JD.cfg.compassAlpha or 0.8
    CC.bg[4] = a
    local span = 60                                -- +- stupnjeva na traci
    local W = hx(0.62)                             -- sirina trake
    local Ht = 0.034 * s                           -- visina trake
    local ts = 0.0125 * s
    local cx = 0.5
    local y = 0.955 - Ht                           -- gornji rub ekrana
    local x0 = cx - W / 2
    local pxDeg = W / (2 * span)
    rect(x0, y, W, Ht, CC.bg)
    rect(x0, y + Ht * 0.95, W, Ht * 0.05, CC.center)              -- zuta crta gore
    -- crtice i brojke
    local labels = {}                              -- v155b: brojke / N E S W crtaju se zadnje (iznad oznaka)
    local first = math.ceil((hdg - span) / 5) * 5
    for d = first, hdg + span, 5 do
        local x = cx + (d - hdg) * pxDeg
        local dn = d % 360
        local major = dn % 30 == 0
        local th = major and Ht * 0.45 or (dn % 10 == 0 and Ht * 0.30 or Ht * 0.18)
        rect(x - hx(0.0007), y + Ht - th, hx(0.0014), th, CC.tick)
        if major then labels[#labels + 1] = { x, dn } end
    end
    -- zakljucani smjer: zeleni marker (na rubu ako je izvan trake)
    local err = 0
    if locked then
        err = wrap180d((Hh.target or hdg) - hdg)
        local off = math.max(-span, math.min(span, err))
        local mx = cx + off * pxDeg
        rect(mx - hx(0.0035), y, hx(0.007), Ht, { CC.lock[1], CC.lock[2], CC.lock[3], 0.55 })
        rect(mx - hx(0.0012), y, hx(0.0024), Ht, CC.lock)
    end
    -- sredina (smjer traktora)
    -- v155b: oznaka sredine samo u gornjem dijelu (crtice), da se brojka / N E S W ispod vidi
    rect(cx - hx(0.0015), y + Ht * 0.45, hx(0.003), Ht * 0.55, CC.center)
    rect(cx - hx(0.006), y - Ht * 0.12, hx(0.012), Ht * 0.10, CC.center)
    for _, L in ipairs(labels) do
        local dn = L[2]
        local lbl = CARD[dn] or string.format("%d", dn)
        text(L[1], y + Ht * 0.12, ts * (CARD[dn] and 1.15 or 0.85), lbl, CARD[dn] and CC.card or CC.tick, RenderText.ALIGN_CENTER, CARD[dn] ~= nil)
    end
    -- broj smjera ispod trake
    local bw, bh = hx(0.075), Ht * 0.85
    rect(cx - bw / 2, y - Ht * 0.2 - bh, bw, bh, CC.bg)
    text(cx, y - Ht * 0.2 - bh + bh * 0.22, ts * 1.35, string.format("%03d\194\176", math.floor(hdg + 0.5) % 360), CC.center, RenderText.ALIGN_CENTER, true)
    if locked then
        local dir = (err > 0.25 and " >") or (err < -0.25 and "< ") or "  "
        local c = math.abs(err) > 5 and CC.warn or CC.lock
        local lx = cx + bw / 2 + hx(0.010)
        text(lx, y - Ht * 0.2 - bh + bh * 0.25, ts * 1.0, string.format("LOCK %05.1f\194\176   %s%.1f\194\176%s", Hh.target or 0, err < -0.25 and "< " or "", math.abs(err), err > 0.25 and " >" or ""), c, RenderText.ALIGN_LEFT, true)
    else
        text(cx + bw / 2 + hx(0.010), y - Ht * 0.2 - bh + bh * 0.25, ts * 0.85, "LAlt+F lock", CC.tick, RenderText.ALIGN_LEFT, false)
    end
    setTextColor(1, 1, 1, 1); setTextBold(false); setTextAlignment(RenderText.ALIGN_LEFT)
end

function JD7810Transmission:draw()
    local motor = getOurCurrentMotor()
    if motor == nil then return end
    -- v155: kompas ne ovisi o LCtrl+Num 0 (ima svoju opciju u izborniku)
    local okC, errC = pcall(JD7810Transmission.drawCompass, motor)
    if not okC and not JD7810Transmission.compassErr then JD7810Transmission.compassErr = true; log("kompas greska: " .. tostring(errC)) end
    if not JD7810Transmission.hudOn then return end
    local ok, err = pcall(JD7810Transmission.drawHud, motor)
    if not ok and not JD7810Transmission.hudErr then JD7810Transmission.hudErr = true; log("HUD greska: " .. tostring(err)) end
end

function JD7810Transmission.actionHud(vehicle, actionName, inputValue, callbackState, isAnalog)
    JD7810Transmission.hudOn = not JD7810Transmission.hudOn
end
