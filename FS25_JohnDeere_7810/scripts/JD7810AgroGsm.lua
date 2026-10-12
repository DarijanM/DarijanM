-- =====================================================================
--  JD7810AgroGsm.lua   v8.1  (FS25 - osobna upotreba, Darijan)
--  Agro GSM mobitel: LCD, signal, baterija, kolijevka, Interactive Control (IC) registracija
--  v8.1: podjela JD7810Transmission.lua v8.0 na module - kod premjesten
--        bez promjene ponasanja. Redoslijed ucitavanja u modDesc.xml:
--        Core, Transmission, Engine, PTO, Display, PerformanceMonitor, AgroGsm, Cockpit
-- =====================================================================

local JD = JD7810Transmission
local SEG7 = JD.U.SEG7
local SEGS = JD.U.SEGS
local clamp = JD.U.clamp
local log = JD.U.log
local vis = JD.U.vis

local function gsmNodes(vehicle)
    if vehicle.jd7810GSM ~= nil then return vehicle.jd7810GSM end
    local G = { ok = false }
    vehicle.jd7810GSM = G
    local ok, root = pcall(I3DUtil.indexToObject, vehicle.components, "agroGsm", vehicle.i3dMappings)
    local function kids(n)
        local t = {}
        local okc, cnt = pcall(getNumOfChildren, n)
        if okc and cnt ~= nil then for i = 0, cnt - 1 do local okn, nm = pcall(function() return getName(getChildAt(n, i)) end); t[#t + 1] = okn and tostring(nm) or "?" end end
        return table.concat(t, ",")
    end
    if not ok or root == nil or root == 0 then G.why = "agroGsm: " .. tostring(root); return G end
    local function ch(parent, name) if parent == nil then return nil end local n = getChild(parent, name); if n ~= nil and n ~= 0 then return n end return nil end
    local phone = ch(root, "gsmPhone")
    local seg = ch(phone, "gsmSeg")
    if seg == nil then
        G.why = string.format("agroGsm=%s '%s' [%s] gsmPhone=%s [%s]", tostring(root), tostring(getName(root)), kids(root), tostring(phone), phone ~= nil and kids(phone) or "-")
        return G
    end
    G.t, G.d = {}, {}
    for i = 1, 4 do local n = ch(seg, "gsmT" .. i); G.t[i] = {}; for _, s in ipairs(SEGS) do G.t[i][s] = ch(n, "gsmT" .. i .. s) end end
    for i = 1, 6 do local n = ch(seg, "gsmD" .. i); G.d[i] = {}; for _, s in ipairs(SEGS) do G.d[i][s] = ch(n, "gsmD" .. i .. s) end end
    G.col, G.dots = ch(seg, "gsmTcol"), ch(seg, "gsmDdots")
    G.seg = seg
    local st = ch(seg, "gsmStatus")
    G.ant, G.batBox, G.chg = ch(st, "gsmSigAnt"), ch(st, "gsmBatBox"), ch(st, "gsmBatChg")
    G.sig, G.bat = {}, {}
    for i = 1, 4 do G.sig[i] = ch(st, "gsmSig" .. i); G.bat[i] = ch(st, "gsmBat" .. i) end
    G.battery = JD7810Transmission.gsmBattery or 1.0          -- 0..1, sprema se u savegame
    G.bars = 3; G.sigT = 0
    G.inCradle = JD7810Transmission.gsmInCradle ~= false
    vis(G.dots, true)
    pcall(JD.U.fontDigits, G.t, "GSM_sat"); pcall(JD.U.fontDigits, G.d, "GSM_datum")   -- font igre umjesto segmenata
    G.ok = true; G.shown = nil; G.colOn = nil
    return G
end

local function gsmDigits(list, txt)
    for i = 1, #list do
        local on = SEG7[txt:sub(i, i)] or ""
        if not JD.U.fontDigitSet(list[i], txt:sub(i, i)) then
            for _, sg in ipairs(SEGS) do vis(list[i][sg], on:find(sg, 1, true) ~= nil) end
        end
    end
end

-- stvarno vrijeme racunala: GIANTS getDate (strftime), pa os.date; tek kad nijedno ne radi -> vrijeme u igri
-- jednom se u log zapise sto je dostupno ("JD7810: Agro GSM sat ..."), da se vidi sto igra dopusta modovima
local GSM_FMT = "%H%M%S%d%m%y"
local gsmSource = nil
local function gsmTry(fn)
    if type(fn) ~= "function" then return nil, "nema (" .. type(fn) .. ")" end
    local ok, s = pcall(fn, GSM_FMT)
    if ok and type(s) == "string" and #s == 12 and s:match("^%d+$") then return s end
    return nil, ok and ("vratio '" .. tostring(s) .. "'") or ("greska: " .. tostring(s))
end
local function gsmGlobal(name)
    local ok, v = pcall(function() return _G ~= nil and _G[name] or nil end)
    if ok and v ~= nil then return v end
    return nil
end
local function gsmDiag()
    local parts = {}
    for _, n in ipairs({ "getDate", "getDateAt", "getTime", "getTimeSec", "netGetTime", "getTimeNs", "os" }) do
        local v = gsmGlobal(n)
        local t = type(v)
        if t == "function" and n ~= "getDate" and n ~= "getDateAt" then
            local ok, r = pcall(v); t = t .. "=" .. tostring(ok and r or "err")
        end
        table.insert(parts, n .. ":" .. t)
    end
    local osLib = gsmGlobal("os")
    if type(osLib) == "table" then
        for _, n in ipairs({ "date", "time", "clock" }) do table.insert(parts, "os." .. n .. ":" .. type(osLib[n])) end
    end
    return table.concat(parts, " ")
end
local function gsmNow()
    local s, why1 = gsmTry(getDate)
    if s ~= nil then
        if gsmSource ~= "getDate" then gsmSource = "getDate"; log("Agro GSM sat: stvarno vrijeme (getDate) " .. s) end
        return s
    end
    local osLib = gsmGlobal("os")
    local s2, why2 = gsmTry(type(osLib) == "table" and osLib.date or nil)
    if s2 ~= nil then
        if gsmSource ~= "os.date" then gsmSource = "os.date"; log("Agro GSM sat: stvarno vrijeme (os.date) " .. s2) end
        return s2
    end
    if gsmSource ~= "igra" then
        gsmSource = "igra"
        log("Agro GSM sat: stvarno vrijeme nedostupno - getDate " .. tostring(why1) .. ", os.date " .. tostring(why2) .. " | " .. gsmDiag())
    end
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local m = env ~= nil and math.floor((env.dayTime or 0) / 60000) or 0
    local day = env ~= nil and (env.currentDayInPeriod or 1) or 1
    local month = env ~= nil and (env.currentPeriod or 1) or 1
    local year = env ~= nil and (env.currentYear or 1) or 1
    return string.format("%02d%02d%02d%02d%02d%02d", math.floor(m / 60) % 24, m % 60, math.floor((g_time or 0) / 1000) % 60, day % 100, month % 100, year % 100)
end

function JD7810Transmission.updateAgroGsm(vehicle, dt)
    local G = gsmNodes(vehicle)
    if not G.ok then
        if not G.warned then G.warned = true; log("Agro GSM: cvorovi mobitela nisu pronadeni: " .. tostring(G.why)) end
        return
    end
    local s = gsmNow()
    local key = s:sub(1, 4) .. s:sub(7, 12)                 -- HHMM + DDMMYY
    if key ~= G.shown then
        local hh = s:sub(1, 2)
        if hh:sub(1, 1) == "0" then hh = " " .. hh:sub(2, 2) end   -- vodeca nula sata se ne prikazuje (kao na mobitelima tog doba)
        gsmDigits(G.t, hh .. s:sub(3, 4))
        gsmDigits(G.d, s:sub(7, 12))
        G.shown = key
    end
    local colOn = tonumber(s:sub(5, 6)) % 2 == 0          -- dvotocka trepce jednom u sekundi
    if colOn ~= G.colOn then vis(G.col, colOn); G.colOn = colOn end
    pcall(JD7810Transmission.updateGsmStatus, vehicle, G, dt)
end

-- ---------- signal i baterija ----------
JD7810Transmission.GSM_CHARGE_H = 2      -- od prazne do pune na punjacu (sati u igri)
JD7810Transmission.GSM_STANDBY_H = 36    -- od pune do prazne bez punjenja (sati u igri)
-- signal: vidljivost prema odasiljacu -> sto je traktor visi od okolnog terena (krug 300 m), to je signal jaci
local function gsmSignal(vehicle)
    local mission = g_currentMission
    local terrain = mission ~= nil and mission.terrainRootNode or nil
    if terrain == nil or vehicle.rootNode == nil then return 3 end
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    local h = getTerrainHeightAtWorldPos(terrain, x, 0, z)
    local half = (mission.terrainSize or 2048) / 2 - 10
    local sum, n = 0, 0
    for k = 0, 7 do
        local a = k * math.pi / 4
        local sx, sz = clamp(x + math.cos(a) * 300, -half, half), clamp(z + math.sin(a) * 300, -half, half)
        sum = sum + getTerrainHeightAtWorldPos(terrain, sx, 0, sz); n = n + 1
    end
    local diff = h - sum / n                                  -- + brdo, - dolina (m)
    local t = (g_time or 0) / 1000
    local wobble = 0.35 * math.sin(t * 0.21) + 0.25 * math.sin(t * 0.53 + 1.7)   -- blago, sporo kolebanje
    return math.floor(clamp(3 + diff / 10 + wobble, 1, 4) + 0.5)
end
-- =====================================================================
--  P) INTERACTIVE CONTROL (FS25_interactiveControl, VertexDezign): klik na tipke
--     monitora i vadenje mobitela iz korita. Bez IC moda sve radi preko numpada.
-- =====================================================================
local function pmSetMode(vehicle, name)
    local P = vehicle.jd7810PM
    if P == nil or not P.ok then return end
    for i, m in ipairs(JD7810Transmission.PM_MODES) do
        if m == name then P.mode = i end
    end
end
local function gsmPhoneNode(vehicle)
    if vehicle.jd7810GsmPhoneNode == nil then
        local ok, n = pcall(I3DUtil.indexToObject, vehicle.components, "gsmPhone", vehicle.i3dMappings)
        vehicle.jd7810GsmPhoneNode = (ok and n ~= nil and n ~= 0) and n or 0
    end
    return vehicle.jd7810GsmPhoneNode
end
function JD7810Transmission.setGsmInCradle(vehicle, inCradle)
    local G = gsmNodes(vehicle)
    G.inCradle = inCradle
    JD7810Transmission.gsmInCradle = inCradle
    local n = gsmPhoneNode(vehicle)
    if n ~= 0 then setVisibility(n, inCradle) end              -- izvaden = vozac ga je uzeo, korito prazno
end
function JD7810Transmission.registerIC()
    local env = _G["FS25_interactiveControl"]
    local IF = env ~= nil and env.InteractiveFunctions or nil
    if IF == nil or IF.addFunction == nil then return false end
    if IF.FUNCTION_ID ~= nil and IF.FUNCTION_ID["JD7810_PM_SPEED"] ~= nil then return true end
    local function modeFn(name)
        return { posFunc = function(target, data, noEventSend)
            if noEventSend then return end
            pmSetMode(target, name)
            JD7810Transmission.pmBeep()
        end }
    end
    IF.addFunction("JD7810_PM_SPEED", modeFn("SPEED"))
    IF.addFunction("JD7810_PM_SLIP", modeFn("SLIP"))
    IF.addFunction("JD7810_PM_PTO", modeFn("PTO"))
    IF.addFunction("JD7810_PM_AREA", modeFn("AREA"))
    IF.addFunction("JD7810_PM_WORK", modeFn("WORK"))
    IF.addFunction("JD7810_PM_WIDTH", modeFn("WIDTH"))
    IF.addFunction("JD7810_PM_SERV", modeFn("SERV"))
    IF.addFunction("JD7810_PM_ZERO", { posFunc = function(target, data, noEventSend)
        if noEventSend then return end
        JD7810Transmission.actionPmZero(target)
    end })
    IF.addFunction("JD7810_PM_SET", { posFunc = function(target, data, noEventSend)
        if noEventSend then return end
        JD7810Transmission.actionPmWidth(target)                  -- radi samo u WDTH prikazu
    end })
    IF.addFunction("JD7810_GSM_CRADLE", {                        -- stanje "ukljuceno" = mobitel izvaden
        posFunc = function(target, data, noEventSend) if not noEventSend then JD7810Transmission.setGsmInCradle(target, false) end end,
        negFunc = function(target, data, noEventSend) if not noEventSend then JD7810Transmission.setGsmInCradle(target, true) end end,
        updateFunc = function(target, data)
            local G = target.jd7810GSM
            if G == nil then return nil end
            return G.inCradle == false
        end
    })
    log("Interactive Control: funkcije monitora i mobitela registrirane")
    return true
end
pcall(JD7810Transmission.registerIC)                              -- ako je IC vec ucitan; inace ponovno u loadMap

function JD7810Transmission.updateGsmStatus(vehicle, G, dt)
    local mi = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local gameMs = dt * ((mi ~= nil and mi.timeScale) or 1)
    local running = false
    if type(vehicle.getIsMotorStarted) == "function" then local ok, r = pcall(vehicle.getIsMotorStarted, vehicle); running = ok and r == true end
    if not G.cradleApplied then G.cradleApplied = true; JD7810Transmission.setGsmInCradle(vehicle, G.inCradle ~= false) end
    local inCradle = G.inCradle ~= false                      -- Interactive Control: izvaden mobitel se ne puni
    local charging = running and inCradle
    if charging then
        G.battery = math.min(1, G.battery + gameMs / (JD7810Transmission.GSM_CHARGE_H * 3600000))
    else
        G.battery = math.max(0, G.battery - gameMs / (JD7810Transmission.GSM_STANDBY_H * 3600000))
    end
    JD7810Transmission.gsmBattery = G.battery
    -- prazna baterija: zaslon se gasi dok se ne upali motor
    local on = G.battery > 0 or charging
    vis(G.seg, on)
    if not on then return end
    G.sigT = G.sigT - dt
    if G.sigT <= 0 then G.sigT = 2000; local ok, b = pcall(gsmSignal, vehicle); if ok and b ~= nil then G.bars = b end end
    for i = 1, 4 do vis(G.sig[i], i <= G.bars) end
    vis(G.ant, true); vis(G.batBox, true); vis(G.chg, charging)
    local full = math.floor(G.battery * 4 + 0.001)             -- pune crtice
    local shown = full
    if charging and G.battery < 0.999 then                      -- punjenje: crtice se pune redom (kao pravi punjac)
        shown = full + math.floor((g_time or 0) / 500) % (5 - full)
    elseif full <= 1 then                                        -- skoro prazna: zadnja crtica trepce
        shown = (math.floor((g_time or 0) / 500) % 2 == 0) and 1 or 0
    end
    for i = 1, 4 do vis(G.bat[i], i <= shown) end
end

