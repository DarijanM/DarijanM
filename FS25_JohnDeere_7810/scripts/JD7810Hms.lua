-- =====================================================================
--  JD7810Hms.lua   v8.5  (FS25 - osobna upotreba, Darijan)
--  HMS (Headland Management System) + GreenStar terminal (original, 2001)
--  9. modul: ucitava se NAKON Core (i nakon Cockpit, koristi getImplements).
--
--  STO RADI
--   - LAlt+H (ili tipka na terminalu) pali HMS. Kad je upaljen:
--       * granica polja iz staze igre (AI), rezervno gustoca tla; uvratina = N redova x radna sirina,
--         mjereno uzduz smjera voznje (rub ispred / iza markera)
--       * svaki prikljucak prati SVOJ marker (AI markeri ili radno podrucje):
--         izlazak u uvratinu -> dize, povratak u polje -> spusta (predvidjanje:
--         brzina x trajanje spustanja + 0,5 m; sijacica tocno na liniji, plug dize ranije)
--       * work mode: na spustanju radni okretaji (rucni gas), PTO ukljuci; na uvratini
--         diferencijal isklj. (ako su redovi F/G na AUTO)
--       * rucni zahvat vozaca (podizanje/spustanje tipkom) = taj prikljucak ceka
--         sljedeci prijelaz zone (kontrola vozacu)
--   - Birac V = F / B / R (tipka G u igri, red G terminala, kasnije fizicki prekidac):
--     F ili R: V radi standardno na odabrani; B (OBA): prednji odmah, straznji na ISTOJ liniji
--     (po prijedjenom razmaku markera) - radi i bez HMS-a. LAlt+V: oba odmah.
--   - Terminal: zaslon = CharacterLine redovi (font igre) + 15 segmenata svjetlosne trake
--     (odstupanje od A-B linije, 5 cm/segment), tipke = Interactive Control (klik), piip.
--     Stranice: RAD (RUN) / SETUP / INFO, PAGE kruzi. A-G biraju red, brojke unose, CLR brise.
--   - Okret i prelazak na sljedecu traku radi VOZAC (RUCNO). POLUAUTO je zasad samo oznaka
--     (nema upravljanja) - svjesno, AutoTrac je dosao tek 2002/03.
--
--  Cvorovi (i3dMappings): gsScreen, gsLightbar_01..15, gsHdr, gsRowA..G, gsValA..G, gsFoot,
--     gsScreenGlow (EMITTER u XML-u), gsKey* (IC tocke u XML-u)
--  IC funkcije: JD7810_GS_A..G, JD7810_GS_0..9, JD7810_GS_DOT, JD7810_GS_CLR,
--     JD7810_GS_PAGE, JD7810_GS_SETUP, JD7810_GS_INFO, JD7810_GS_RUN, JD7810_GS_BRIGHT
--  Akcije: JD7810_HMS_TOGGLE (LAlt+H), JD7810_HMS_ALL (LAlt+V)
--  Postavke (jd7810Settings.xml <hms .../>): enabled, rows, mode, sound, font, lightbarCm
-- =====================================================================

local JD = JD7810Transmission
local log = JD.U.log
local setEvent = JD.U.setEvent
local clamp = JD.U.clamp

JD.HMS_VERSION = "8.6"

-- ---------------------------------------------------------------------
--  Postavke (dodaju se u Core popis; datoteka se ponovno procita na kraju modula)
-- ---------------------------------------------------------------------
local HMS_SETTINGS = {
    { key = "hmsRows",       type = "float", default = 2,    xml = ".hms#rows",       desc = "HMS: broj redova uvratine (1-6)",                 min = 1,   max = 6 },
    { key = "hmsMode",       type = "float", default = 0,    xml = ".hms#mode",       desc = "HMS: 0 = MANUAL (vozac okrece), 1 = SEMI-AUTO (zasad samo oznaka)", min = 0, max = 1 },
    { key = "hmsSound",      type = "bool",  default = true, xml = ".hms#sound",      desc = "HMS/terminal: piip na tipku i na dizanje/spustanje" },
    { key = "hmsPto",        type = "bool",  default = true, xml = ".hms#pto",        desc = "HMS: PTO automatski uz spustanje (red G AUTO)" },
    { key = "hmsDiff",       type = "bool",  default = true, xml = ".hms#diff",       desc = "HMS: diferencijal isklj. na uvratini (red G AUTO)" },
    { key = "hmsWorkRpm",    type = "float", default = 1950, xml = ".hms#workRpm",    desc = "HMS: radni okretaji na spustanju (rucni gas), 0 = ne diraj", min = 0, max = 2300 },
    { key = "hmsAlignKeys",  type = "bool",  default = true, xml = ".hms#alignKeys", desc = "v187: redovi A-G terminala u ravnini s bocnim tipkama" },
    { key = "hmsLightbarDir", type = "float", default = -1,  xml = ".hms#lightbarDir", desc = "v186: svjetlosna traka -1 = svijetli strana na koju treba skrenuti, 1 = strana na kojoj je traktor (obrnuto)", min = -1, max = 1 },
    { key = "hmsLightbarCm", type = "float", default = 5,    xml = ".hms#lightbarCm", desc = "terminal: cm po segmentu svjetlosne trake",       min = 2,   max = 20 },
    { key = "hmsFont",       type = "float", default = 1,    xml = ".hms#font",       desc = "terminal: 1 = font GENERIC (slova), 0 = DIGIT (samo brojke)", min = 0, max = 1 },
    { key = "hmsTextSize",   type = "float", default = 5.0,  xml = ".hms#textSize",   desc = "terminal: visina znaka u mm",                     min = 3,   max = 8 },
    { key = "hmsFontThick",  type = "float", default = 1.8,  xml = ".hms#fontThick",  desc = "terminal: debljina slova (1 = tanko, 2 = debelo)", min = 1,   max = 3 },
    { key = "hmsTextRotX",   type = "float", default = -90,  xml = ".hms#textRotX",   desc = "terminal: okret teksta oko X (st.) - sidra iz Blendera imaju Y prema vozacu", min = -180, max = 180 },
    { key = "hmsCharSpace",  type = "float", default = 0.6,  xml = ".hms#charSpace",  desc = "terminal: razmak izmedju slova (1 = font igre)",    min = 0.2, max = 1.5 },
    { key = "vSelDir",       type = "float", default = 1,    xml = ".hms#vSelDir",    desc = "prekidac biraca V: smjer klizanja gumba (1 ili -1)", min = -1,  max = 1 },
}
for _, s in ipairs(HMS_SETTINGS) do
    table.insert(JD.SETTINGS, s)
    if JD.cfg[s.key] == nil then JD.cfg[s.key] = s.default end
end

-- ---------------------------------------------------------------------
--  Pomocno
-- ---------------------------------------------------------------------
local function call(obj, fname, ...)
    if obj ~= nil and type(obj[fname]) == "function" then
        local ok, a, b, c = pcall(obj[fname], obj, ...)
        if ok then return a, b, c end
    end
    return nil
end
local function isOursVehicle(vehicle)
    return vehicle ~= nil and vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor ~= nil and JD.U.isOurs(vehicle.spec_motorized.motor)
end
local function motorOn(vehicle)
    local r = call(vehicle, "getIsMotorStarted")
    return r == true
end
local function beep()
    if JD.cfg.hmsSound == false then return end
    if JD.pmBeep ~= nil then pcall(JD.pmBeep) end
end
local function vis(n, v) if n ~= nil and n ~= 0 then setVisibility(n, v) end end
local function fmt1(v) return string.format("%.1f", v) end

-- =====================================================================
--  A) STANJE PO TRAKTORU
-- =====================================================================
local function hmsState(vehicle)
    if vehicle.jd7810Hms ~= nil then return vehicle.jd7810Hms end
    local H = {
        on = false,
        page = "RUN",            -- RUN / SETUP / INFO / HDG (v155: smjer)
        row = nil,               -- odabrani red (A..G) za unos
        input = "",              -- medjuspremnik brojcanog unosa
        rows = JD.cfg.hmsRows or 2,
        mode = (JD.cfg.hmsMode or 0) >= 0.5 and "SEMI-AUTO" or "MANUAL",
        width = 0,               -- radna sirina (m) - auto + rucna korekcija
        widthManual = nil,
        passes = 0,
        areaHa = 0,              -- obradjeno od ukljucenja (iz prijedjenog puta x sirina)
        distM = 0,
        course = nil,            -- SteeringFieldCourse (granica polja igre) ili nil = gustoca tla
        fieldPending = false,    -- zahtjev za stazu u tijeku
        fieldReqT = 0,
        fieldText = "SEARCHING",
        zoneT = 0,               -- akumulator za racunanje zona (ZONE_PERIOD_MS)
        impl = {},               -- po prikljucku: { zone, lastLowered, byUs, armed, pending }
        ab = nil,                -- A-B linija { x, z, dx, dz }
        offsetCm = nil,
        pendingRear = nil,       -- V kratki: { object, distLeft }
        odo = 0,
        msg = "", msgT = 0,
        dirty = true, txtT = 0,
        lastRun = 0,
    }
    vehicle.jd7810Hms = H
    return H
end
local function say(H, text, ms)
    H.msg = text; H.msgT = ms or 3000; H.dirty = true
    setEvent("HMS: " .. text)
end

-- =====================================================================
--  B) POLJE (v8.4): granica staze polja igre (AI) ili rezervno gustoca tla.
--     API potvrdjen u izvoru igre 1.24 (AIAutomaticSteering.lua 468/752/759, AIDriveStrategyFieldCourse.lua 87):
--       FieldCourseSettings.generate(vehicle) -> settings
--       g_fieldCourseManager:generateFieldCourseAtWorldPos(x, z, settings, callback(target, course), target)
--       SteeringFieldCourse.new(course):getIsPointInsideBoundary(x, z)
--     Uvratina se mjeri UZDUZ smjera voznje (rub ispred / iza markera), ne najbliza udaljenost:
--     voznja uz bocni rub ostaje WORK.
-- =====================================================================
local FIELD_RETRY_MS = 10000      -- ponovni zahtjev ako nema staze, a traktor je na polju (gustoca)
local ZONE_PERIOD_MS = 100        -- zone se racunaju 10x u sekundi
local ZONE_STABLE_MS = 250        -- nova zona mora se drzati toliko prije reakcije (nazubljen rub, teleport)
local PROBE_STEP = 2.0            -- gruba sonda (m), zatim binarno do ~0,25 m

-- rezervno: je li tocka na polju (gustoca tla igre; Vehicle.lua 2553)
local function onFieldDensity(x, z)
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFieldDataAtWorldPosition == nil then return nil end
    local ok, isOnField = pcall(FSDensityMapUtil.getFieldDataAtWorldPosition, x, 0, z)
    if ok then return isOnField == true end
    return nil
end
local function requestField(vehicle, H)
    H.course = nil
    H.fieldReqT = g_currentMission.time or 0
    if FieldCourseSettings == nil or FieldCourseSettings.generate == nil or g_fieldCourseManager == nil
        or g_fieldCourseManager.generateFieldCourseAtWorldPos == nil or SteeringFieldCourse == nil or SteeringFieldCourse.new == nil then
        H.fieldText = "DENSITY"
        log("HMS: API staze polja nije dostupan - rezervna detekcija (gustoca tla)")
        return
    end
    local root = vehicle.rootVehicle or vehicle
    local ok, settings = pcall(FieldCourseSettings.generate, root)
    if not ok or settings == nil then H.fieldText = "DENSITY"; log("HMS: FieldCourseSettings.generate nije uspio - gustoca tla"); return end
    if settings.implementWidth ~= nil and settings.implementWidth > 0.2 then H.widthAuto = settings.implementWidth end
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    if g_fieldCourseManager.roundToTerrainDetailPixel ~= nil then
        local ok3, rx, rz = pcall(g_fieldCourseManager.roundToTerrainDetailPixel, g_fieldCourseManager, x, z)
        if ok3 and rx ~= nil then x, z = rx, rz end
    end
    H.fieldPending = true
    H.fieldText = "SEARCHING"
    local ok2 = pcall(g_fieldCourseManager.generateFieldCourseAtWorldPos, g_fieldCourseManager, x, z, settings, function(_, course)
        H.fieldPending = false
        H.dirty = true
        if course == nil then
            H.fieldText = "NO FIELD"
            log("HMS: staza polja nije pronadjena - gustoca tla")
            return
        end
        local ok4, sfc = pcall(SteeringFieldCourse.new, course)
        if ok4 and sfc ~= nil and type(sfc.getIsPointInsideBoundary) == "function" then
            H.course = sfc
            H.fieldText = "FIELD OK"
            log(string.format("HMS: field course OK (sirina %.2f m)", settings.implementWidth or 0))
        else
            H.fieldText = "NO FIELD"
            log("HMS: SteeringFieldCourse nije uspio - gustoca tla")
        end
    end, nil)
    if not ok2 then H.fieldPending = false; H.fieldText = "DENSITY"; log("HMS: generateFieldCourseAtWorldPos greska - gustoca tla") end
end
-- jedini izvor istine "unutra / vani": granica staze, inace gustoca tla
local function inside(H, x, z)
    if H.course ~= nil then
        local ok, r = pcall(H.course.getIsPointInsideBoundary, H.course, x, z)
        if ok then return r == true end
    end
    local on = onFieldDensity(x, z)
    if on == nil then return true end      -- nema ni gustoce: sve WORK (HMS bez automatike, kao prije)
    return on
end
-- udaljenost od (x,z) do ruba u smjeru (dx,dz), najvise maxD (vraca maxD + 1 ako ruba nema)
local function edgeDist(H, x, z, dx, dz, maxD)
    local last = 0
    local d = PROBE_STEP
    while d <= maxD + PROBE_STEP do
        if not inside(H, x + dx * d, z + dz * d) then
            local lo, hi = last, d
            for _ = 1, 3 do
                local mid = (lo + hi) * 0.5
                if inside(H, x + dx * mid, z + dz * mid) then lo = mid else hi = mid end
            end
            return (lo + hi) * 0.5
        end
        last = d
        d = d + PROBE_STEP
    end
    return maxD + 1
end
-- v188: zona po udaljenosti od ruba polja u SVIM smjerovima (ne samo naprijed/natrag):
--   "OUT" izvan polja, "HEAD" uvratina = pojas sirine (redovi x radna sirina) uz cijeli rub, "WORK" unutrasnjost.
--   Prije se gledalo samo uzduz smjera voznje -> pri okretu uz rub (voznja paralelno s rubom) zona je postala
--   WORK i prikljucak se spustio. Unutrasnjost = krug polumjera uvratine oko tocke cijeli u polju (24 sonde).
local ZONE_DIRS = 16
local function zoneAt(H, x, z, dx, dz)
    if not inside(H, x, z) then return "OUT", 0, 0 end
    local head = math.max(0.5, H.rows * math.max(H.width, 1.0))
    for _, rr in ipairs({ head, head * 0.5 }) do
        local n = (rr == head) and ZONE_DIRS or 8
        for i = 0, n - 1 do
            local a = (i / n) * 2 * math.pi
            if not inside(H, x + math.cos(a) * rr, z + math.sin(a) * rr) then return "HEAD", 0, 0 end
        end
    end
    return "WORK", head, head
end
local function updateFieldRequest(vehicle, H)
    if H.course ~= nil or H.fieldPending then return end
    local t = g_currentMission.time or 0
    if (t - (H.fieldReqT or 0)) < FIELD_RETRY_MS then return end
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    if onFieldDensity(x, z) then requestField(vehicle, H) else H.fieldReqT = t end
end

-- =====================================================================
--  C) PRIKLJUCCI: markeri, vrsta, spustanje/dizanje
-- =====================================================================
local function implKind(obj)
    if obj.spec_sowingMachine ~= nil then return "SEED" end
    if obj.spec_plow ~= nil then return "PLOW" end
    if obj.spec_sprayer ~= nil then return "SPRAY" end
    if obj.spec_mower ~= nil then return "MOW" end
    if obj.spec_cultivator ~= nil then return "CULT" end
    return "GEN"
end
-- marker: sredina prednjeg radnog ruba (AI markeri) i straznji marker; rezervno korijen prikljucka
local function implMarkers(obj)
    local l, r, b = call(obj, "getAIMarkers")
    if l ~= nil and r ~= nil then return l, r, b end
    return obj.rootNode, obj.rootNode, obj.rootNode
end
local function markerPos(l, r)
    local lx, _, lz = getWorldTranslation(l)
    local rx, _, rz = getWorldTranslation(r)
    return (lx + rx) * 0.5, (lz + rz) * 0.5
end
local function implWidth(obj)
    local l, r = implMarkers(obj)
    if l ~= nil and r ~= nil and l ~= r then
        local lx, _, lz = getWorldTranslation(l); local rx, _, rz = getWorldTranslation(r)
        return math.sqrt((lx - rx) ^ 2 + (lz - rz) ^ 2)
    end
    return 0
end
local function lowerDurationMs(vehicle, obj, jointIndex)
    local spec = vehicle.spec_attacherJoints
    local jd = spec ~= nil and spec.attacherJoints ~= nil and spec.attacherJoints[jointIndex] or nil
    if jd ~= nil and jd.moveDefaultTime ~= nil and jd.moveDefaultTime > 0 then return jd.moveDefaultTime end
    local sa = obj.spec_attachable
    if sa ~= nil and sa.lowerAnimation ~= nil and obj.spec_animatedVehicle ~= nil then
        local d = call(obj, "getAnimationDuration", sa.lowerAnimation)
        if d ~= nil and d > 0 then return d end
    end
    return 2000
end
local function isLowered(obj)
    local l = call(obj, "getIsLowered", true)
    return l == true
end
-- spusti/digni "kao AI" (aiImplementStartLine/EndLine), rezervno setLoweredAll preko traktora
local function setImplLowered(vehicle, I, lowered)
    local obj = I.object
    I.byUs = g_currentMission.time or 0
    local done = false
    if lowered then
        if type(obj.aiImplementStartLine) == "function" then done = pcall(obj.aiImplementStartLine, obj) end
    else
        if type(obj.aiImplementEndLine) == "function" then done = pcall(obj.aiImplementEndLine, obj) end
    end
    if not done then
        -- rezervno: standardno spustanje preko traktora za taj zglob
        if type(vehicle.setJointMoveDown) == "function" then pcall(vehicle.setJointMoveDown, vehicle, I.joint, lowered, true) end
        if type(obj.setLowered) == "function" then pcall(obj.setLowered, obj, lowered) end
    end
    -- work mode: PTO uz spustanje (red G AUTO)
    if JD.cfg.hmsPto ~= false then
        local pc = obj.spec_powerConsumer
        local needsPto = pc ~= nil and ((pc.neededMaxPtoPower or 0) > 0 or (pc.ptoRpm or 0) > 0)
        if needsPto and type(obj.setIsTurnedOn) == "function" then pcall(obj.setIsTurnedOn, obj, lowered) end
    end
    I.lastLowered = lowered
end
-- radni okretaji (rucni gas) pri spustanju - koristi postojecu funkciju rucnog gasa ako postoji
local function workRpm(vehicle, on)
    local rpm = JD.cfg.hmsWorkRpm or 0
    if rpm <= 0 or JD.setHandThrottle == nil then return end
    local motor = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil
    if motor == nil then return end
    if on then
        motor.jd7810HmsPrevRpm = motor.jd7810HandRpm or 0          -- zapamti vozacev rucni gas
        pcall(JD.setHandThrottle, motor, rpm)
    elseif motor.jd7810HmsPrevRpm ~= nil then
        pcall(JD.setHandThrottle, motor, motor.jd7810HmsPrevRpm)   -- vrati kako je bilo (0 = iskljucen)
        motor.jd7810HmsPrevRpm = nil
    end
end
-- diferencijal (red G AUTO): na uvratini isklj.
local function diffLock(vehicle, on)
    if JD.cfg.hmsDiff == false then return end
    local motor = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil
    if motor == nil then return end
    if on then
        if not motor.jd7810DiffLock then motor.jd7810DiffLock = true; motor.jd7810HmsDiffSet = true end
    elseif motor.jd7810HmsDiffSet then
        motor.jd7810DiffLock = false; motor.jd7810HmsDiffSet = nil     -- iskljuci samo ono sto je HMS ukljucio
    end
end

-- =====================================================================
--  D) GLAVNA PETLJA (poziva se iz Engine.update za nas traktor): zone, predvidjanje, akcije
-- =====================================================================
-- birac V (F / R / TRAKTOR / B): stanje i kruzenje su u Cockpitu (JD.vSelectorState / JD.vSelectorNext, tipka G)
local function vSelectorText(vehicle)
    if JD.vSelectorState ~= nil then
        local _, name = JD.vSelectorState(vehicle)
        return name
    end
    return vehicle.jd7810Both and "BOTH (B)" or "-"
end
local function vehicleHeading(vehicle)
    local dx, _, dz = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
    local L = math.sqrt(dx * dx + dz * dz)
    if L < 1e-6 then return 0, 1 end
    return dx / L, dz / L
end
local function updateWidth(vehicle, H, impls)
    if H.widthManual ~= nil then H.width = H.widthManual; return end
    local w = H.widthAuto or 0
    for _, e in ipairs(impls) do w = math.max(w, implWidth(e.object)) end
    if w > 0.2 then H.width = w end
end
local function updateLightbar(vehicle, H, speedKmh, lowered)
    if H.ab == nil then                       -- v186: A-B postavlja vozac (INFO > F), ne vise samo pri spustanju
        H.offsetCm = nil
        return
    end
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    -- bocna udaljenost do A-B linije, pa do najblize paralelne trake (razmak = sirina)
    local lat = (x - H.ab.x) * (-H.ab.dz) + (z - H.ab.z) * (H.ab.dx)
    local w = math.max(H.width, 0.5)
    local k = math.floor(lat / w + 0.5)
    local off = lat - k * w
    -- predznak u odnosu na smjer voznje (u povratnoj traci se okrene)
    local dx, dz = vehicleHeading(vehicle)
    if dx * H.ab.dx + dz * H.ab.dz < 0 then off = -off end
    H.offsetCm = off * 100
    H.lane = k
end

function JD7810Transmission.updateHms(motor, dt)
    local vehicle = motor.vehicle
    if vehicle == nil then return end
    local H = hmsState(vehicle)
    local t = g_currentMission.time or 0
    H.odo = H.odo or 0
    if H.msgT > 0 then H.msgT = H.msgT - dt; if H.msgT <= 0 then H.msg = ""; H.dirty = true end end
    local speedKmh = JD.U.getSpeedKmh(motor) or 0
    local speedMs = speedKmh / 3.6
    if speedKmh > 0.3 then H.lastRev = (vehicle.movingDirection or 1) < 0 end
    local reverse = H.lastRev == true          -- pri mirovanju zadrzi zadnji smjer (movingDirection titra na 0 km/h)
    local step = speedMs * dt / 1000
    H.odo = H.odo + step
    -- birac B: straznji na istoj liniji (radi i bez HMS-a)
    if H.pendingRear ~= nil then
        H.pendingRear.distLeft = H.pendingRear.distLeft - step
        if H.pendingRear.distLeft <= 0 then
            local I = H.impl[H.pendingRear.object]
            if I ~= nil then setImplLowered(vehicle, I, H.pendingRear.lowered); beep() end
            H.pendingRear = nil
        end
    end
    local vs = vSelectorText(vehicle); if vs ~= H.vSel then H.vSel = vs; H.dirty = true end
    if not H.on then JD.hmsScreen(vehicle, H, dt); return end
    updateFieldRequest(vehicle, H)
    H.zoneT = (H.zoneT or 0) + dt
    local doZones = H.zoneT >= ZONE_PERIOD_MS
    if doZones then H.zoneT = 0 end
    local impls = JD.getImplements(vehicle)
    updateWidth(vehicle, H, impls)
    -- cekanje polja: nista ne radimo dok kontura ne stigne (ili rezervni nacin)
    local anyLowered = false
    local onHeadland = false
    for _, e in ipairs(impls) do
        local obj = e.object
        local I = H.impl[obj]
        if I == nil then
            I = { object = obj, joint = e.joint, front = e.front, kind = implKind(obj), zone = nil, lastLowered = isLowered(obj), byUs = 0, armed = true }
            H.impl[obj] = I
        end
        -- rucni zahvat vozaca: stanje se promijenilo, a nismo mi -> cekaj sljedeci prijelaz
        local lowNow = isLowered(obj)
        if lowNow ~= I.lastLowered and (t - (I.byUs or 0)) > 1500 then
            -- rucno spusteno u radnoj zoni (pocetak prvog prolaza) ili rucno dignuto na uvratini = u skladu s HMS-om -> ostaje naoruzano;
            -- suprotno (dignuto usred polja / spusteno na uvratini) -> cekaj sljedeci prijelaz
            local consistent = (lowNow and I.zone == "WORK") or (not lowNow and I.zone ~= nil and I.zone ~= "WORK")
            I.armed = consistent
            I.pendingLower = nil
            I.lastLowered = lowNow
            say(H, (e.front and "FRONT" or "REAR") .. " MANUAL", 2000)
            if JD.cfg.debug then log(string.format("HMS: manual %s zone=%s armed=%s", lowNow and "DOWN" or "UP", tostring(I.zone), tostring(consistent))) end
        end
        if lowNow then anyLowered = true end
        -- marker + predvidjanje
        local l, r, b = implMarkers(obj)
        local mx, mz = markerPos(l, r)
        local dx, dz = vehicleHeading(vehicle)
        if reverse then dx, dz = -dx, -dz end
        local lowerMs = lowerDurationMs(vehicle, obj, e.joint)
        local ahead = speedMs * lowerMs / 1000 + 0.5
        if I.kind == "SEED" then ahead = math.max(0, speedMs * lowerMs / 1000 - 0.3) end   -- sijacica: tocno na liniji
        if doZones or I.zoneL == nil then
            -- v188: obje odluke po PREDNJEM radnom rubu prikljucka (AI markeri) -> rub obrade = crta uvratine, ravno i
            -- jednako na oba kraja. Spustanje unaprijed za vrijeme spustanja (prikljucak je dolje tocno na crti),
            -- dizanje kad prednji rub prijede crtu.
            I.zoneL, I.dF, I.dB = zoneAt(H, mx + dx * ahead, mz + dz * ahead, dx, dz)
            I.zoneR = zoneAt(H, mx, mz, dx, dz)
        end
        local zoneLower, zoneRaise = I.zoneL, I.zoneR
        local zone = zoneLower
        if lowNow then zone = zoneRaise end       -- spusten: digni na crti; dignut: spusti unaprijed
        if zone ~= "WORK" then onHeadland = true end
        if I.zone == nil then I.zone = zone end
        -- stabilizacija: nova zona vrijedi tek kad se drzi ZONE_STABLE_MS (nazubljen rub, teleport)
        if zone ~= I.zoneCand then I.zoneCand = zone; I.zoneCandT = t end
        if zone ~= I.zone and (t - (I.zoneCandT or t)) >= ZONE_STABLE_MS then
            -- prijelaz zone
            if JD.cfg.debug then log(string.format("HMS: zone %s -> %s (%s, lowered=%s armed=%s v=%.1f)", tostring(I.zone), zone, e.front and "front" or "rear", tostring(lowNow), tostring(I.armed), speedKmh)) end
            if zone == "WORK" and I.zone ~= "WORK" then
                I.armed = true
                if speedKmh > 0.5 and not reverse then
                    setImplLowered(vehicle, I, true); H.passes = H.passes + 1; beep()
                else
                    I.pendingLower = true          -- usli unatrag ili stojeci: spusti cim krene naprijed
                end
            elseif zone ~= "WORK" and I.zone == "WORK" then
                if I.armed and lowNow then setImplLowered(vehicle, I, false); beep() end
                I.armed = true
                I.pendingLower = nil
            end
            I.zone = zone
            H.dirty = true
        end
        -- odgodjeno spustanje: u radnoj zoni, dignut, krenuo naprijed
        if I.pendingLower and I.zone == "WORK" and not lowNow and I.armed and speedKmh > 0.5 and not reverse then
            I.pendingLower = nil
            setImplLowered(vehicle, I, true); H.passes = H.passes + 1; beep()
            if JD.cfg.debug then log("HMS: odgodjeno spustanje (ulaz unatrag -> naprijed)") end
        end
        -- obradjena povrsina (gruba): spusten + naprijed
        if lowNow and not reverse then H.distM = H.distM + step; H.areaHa = H.areaHa + step * math.max(H.width, 0) / 10000 end
    end
    -- work mode: okretaji i diferencijal po stanju
    if anyLowered ~= H.wasLowered then
        workRpm(vehicle, anyLowered)
        H.wasLowered = anyLowered
        H.dirty = true
    end
    if onHeadland ~= H.wasHeadland then
        diffLock(vehicle, not onHeadland and anyLowered)
        H.wasHeadland = onHeadland
    end
    updateLightbar(vehicle, H, speedKmh, anyLowered)
    JD.hmsScreen(vehicle, H, dt)
end

-- =====================================================================
--  E) AKCIJE: LAlt+H (HMS), LAlt+V (oba odmah), V kratki (prednji odmah + straznji na liniji)
-- =====================================================================
function JD7810Transmission.hmsToggle(vehicle, on)
    local H = hmsState(vehicle)
    if on == nil then on = not H.on end
    H.on = on
    H.dirty = true
    if on then
        H.passes = 0; H.areaHa = 0; H.distM = 0; H.impl = {}           -- v186: A-B ostaje (postavlja/brise vozac)
        requestField(vehicle, H)
        say(H, "HMS ON", 2500); log("HMS: ON (polje: " .. tostring(H.fieldText) .. ")")
    else
        workRpm(vehicle, false)
        say(H, "HMS OFF", 2500); log("HMS: OFF")
    end
    beep()
end
function JD7810Transmission.actionHmsToggle(vehicle)
    if isOursVehicle(vehicle) then JD.hmsToggle(vehicle) end
end
-- oba prikljucka odmah (LAlt+V): spusti ako je ijedan dignut, inace digni oba
function JD7810Transmission.actionHmsAll(vehicle)
    if not isOursVehicle(vehicle) then return end
    local H = hmsState(vehicle)
    local impls = JD.getImplements(vehicle)
    if #impls == 0 then return end
    local anyUp = false
    for _, e in ipairs(impls) do if not isLowered(e.object) then anyUp = true end end
    for _, e in ipairs(impls) do
        local I = H.impl[e.object] or { object = e.object, joint = e.joint, front = e.front, kind = implKind(e.object), armed = true }
        H.impl[e.object] = I
        setImplLowered(vehicle, I, anyUp)
    end
    H.pendingRear = nil
    say(H, anyUp and "BOTH DOWN" or "BOTH UP", 1500)
    beep()
end
-- V: ovisi o biracu F / B / R (Cockpit: tipka G kruzi prednji -> straznji -> OBA; kasnije i fizicki prekidac, IC).
--   F ili R  -> standardno (igra dize/spusta odabrani prikljucak)
--   B (OBA)  -> princip s kasnjenjem: prednji odmah, straznji kad prijedje isti razmak (radi i kad HMS nije ukljucen)
local function hmsLowerBoth(self)   -- self = traktor; vraca true ako je V obradjen (OBA s kasnjenjem)
    if isOursVehicle(self) and self.jd7810Both then
        local H = hmsState(self)
        local impls = JD.getImplements(self)
        if #impls == 2 then
            local front, rear = nil, nil
            for _, e in ipairs(impls) do if e.front then front = e else rear = e end end
            if front ~= nil and rear ~= nil then
                local I = H.impl[front.object] or { object = front.object, joint = front.joint, front = true, kind = implKind(front.object), armed = true }
                H.impl[front.object] = I
                local lowered = not isLowered(front.object)
                setImplLowered(self, I, lowered)
                local fl, fr = implMarkers(front.object); local rl, rr = implMarkers(rear.object)
                local fx, fz = markerPos(fl, fr); local rx, rz = markerPos(rl, rr)
                local dx, dz = vehicleHeading(self)
                local dist = (fx - rx) * dx + (fz - rz) * dz          -- razmak markera uzduz voznje
                H.pendingRear = { object = rear.object, distLeft = math.max(0.2, dist), lowered = lowered }
                H.impl[rear.object] = H.impl[rear.object] or { object = rear.object, joint = rear.joint, front = false, kind = implKind(rear.object), armed = true }
                say(H, lowered and "FRONT DOWN, REAR AT LINE" or "FRONT UP, REAR AT LINE", 2000)
                beep()
                return true
            end
        end
    end
    return false
end
local function hmsLowerIntercept(self, superFunc, ...)          -- traktor odabran (samo debug)
    if hmsLowerBoth(self) then return end
    return superFunc(self, ...)
end
-- prikljucak odabran (uobicajeno): Cockpit presrece callbackove prikljucka i zove ovo za polozaj BOTH
JD7810Transmission.hmsLowerBoth = hmsLowerBoth
if AttacherJoints ~= nil and AttacherJoints.actionEventLowerImplement ~= nil then
    AttacherJoints.actionEventLowerImplement = Utils.overwrittenFunction(AttacherJoints.actionEventLowerImplement, hmsLowerIntercept)
else
    log("HMS: AttacherJoints.actionEventLowerImplement nije pronadjen - V kratki radi standardno (provjeriti naziv u LUADOC)")
end

-- tipke (uz postojece u Engine.onRegisterActionEvents): dodajemo svoje u istom hooku
if Motorized ~= nil and Motorized.onRegisterActionEvents ~= nil then
    Motorized.onRegisterActionEvents = Utils.appendedFunction(Motorized.onRegisterActionEvents, function(self, isActiveForInput, isActiveForInputIgnoreSelection)
        local spec = self.spec_motorized
        if not self.isClient or spec == nil or spec.motor == nil or not JD.U.isOurs(spec.motor) then return end
        if not isActiveForInputIgnoreSelection then return end
        local ids = {}
        if InputAction.JD7810_HMS_TOGGLE ~= nil then
            local _, id = self:addActionEvent(spec.actionEvents, InputAction.JD7810_HMS_TOGGLE, self, JD.actionHmsToggle, false, true, false, true, nil)
            table.insert(ids, id)
        end
        if InputAction.JD7810_HMS_ALL ~= nil then
            local _, id = self:addActionEvent(spec.actionEvents, InputAction.JD7810_HMS_ALL, self, JD.actionHmsAll, false, true, false, true, nil)
            table.insert(ids, id)
        end
        for _, id in ipairs(ids) do if id ~= nil then g_inputBinding:setActionEventTextVisibility(id, false) end end
    end)
end

function JD7810Transmission.cycleVSelector(vehicle)
    if JD.vSelectorNext ~= nil and JD.vSelectorNext(vehicle) then
        local H = hmsState(vehicle); H.vSel = vSelectorText(vehicle); H.dirty = true
    end
end

-- =====================================================================
--  F) TERMINAL: cvorovi, font, stranice, tipke
-- =====================================================================
local ROWS = { "A", "B", "C", "D", "E", "F", "G" }
local function gsNodes(vehicle)
    if vehicle.jd7810Gs ~= nil then return vehicle.jd7810Gs end
    local G = { ok = false, bar = {}, row = {}, val = {}, lines = {} }
    vehicle.jd7810Gs = G
    local function node(name)
        if vehicle.i3dMappings == nil or vehicle.i3dMappings[name] == nil then return nil end   -- bez "Index not found" u logu
        local ok, n = pcall(I3DUtil.indexToObject, vehicle.components, name, vehicle.i3dMappings)
        if ok and n ~= nil and n ~= 0 then return n end
        return nil
    end
    G.screen = node("gsScreen")
    if G.screen == nil then if not G.logged then G.logged = true; log("terminal: i3dMapping gsScreen ne postoji (terminal jos nije u modelu) - zaslon iskljucen") end return G end
    for i = 1, 15 do G.bar[i] = node(string.format("gsLightbar_%02d", i)) end
    local fontName = (JD.cfg.hmsFont or 1) >= 0.5 and "GENERIC" or "DIGIT"
    local font = nil
    if g_materialManager ~= nil and g_materialManager.getFontMaterial ~= nil then
        font = g_materialManager:getFontMaterial(fontName, JD.MOD_NAME)
        if font == nil and fontName ~= "DIGIT" then
            log("terminal: font " .. fontName .. " nije dostupan, koristim DIGIT (samo brojke)")
            font = g_materialManager:getFontMaterial("DIGIT", JD.MOD_NAME)
        end
    end
    if font == nil or CharacterLine == nil then log("terminal: font igre nije dostupan - zaslon bez teksta"); return G end
    local size = (JD.cfg.hmsTextSize or 5) / 1000
    local function line(anchor, align, chars, sz, keyName)
        local n = node(anchor)
        if n == nil then return nil end
        local tg = createTransformGroup("jd7810Gs_" .. anchor)
        link(n, tg)
        -- v187: red teksta okomito u ravnini sa sredinom tipke (sidro: Z = dolje po zaslonu)
        local key = keyName ~= nil and node(keyName) or nil
        if key ~= nil and JD.cfg.hmsAlignKeys ~= false then
            local kx, ky, kz = getWorldTranslation(key)
            local _, _, lz = worldToLocal(n, kx, ky, kz)
            if lz ~= nil and math.abs(lz) < 0.03 then setTranslation(tg, 0, 0, lz) end
        end
        -- v159: sidra (prazni objekti iz Blendera) u i3d imaju Y prema vozacu, Z prema dolje -> slova su stajala okomito
        -- na zaslon (vidljiva samo kao crtice). Okret -90 st. oko X: Y = gore po zaslonu, lice slova prema vozacu.
        setRotation(tg, math.rad(JD.cfg.hmsTextRotX or -90), 0, 0)
        local cl = CharacterLine.new(tg, font, chars)
        -- v159: citljivost - font GENERIC je za utisnute tablice (tanka slova + normal mapa = isprekidano na LCD-u)
        if cl.setUseNormalMap ~= nil then cl:setUseNormalMap(false) end            -- ravan tisak kao LCD
        if cl.setFontThickness ~= nil then cl:setFontThickness(JD.cfg.hmsFontThick or 1.8) end
        if cl.setCharacterSpacing ~= nil then cl:setCharacterSpacing(JD.cfg.hmsCharSpace or 0.6) end
        cl:setSizeAndScale(sz or size, 1, 1)
        cl:setTextAlignment(align)
        if keyName ~= nil and cl.setTextVerticalAlignment ~= nil and RenderText.VERTICAL_ALIGN_MIDDLE ~= nil then
            cl:setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
        end
        cl:setColor({ 0.05, 0.06, 0.04, 1 }, nil, 0, 0)
        cl:setText("")
        return { cl = cl, tg = tg, text = "" }
    end
    G.hdr = line("gsHdr", RenderText.ALIGN_CENTER, 16, size * 1.1)
    for _, c in ipairs(ROWS) do
        G.row[c] = line("gsRow" .. c, RenderText.ALIGN_LEFT, 12, nil, "gsKey" .. c)
        G.val[c] = line("gsVal" .. c, RenderText.ALIGN_RIGHT, 10, nil, "gsKey" .. c)
    end
    G.foot = line("gsFoot", RenderText.ALIGN_LEFT, 20)
    G.ok = true
    log("terminal: zaslon spreman (font " .. fontName .. ")")
    return G
end
local function setLine(L, text)
    if L == nil or L.text == text then return end
    L.text = text
    pcall(L.cl.setText, L.cl, text)
end
local function pageRows(H)
    local mode = H.mode
    local val = {}
    local lbl = {}
    if H.page == "RUN" then
        lbl.A, val.A = "HMS", H.on and "ON" or "OFF"
        lbl.B, val.B = "HEADLAND", string.format("%d rows", H.rows)
        lbl.C, val.C = "MODE", mode
        lbl.D, val.D = "WIDTH", fmt1(H.width) .. (H.widthManual and " M" or " A")
        lbl.E, val.E = "PASS", tostring(H.passes)
        lbl.F, val.F = "RPM", string.format("%d", JD.cfg.hmsWorkRpm or 0)
        lbl.G, val.G = "V LIFTS", H.vSel or "-"
    elseif H.page == "SETUP" then
        lbl.A, val.A = "WIDTH MAN", H.widthManual and fmt1(H.widthManual) or "AUTO"
        lbl.B, val.B = "ROWS", tostring(H.rows)
        lbl.C, val.C = "MODE", mode
        lbl.D, val.D = "RPM", string.format("%d", JD.cfg.hmsWorkRpm or 0)
        lbl.E, val.E = "PTO AUTO", JD.cfg.hmsPto ~= false and "YES" or "NO"
        lbl.F, val.F = "DIFF AUTO", JD.cfg.hmsDiff ~= false and "YES" or "NO"
        lbl.G, val.G = "SOUND", JD.cfg.hmsSound ~= false and "YES" or "NO"
    elseif H.page == "HDG" then
        -- v155: zakljucavanje smjera (JD7810Heading.lua) - iste postavke kao ESC > Settings > JOHN DEERE 7810
        local veh = H.vehicle
        local Hh = veh ~= nil and veh.jd7810Head or nil
        local hd = (veh ~= nil and JD.getHeadingDeg ~= nil) and JD.getHeadingDeg(veh) or nil
        local step = JD.cfg.headingStep or 1
        lbl.A, val.A = "LOCK", (Hh ~= nil and Hh.on) and "ON" or "OFF"
        lbl.B, val.B = "HEADING", hd ~= nil and string.format("%05.1f", hd) or "-"
        lbl.C, val.C = "TARGET", (Hh ~= nil and Hh.target ~= nil) and string.format("%05.1f", Hh.target) or "-"
        lbl.D, val.D = "RESOLUTION", step < 0.5 and "EXACT" or string.format("%d DEG", math.floor(step + 0.5))
        lbl.E, val.E = "REFERENCE", (Hh ~= nil and Hh.last ~= nil) and string.format("%03d/%03d", math.floor(Hh.last + 0.5) % 360, math.floor(Hh.last + 180.5) % 360) or "-"
        lbl.F, val.F = "SNAP", string.format("%d DEG", math.floor((JD.cfg.headingSnap or 10) + 0.5))
        lbl.G, val.G = "COMPASS HUD", JD.cfg.compassHud ~= false and "ON" or "OFF"
    else -- INFO
        lbl.A, val.A = "FIELD", H.fieldText or "-"
        lbl.B, val.B = "AREA", string.format("%.2f ha", H.areaHa)
        lbl.C, val.C = "DIST", string.format("%.2f km", H.distM / 1000)
        lbl.D, val.D = "PASS", tostring(H.passes)
        lbl.E, val.E = "LANE", H.lane ~= nil and tostring(H.lane) or "-"
        lbl.F, val.F = "A-B", H.ab ~= nil and "SET (F CLR)" or "NO (F SET)"
        lbl.G, val.G = "VERSION", "HMS " .. JD.HMS_VERSION
    end
    return lbl, val
end
function JD7810Transmission.hmsScreen(vehicle, H, dt)
    local G = gsNodes(vehicle)
    if not G.ok then return end
    H.txtT = (H.txtT or 0) + dt
    local on = motorOn(vehicle)
    if on ~= G.wasOn then G.wasOn = on; H.dirty = true end
    -- svjetlosna traka: svaki okvir (jeftino: 15 setVisibility)
    -- v186: stupac od sredine (sredina = na liniji), strana = kamo skrenuti (hms#lightbarDir), izvan +-7 zadnje polje trepce
    local cm = JD.cfg.hmsLightbarCm or 5
    local dir = (JD.cfg.hmsLightbarDir or -1) < 0 and -1 or 1
    local n = nil
    local Hh = vehicle.jd7810Head                                  -- v155: zakljucan smjer (JD7810Heading.lua)
    if on and Hh ~= nil and Hh.on and Hh.err ~= nil then
        n = math.floor(Hh.err + 0.5) * dir                         -- 1 polje = 1 st. odstupanja smjera
    elseif on and H.on and H.offsetCm ~= nil then
        n = math.floor(H.offsetCm / cm + 0.5) * dir                -- 1 polje = lightbarCm cm
    end
    local key = nil
    if n ~= nil then
        local over = math.abs(n) > 7
        local m = clamp(n, -7, 7)
        local blinkOff = over and (math.floor((g_time or 0) / 250) % 2 == 1)
        key = string.format("%d/%s", m, tostring(blinkOff))
        if key ~= G.segKey then
            for i = 1, 15 do
                local d = i - 8
                local lit = (d == 0) or (m > 0 and d > 0 and d <= m) or (m < 0 and d < 0 and d >= m)
                if blinkOff and d == m then lit = false end
                vis(G.bar[i], lit)
            end
        end
    elseif G.segKey ~= nil then
        for i = 1, 15 do vis(G.bar[i], false) end
    end
    G.segKey = key
    if H.txtT < 100 and not H.dirty then return end       -- tekst najvise 10x u sekundi
    H.txtT = 0; H.dirty = false
    if not on then
        setLine(G.hdr, ""); setLine(G.foot, "")
        for _, c in ipairs(ROWS) do setLine(G.row[c], ""); setLine(G.val[c], "") end
        return
    end
    H.vehicle = vehicle                                            -- v155: za stranicu HDG
    local lbl, val = pageRows(H)
    local hdr
    if H.page == "RUN" then
        local hd = JD.getHeadingDeg ~= nil and JD.getHeadingDeg(vehicle) or nil
        if Hh ~= nil and Hh.on then hdr = string.format("HDG %03d LK %03d", math.floor((hd or 0) + 0.5) % 360, math.floor((Hh.target or 0) + 0.5) % 360)
        elseif H.on and H.offsetCm ~= nil then hdr = string.format("%+d cm", math.floor(H.offsetCm + 0.5))
        elseif H.on then hdr = H.fieldText or ""
        elseif hd ~= nil then hdr = string.format("HMS OFF  HDG %03d", math.floor(hd + 0.5) % 360)
        else hdr = "HMS OFF" end
    elseif H.page == "HDG" then
        local hd2 = JD.getHeadingDeg ~= nil and JD.getHeadingDeg(vehicle) or nil
        if Hh ~= nil and Hh.on then hdr = string.format("HDG %03d LK %03d", math.floor((hd2 or 0) + 0.5) % 360, math.floor((Hh.target or 0) + 0.5) % 360)
        else hdr = string.format("HDG %03d", math.floor((hd2 or 0) + 0.5) % 360) end
    else hdr = H.page end
    setLine(G.hdr, hdr)
    for _, c in ipairs(ROWS) do
        local mark = (H.row == c) and ">" or ""
        setLine(G.row[c], mark .. (lbl[c] or ""))
        local v = val[c] or ""
        if H.row == c and H.input ~= "" then v = H.input .. "_" end
        setLine(G.val[c], v)
    end
    local foot = H.msg
    if foot == "" then
        if H.page == "RUN" then foot = H.on and ("PAGE SETUP INFO  " .. (H.mode == "MANUAL" and "DRIVER TURNS" or "SEMI-AUTO")) or "RUN = HMS ON"
        elseif H.page == "SETUP" or H.page == "HDG" then foot = "A-G SELECT, DIGITS ENTER, CLR"
        else foot = "RUN = BACK" end
    end
    setLine(G.foot, foot)
end

-- ---- tipke: logika ----
local function applyRowAction(vehicle, H, c)
    H.dirty = true
    if H.page == "RUN" then
        if c == "A" then JD.hmsToggle(vehicle); return end
        if c == "B" then H.row = "B"; return end
        if c == "C" then H.mode = (H.mode == "MANUAL") and "SEMI-AUTO" or "MANUAL"; JD.cfg.hmsMode = H.mode == "SEMI-AUTO" and 1 or 0; say(H, H.mode == "SEMI-AUTO" and "SEMI-AUTO: LABEL ONLY FOR NOW" or "MANUAL", 2500); return end
        if c == "D" then H.row = "D"; return end
        if c == "E" then H.passes = 0; say(H, "PASSES = 0", 1500); return end
        if c == "F" then H.row = "F"; return end
        if c == "G" then JD.cycleVSelector(vehicle); return end     -- F -> B -> R (isto kao tipka G u igri)
    elseif H.page == "SETUP" then
        if c == "A" then if H.widthManual ~= nil then H.widthManual = nil; say(H, "WIDTH AUTO", 1500) else H.row = "A" end return end
        if c == "B" then H.row = "B"; return end
        if c == "C" then H.mode = (H.mode == "MANUAL") and "SEMI-AUTO" or "MANUAL"; JD.cfg.hmsMode = H.mode == "SEMI-AUTO" and 1 or 0; return end
        if c == "D" then H.row = "D"; return end
        if c == "E" then JD.cfg.hmsPto = not (JD.cfg.hmsPto ~= false); return end
        if c == "F" then JD.cfg.hmsDiff = not (JD.cfg.hmsDiff ~= false); return end
        if c == "G" then JD.cfg.hmsSound = not (JD.cfg.hmsSound ~= false); return end
    elseif H.page == "HDG" then
        local save = function() if JD.saveSteer ~= nil then pcall(JD.saveSteer) end end
        if c == "A" then if JD.toggleHeadingLock ~= nil then JD.toggleHeadingLock(vehicle) end; return end
        if c == "B" then say(H, "HEADING: DISPLAY ONLY", 1500); return end
        if c == "C" or c == "E" or c == "F" then H.row = c; return end
        if c == "D" then
            local steps = { 0.1, 1, 5, 15, 45 }
            local cur, idx = JD.cfg.headingStep or 1, 1
            for i, f in ipairs(steps) do if math.abs(f - cur) < 0.05 then idx = i end end
            JD.cfg.headingStep = steps[idx % #steps + 1]; save()
            say(H, "RESOLUTION " .. (JD.cfg.headingStep < 0.5 and "EXACT" or string.format("%d DEG", JD.cfg.headingStep)), 1500)
            return
        end
        if c == "G" then JD.cfg.compassHud = not (JD.cfg.compassHud ~= false); save(); return end
    else
        if c == "B" or c == "C" or c == "D" then H.areaHa = 0; H.distM = 0; H.passes = 0; say(H, "COUNTERS = 0", 1500) end
        if c == "F" then                                               -- v186: A-B postavi ovdje i sada / obrisi
            if H.ab == nil then
                local x, _, z = getWorldTranslation(vehicle.rootNode)
                local dx, dz = vehicleHeading(vehicle)
                H.ab = { x = x, z = z, dx = dx, dz = dz }
                say(H, "A-B LINE SET", 2000)
            else
                H.ab = nil; H.offsetCm = nil; say(H, "A-B CLEARED", 1500)
            end
        end
    end
end
local function commitInput(vehicle, H)
    local v = tonumber(H.input)
    H.input = ""
    if v == nil or H.row == nil then H.row = nil; return end
    local c = H.row
    if (H.page == "RUN" and c == "B") or (H.page == "SETUP" and c == "B") then H.rows = clamp(math.floor(v + 0.5), 1, 6); JD.cfg.hmsRows = H.rows
    elseif (H.page == "RUN" and c == "D") or (H.page == "SETUP" and c == "A") then H.widthManual = clamp(v, 0.5, 30); H.width = H.widthManual
    elseif (H.page == "RUN" and c == "F") or (H.page == "SETUP" and c == "D") then JD.cfg.hmsWorkRpm = clamp(math.floor(v + 0.5), 0, 2300)
    elseif H.page == "HDG" and c == "C" then if JD.headingSetTarget ~= nil then JD.headingSetTarget(vehicle, v % 360) end
    elseif H.page == "HDG" and c == "E" then if JD.headingSetReference ~= nil then JD.headingSetReference(vehicle, v % 360) end
    elseif H.page == "HDG" and c == "F" then JD.cfg.headingSnap = clamp(math.floor(v + 0.5), 0, 45); if JD.saveSteer ~= nil then pcall(JD.saveSteer) end
    end
    H.row = nil
    H.dirty = true
    say(H, "SAVED", 1200)
end
function JD7810Transmission.gsKey(vehicle, key)
    if not isOursVehicle(vehicle) then return end
    local H = hmsState(vehicle)
    H.dirty = true
    beep()
    if key == "PAGE" then
        H.row = nil; H.input = ""
        H.page = (H.page == "RUN") and "SETUP" or (H.page == "SETUP" and "INFO") or (H.page == "INFO" and "HDG") or "RUN"
    elseif key == "SETUP" then H.page = "SETUP"; H.row = nil; H.input = ""
    elseif key == "INFO" then H.page = "INFO"; H.row = nil; H.input = ""
    elseif key == "RUN" then
        if H.page == "RUN" and not H.on then JD.hmsToggle(vehicle, true) end
        H.page = "RUN"; H.row = nil; H.input = ""
    elseif key == "CLR" then
        if H.input ~= "" then H.input = ""
        elseif H.page == "HDG" and H.row == "E" then
            if JD.headingSetReference ~= nil then JD.headingSetReference(vehicle, nil) end
            H.row = nil; say(H, "REFERENCE CLEARED", 1500)
        else H.row = nil end
    elseif key == "DOT" then
        if H.row ~= nil and not string.find(H.input, "%.") then H.input = (H.input == "" and "0" or H.input) .. "." end
    elseif key == "BRIGHT" then
        say(H, "BRIGHTNESS: BACKLIGHT AUTO", 1500)
    elseif #key == 1 and key >= "0" and key <= "9" then
        if H.row ~= nil then
            if #H.input < 6 then H.input = H.input .. key end
            -- potvrda: unos se primjenjuje kad se pritisne isto slovo reda ili RUN; ovdje odmah ako je cijeli broj redova (1 znamenka)
            if ((H.page == "RUN" or H.page == "SETUP") and H.row == "B") then commitInput(vehicle, H) end
        end
    elseif #key == 1 and key >= "A" and key <= "G" then
        if H.row == key and H.input ~= "" then commitInput(vehicle, H)
        elseif H.row == key then H.row = nil
        else H.input = ""; applyRowAction(vehicle, H, key) end
    end
end

-- Interactive Control: funkcije tipki terminala
function JD7810Transmission.registerIcHms()
    local env = _G["FS25_interactiveControl"]
    local IF = env ~= nil and env.InteractiveFunctions or nil
    if IF == nil or IF.addFunction == nil then return false end
    if IF.FUNCTION_ID ~= nil and IF.FUNCTION_ID["JD7810_GS_PAGE"] ~= nil then return true end
    local keys = { "A", "B", "C", "D", "E", "F", "G", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "DOT", "CLR", "PAGE", "SETUP", "INFO", "RUN", "BRIGHT" }
    for _, k in ipairs(keys) do
        IF.addFunction("JD7810_GS_" .. k, { posFunc = function(target, data, noEventSend)
            if noEventSend then return end
            JD.gsKey(target, k)
        end })
    end
    log("Interactive Control: tipke terminala registrirane (" .. #keys .. ")")
    return true
end
pcall(JD.registerIcHms)
if JD.registerIC ~= nil then
    JD.registerIC = Utils.appendedFunction(JD.registerIC, function() pcall(JD.registerIcHms) end)   -- Core.loadMap zove registerIC
end

-- konzola
function JD7810Transmission:consoleHms(arg)
    local v = g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil and g_localPlayer:getCurrentVehicle() or nil
    if v == nil or not isOursVehicle(v) then return "HMS: sit in the 7810" end
    if arg == "on" then JD.hmsToggle(v, true) elseif arg == "off" then JD.hmsToggle(v, false) end
    local H = hmsState(v)
    local zs = {}
    for _, I in pairs(H.impl) do
        table.insert(zs, string.format("%s %s ahead %s behind %s", I.front and "front" or "rear", tostring(I.zone),
            I.dF ~= nil and string.format("%.1f m", I.dF) or "-", I.dB ~= nil and string.format("%.1f m", I.dB) or "-"))
    end
    return string.format("HMS %s | field %s | width %.2f | rows %d | headland %.1f m | passes %d | offset %s cm | A-B %s | %s", H.on and "ON" or "OFF", H.fieldText or "-", H.width, H.rows,
        H.rows * math.max(H.width, 1.0), H.passes, H.offsetCm and string.format("%+.0f", H.offsetCm) or "-", H.ab and "yes" or "no", #zs > 0 and table.concat(zs, "; ") or "no implement")
end
table.insert(JD.COMMANDS, { "jd7810Hms", "HMS state / on / off", "consoleHms", "[on|off]" })

-- postavke ponovno (datoteka je procitana prije nego je ovaj modul dodao svoje kljuceve)
pcall(JD.loadSettings)
log("HMS modul v" .. JD.HMS_VERSION .. " ucitan")
