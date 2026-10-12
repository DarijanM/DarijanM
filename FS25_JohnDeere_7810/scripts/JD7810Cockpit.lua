-- =====================================================================
--  JD7810Cockpit.lua   v8.3  (birac V: PREDNJI -> STRAZNJI -> TRAKTOR -> OBA na tipki G)
--  (prije: v8.1)  (FS25 - osobna upotreba, Darijan)
--  kabina: konzola prikljucaka (SCV I-III, podizac, HMS), IVT poluga i gumbi (birac, Field Cruise)
--  v8.1: podjela JD7810Transmission.lua v8.0 na module - kod premjesten
--        bez promjene ponasanja.
--  v8.2: rucice sva tri mjenjaca prate utor kulise (graf utora + IK), Powershift rucica animirana. Redoslijed ucitavanja u modDesc.xml:
--        Core, Transmission, Engine, PTO, Display, PerformanceMonitor, AgroGsm, Cockpit
-- =====================================================================

local JD = JD7810Transmission
local clamp = JD.U.clamp
local getSpeedKmh = JD.U.getSpeedKmh
local isOurs = JD.U.isOurs
local log = JD.U.log
local setEvent = JD.U.setEvent

-- =====================================================================
--  M) KONZOLA PRIKLJUCAKA: SCV I-III, rucica podizaca, HMS klackalica
--     + treci izbor "OBA" na tipki za odabir prikljucka (G) -> V spusta/dize oba
--     Sve u pcall zastiti: ako se neka funkcija igre ne poklopi, igra radi normalno,
--     a jd7810Debug ispise sto nije pronadeno.
-- =====================================================================
JD7810Transmission.CTRL_IDS = { scv1 = "scvLever1Rot", scv2 = "scvLever2Rot", scv3 = "scvLever3Rot",
                                hitch = "hitchLeverRot", hms = "hmsSwitchRot" }
local SCV = { raise = -9, lower = 9, float = 15, detent = -9 }
local HITCH_DOWN, HMS_DEG = 12, 10

local function dbg(fmt, ...)
    if JD7810Transmission.cfg.debug then log("JD7810 konzola: " .. string.format(fmt, ...)) end
end

local function ctrlNodes(vehicle)
    if vehicle.jd7810Ctrl == nil then
        vehicle.jd7810Ctrl = { nodes = {}, ang = {}, pulse = {}, last = {} }
        for key, id in pairs(JD7810Transmission.CTRL_IDS) do
            local ok, n = pcall(I3DUtil.indexToObject, vehicle.components, id, vehicle.i3dMappings)
            if ok and n ~= nil and n ~= 0 then vehicle.jd7810Ctrl.nodes[key] = n else dbg("nema cvora %s", id) end
        end
    end
    return vehicle.jd7810Ctrl
end

-- popis prikljucaka: objekt, sprijeda/straga, trozglobni
function JD7810Transmission.getImplements(vehicle)
    local out = {}
    local spec = vehicle.spec_attacherJoints
    if spec == nil or spec.attachedImplements == nil then return out end
    for _, impl in pairs(spec.attachedImplements) do
        local jd = spec.attacherJoints ~= nil and spec.attacherJoints[impl.jointDescIndex] or nil
        local front, threePoint = false, false
        if jd ~= nil and jd.jointTransform ~= nil then
            local ok, _, _, z = pcall(localToLocal, jd.jointTransform, vehicle.rootNode, 0, 0, 0)
            front = ok and z ~= nil and z > 0
            if AttacherJoints ~= nil and AttacherJoints.JOINTTYPE_IMPLEMENT ~= nil then
                threePoint = jd.jointType == AttacherJoints.JOINTTYPE_IMPLEMENT
            end
        end
        table.insert(out, { object = impl.object, joint = impl.jointDescIndex, front = front, threePoint = threePoint })
    end
    return out
end

local function call(obj, fname, ...)
    if obj ~= nil and type(obj[fname]) == "function" then
        local ok, r = pcall(obj[fname], obj, ...)
        if ok then return r end
    end
    return nil
end

-- stanje prikljucaka -> ciljni kutevi rucica
local function controlTargets(vehicle, C, dt)
    local t = { scv1 = 0, scv2 = 0, scv3 = 0, hitch = 0, hms = 0 }
    local now = g_time or 0
    for _, im in ipairs(JD7810Transmission.getImplements(vehicle)) do
        local o = im.object
        local key = tostring(o)
        local L = C.last[key] or {}
        -- 1) sklapanje -> SCV I (dok traje animacija)
        local ft = call(o, "getFoldAnimTime")
        if ft ~= nil and L.fold ~= nil and math.abs(ft - L.fold) > 1e-5 then
            t.scv1 = (ft > L.fold) and SCV.lower or SCV.raise
        end
        L.fold = ft
        -- 2) spusten/podignut
        local low = call(o, "getIsLowered", true)
        if low ~= nil then
            if L.low ~= nil and low ~= L.low then C.pulse[key .. "low"] = now + 900 end
            local moving = (C.pulse[key .. "low"] or 0) > now
            if im.threePoint and not im.front then
                t.hitch = low and HITCH_DOWN or 0                         -- polozajna rucica podizaca
            elseif not im.threePoint then
                if moving then t.scv2 = low and SCV.lower or SCV.raise
                elseif low then t.scv2 = SCV.float end                    -- spusten vuceni stroj: plivajuci polozaj
            end
            L.low = low
        end
        -- 3) SCV III automatski prema prikljucku
        local sp = o.spec_trailer
        if sp ~= nil and sp.tipState ~= nil and Trailer ~= nil and Trailer.TIPSTATE_CLOSED ~= nil and sp.tipState ~= Trailer.TIPSTATE_CLOSED then
            t.scv3 = SCV.raise                                             -- kipanje: drzi dok traje
        end
        local pl = o.spec_plow
        if pl ~= nil and pl.rotationMax ~= nil then
            if L.plow ~= nil and pl.rotationMax ~= L.plow then C.pulse[key .. "plow"] = now + 1200 end
            L.plow = pl.rotationMax
            if (C.pulse[key .. "plow"] or 0) > now then t.scv3 = SCV.lower end
        end
        local rm = o.spec_ridgeMarker
        if rm ~= nil and rm.ridgeMarkerState ~= nil then
            if L.rm ~= nil and rm.ridgeMarkerState ~= L.rm then C.pulse[key .. "rm"] = now + 700 end
            L.rm = rm.ridgeMarkerState
            if (C.pulse[key .. "rm"] or 0) > now then t.scv3 = SCV.lower end
        end
        if o.spec_sowingMachine ~= nil and call(o, "getIsTurnedOn") == true and t.scv3 == 0 then
            t.scv3 = SCV.detent                                            -- hidraulicki motor ventilatora: zaskocni polozaj
        end
        C.last[key] = L
    end
    -- HMS: odabrani prikljucak (sprijeda / oba / straga)
    if vehicle.jd7810Both then
        t.hms = 0
    else
        local sel = call(vehicle, "getSelectedVehicle")                 -- FS25: odabrano vozilo (prikljucak)
        local front = nil
        if sel ~= nil and not vehicle.jd7810SelTractor then
            for _, im in ipairs(JD7810Transmission.getImplements(vehicle)) do
                if im.object == sel then front = im.front end
            end
        end
        if front == true then t.hms = HMS_DEG elseif front == false then t.hms = -HMS_DEG end
    end
    return t
end

-- V (LOWER_IMPLEMENT): u FS25 sve staze tipke V zavrsavaju na traktoru (AttacherJoints instance funkcije
-- handleLowerImplementEvent -> handleLowerImplementByAttacherJointIndex). Funkcije se kopiraju u vozilo pri
-- registraciji tipa, zato zamjena u tablici AttacherJoints ne djeluje -> omotavamo NA INSTANCI nasega traktora.
-- TRACTOR: blokira se samo handleLowerImplementEvent (tipka V); IC rucica podizaca i HMS (setJointMoveDown) rade.
-- Ako handleLowerImplementEvent ne postoji, blokira se ByAttacherJointIndex. Debug log javlja koja je pozvana.
local function ensureLowerHook(vehicle)
    if vehicle.jd7810LowerHooked then return end
    vehicle.jd7810LowerHooked = true
    local hasEvent = type(vehicle.handleLowerImplementEvent) == "function"
    local names = {}
    for _, fname in ipairs({ "handleLowerImplementEvent", "handleLowerImplementByAttacherJointIndex" }) do
        local orig = vehicle[fname]
        if type(orig) == "function" then
            local blocks = (fname == "handleLowerImplementEvent") or not hasEvent
            vehicle[fname] = function(self, ...)
                dbg("V: %s", fname)
                if blocks and self.jd7810SelTractor then
                    setEvent("V selector: TRACTOR - no implement selected"); return
                end
                if blocks and self.jd7810Both and JD7810Transmission.hmsLowerBoth ~= nil and JD7810Transmission.hmsLowerBoth(self) then return end
                return orig(self, ...)
            end
            table.insert(names, fname)
        end
    end
    dbg("V: instanca omotana: %s", #names > 0 and table.concat(names, ", ") or "NISTA (V radi standardno)")
end

function JD7810Transmission.updateConsoleControls(motor, dt)
    local vehicle = motor.vehicle
    if vehicle == nil then return end
    pcall(ensureLowerHook, vehicle)
    pcall(vSelKnobUpdate, vehicle, dt)                 -- klizni prekidac biraca V
    local C = ctrlNodes(vehicle)
    if next(C.nodes) == nil then return end
    local ok, t = pcall(controlTargets, vehicle, C, dt)
    if not ok then dbg("greska: %s", tostring(t)); return end
    local rate = math.rad(140) * dt / 1000
    for key, node in pairs(C.nodes) do
        local target = math.rad(t[key] or 0)
        local a = C.ang[key] or 0
        a = a + math.max(-rate, math.min(rate, target - a))
        C.ang[key] = a
        setRotation(node, a * (JD7810Transmission.cfg.consoleDir or 1), 0, 0)
    end
end

-- ---- odabir "OBA" na tipki G i spustanje oba na V ----
local function implCount(vehicle) return #JD7810Transmission.getImplements(vehicle) end
local function isOursVehicle(vehicle)
    return vehicle ~= nil and vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor ~= nil and isOurs(vehicle.spec_motorized.motor)
end
function JD7810Transmission.toggleBoth(vehicle)
    if implCount(vehicle) < 2 then vehicle.jd7810Both = false; return false end
    vehicle.jd7810Both = not vehicle.jd7810Both
    setEvent(vehicle.jd7810Both and "Implement: BOTH (V lowers/raises both)" or "Implement: single selection")
    return true
end
-- akcija "oba prikljucka" (sada samo preko G; numpad 4 je prethodni prikaz monitora)
function JD7810Transmission.actionImplementBoth(vehicle)
    JD7810Transmission.toggleBoth(vehicle)
end
-- presretanje odabira prikljucka (G): PREDNJI -> STRAZNJI -> TRAKTOR -> OBA -> PREDNJI ... (Darijan, 6.10.: birac F/B/R + traktor)
--   "OBA" = jd7810Both (V radi po principu s kasnjenjem u JD7810Hms.lua, rezervno sve odjednom dolje).
--   Koristi Vehicle:getSelectedVehicle / setSelectedVehicle (FS25 Vehicle.lua).
-- FS25 API (Vehicle.lua): getSelectedVehicle() / setSelectedVehicle(vehicle); kruzenje = Vehicle.actionEventToggleSelection(+Reverse).
-- Traktor sam nije "selectable" u igri (samo u debug nacinu) -> polozaj TRAKTOR je nasa zastavica jd7810SelTractor (V tada ne radi nista).
local function selectedObject(vehicle)
    return call(vehicle, "getSelectedVehicle")
end
local function selectObject(vehicle, obj)
    if type(vehicle.setSelectedVehicle) ~= "function" then return false end
    local ok = pcall(vehicle.setSelectedVehicle, vehicle, obj)
    return ok and selectedObject(vehicle) == obj
end
function JD7810Transmission.vSelectorOrder(vehicle)
    local front, rear = nil, nil
    for _, e in ipairs(JD7810Transmission.getImplements(vehicle)) do
        if e.front then front = front or e.object else rear = rear or e.object end
    end
    local order = {}
    if front ~= nil then table.insert(order, { name = "FRONT (F)", obj = front }) end
    if rear ~= nil then table.insert(order, { name = "REAR (R)", obj = rear }) end
    table.insert(order, { name = "TRACTOR", tractor = true })
    if front ~= nil and rear ~= nil then table.insert(order, { name = "BOTH (B)", both = true }) end
    return order
end
-- trenutni polozaj biraca (indeks u redoslijedu) i tekst
function JD7810Transmission.vSelectorState(vehicle)
    local order = JD7810Transmission.vSelectorOrder(vehicle)
    if vehicle.jd7810Both then
        for i, o in ipairs(order) do if o.both then return i, o.name, order end end
    end
    if vehicle.jd7810SelTractor then
        for i, o in ipairs(order) do if o.tractor then return i, o.name, order end end
    end
    local cur = selectedObject(vehicle)
    for i, o in ipairs(order) do if o.obj ~= nil and o.obj == cur then return i, o.name, order end end
    return 0, "?", order
end
local function applySel(vehicle, o)
    vehicle.jd7810Both = o.both == true
    vehicle.jd7810SelTractor = o.tractor == true
    if o.obj ~= nil then
        if not selectObject(vehicle, o.obj) then return false end
    end
    setEvent("V selector: " .. o.name)
    return true
end
-- sljedeci / prethodni polozaj; vraca true ako je uspjelo (inace poziva originalni odabir igre)
function JD7810Transmission.vSelectorNext(vehicle, dir)
    local i, _, order = JD7810Transmission.vSelectorState(vehicle)
    if #order < 2 then return false end
    dir = dir or 1
    local idx = ((i - 1 + dir) % #order) + 1
    if i == 0 then idx = 1 end
    return applySel(vehicle, order[idx])
end
-- postavi birac na zadani polozaj 1..4 (IC: klik na ikonu; terminal)
function JD7810Transmission.vSelectorSet(vehicle, idx)
    local _, _, order = JD7810Transmission.vSelectorState(vehicle)
    local o = order[idx]
    if o == nil then return false end
    return applySel(vehicle, o)
end
JD7810Transmission.selectHooks = {}
if Vehicle ~= nil and type(Vehicle.actionEventToggleSelection) == "function" then
    Vehicle.actionEventToggleSelection = Utils.overwrittenFunction(Vehicle.actionEventToggleSelection, function(self, superFunc, ...)
        if isOursVehicle(self) then self.jd7810Both = false; self.jd7810SelTractor = false end   -- v185: G = izbor igre (svi prikljucci)
        return superFunc(self, ...)
    end)
    table.insert(JD7810Transmission.selectHooks, "Vehicle.actionEventToggleSelection")
    if type(Vehicle.actionEventToggleSelectionReverse) == "function" then
        Vehicle.actionEventToggleSelectionReverse = Utils.overwrittenFunction(Vehicle.actionEventToggleSelectionReverse, function(self, superFunc, ...)
            if isOursVehicle(self) then self.jd7810Both = false; self.jd7810SelTractor = false end
            return superFunc(self, ...)
        end)
        table.insert(JD7810Transmission.selectHooks, "Vehicle.actionEventToggleSelectionReverse")
    end
    dbg("presretnuto: %s", table.concat(JD7810Transmission.selectHooks, ", "))
else
    log("birac V: Vehicle.actionEventToggleSelection nije pronadjen - tipka G radi kao u igri")
end
-- V: kad je odabrano OBA, spusti/digni sve prikljucke
if AttacherJoints ~= nil and type(AttacherJoints.actionEventLowerImplement) == "function" then
    local origLower = AttacherJoints.actionEventLowerImplement
    AttacherJoints.actionEventLowerImplement = function(self, ...)
        if self.jd7810SelTractor and isOursVehicle(self) then setEvent("V selector: TRACTOR - no implement selected"); return end
        if self.jd7810Both and isOursVehicle(self) and implCount(self) >= 2 then
            if type(AttacherJoints.actionEventLowerAllImplements) == "function" then
                local ok = pcall(AttacherJoints.actionEventLowerAllImplements, self, ...)
                if ok then return end
            end
            -- rucno: svi zglobovi u isti smjer (prema prvom)
            local ims = JD7810Transmission.getImplements(self); local target = nil
            for _, im in ipairs(ims) do
                local down = call(self, "getJointMoveDown", im.joint)
                if target == nil then target = not down end
                call(self, "setJointMoveDown", im.joint, target, false)
            end
            return
        end
        return origLower(self, ...)
    end
end
-- V kad je odabran PRIKLJUCAK (uobicajeno): igra zove callback specijalizacije PRIKLJUCKA (self = prikljucak).
-- Naziv nije pouzdano poznat (Attachable.actionEventLowerImplement u FS25 NE postoji) -> presrecemo sve
-- actionEvent* funkcije s "Lower" ili "FoldMiddle" u specijalizacijama prikljucaka; u debug nacinu log javlja koja je pozvana.
local function rootOf(obj)
    local r = obj.rootVehicle
    if r == nil and type(obj.getRootVehicle) == "function" then r = obj:getRootVehicle() end
    return r
end
JD7810Transmission.rootOf = rootOf
do
    local specs = { Attachable = Attachable, Foldable = Foldable, Plow = Plow, Pickup = Pickup, Cutter = Cutter,
        Cultivator = Cultivator, SowingMachine = SowingMachine, Sprayer = Sprayer, Mower = Mower, Subsoiler = Subsoiler,
        Weeder = Weeder, Roller = Roller, Leveler = Leveler, Tedder = Tedder, Windrower = Windrower, Baler = Baler }
    local wrapped = {}
    for sName, tbl in pairs(specs) do
        if type(tbl) == "table" then
            local names = {}
            for k, f in pairs(tbl) do
                if type(f) == "function" and type(k) == "string" and k:find("^actionEvent") and (k:find("Lower") or k:find("FoldMiddle")) then
                    table.insert(names, k)
                end
            end
            for _, k in ipairs(names) do
                local full = sName .. "." .. k
                tbl[k] = Utils.overwrittenFunction(tbl[k], function(self, superFunc, ...)
                    local root = rootOf(self)
                    if root ~= nil and root ~= self and isOursVehicle(root) then
                        dbg("V: %s", full)
                        if root.jd7810SelTractor then setEvent("V selector: TRACTOR - no implement selected"); return end
                        if root.jd7810Both and JD7810Transmission.hmsLowerBoth ~= nil and JD7810Transmission.hmsLowerBoth(root) then return end
                    end
                    return superFunc(self, ...)
                end)
                table.insert(wrapped, full)
            end
        end
    end
    dbg("presretnuto (V prikljucka): %s", #wrapped > 0 and table.concat(wrapped, ", ") or "NISTA")
end

JD7810Transmission.GATE_AQ = {
    nodes = {
        chP = { -18.098, 28.045, -4.1 }, chA = { 1.966, 32.074, -4.1 }, chB = { 21.276, 35.952, -4.1 }, N = { 30.939, 37.892, -4.1 },
        chC = { 40.61, 39.834, -4.1 }, chD = { 59.976, 43.724, -4.1 }, chE = { 79.369, 47.618, -4.1 }, A = { -7.943, 81.345, -4.1 },
        B = { 31.173, -13.31, -4.1 }, C = { 30.705, 89.181, -4.1 }, D = { 69.87, -5.615, -4.1 }, E = { 69.467, 97.043, -4.1 },
        Pk = { -8.425, -20.006, -4.1 }, P = { 1.8, -20, -4.1 },
    },
    edges = {
        { "chP", "chA" }, { "chA", "chB" }, { "chB", "N" }, { "N", "chC" }, { "chC", "chD" }, { "chD", "chE" }, { "chA", "A" }, { "chB", "B" },
        { "chC", "C" }, { "chD", "D" }, { "chE", "E" }, { "chP", "Pk" }, { "Pk", "P" },
    },
}
JD7810Transmission.GATE_PS = {
    nodes = {
        HL = { -17.6, -27, 0.75 }, HR = { -2.4, -27, 0.75 }, HU = { -10, -19.4, 0.75 }, hl1 = { -15.633, -26.741, 0.75 },
        hl2 = { -13.8, -25.982, 0.75 }, hl3 = { -12.226, -24.774, 0.75 }, hl4 = { -11.018, -23.2, 0.75 }, hl5 = { -10.259, -21.367, 0.75 },
        hr1 = { -4.367, -26.741, 0.75 }, hr2 = { -6.2, -25.982, 0.75 }, hr3 = { -7.774, -24.774, 0.75 }, hr4 = { -8.982, -23.2, 0.75 },
        hr5 = { -9.741, -21.367, 0.75 }, Na = { -36.4, -27, 0.75 }, Nb = { -44, -34.6, 0.75 }, n1 = { -38.367, -27.259, 0.75 },
        n2 = { -40.2, -28.018, 0.75 }, N = { -41.774, -29.226, 0.75 }, n4 = { -42.982, -30.8, 0.75 }, n5 = { -43.741, -32.633, 0.75 },
        Ca = { -44, -51.4, 0.75 }, Cb = { -36.4, -59, 0.75 }, c1 = { -43.741, -53.367, 0.75 }, c2 = { -42.982, -55.2, 0.75 },
        c3 = { -41.774, -56.774, 0.75 }, c4 = { -40.2, -57.982, 0.75 }, c5 = { -38.367, -58.741, 0.75 }, P = { -20, -59, 0.75 },
        Ra = { 10.4, -27, 0.75 }, Rb = { 18, -34.6, 0.75 }, r1 = { 12.367, -27.259, 0.75 }, r2 = { 14.2, -28.018, 0.75 },
        r3 = { 15.774, -29.226, 0.75 }, r4 = { 16.982, -30.8, 0.75 }, r5 = { 17.741, -32.633, 0.75 }, R1 = { 18, -36.95, 0.75 },
        R2 = { 18, -41.963, 0.75 }, R3 = { 18, -46.976, 0.75 }, R4 = { 18, -51.989, 0.75 }, R5 = { 18, -57.002, 0.75 }, R6 = { 18, -62.015, 0.75 },
        R7 = { 18, -67.028, 0.75 }, F1 = { -10, -9.08, 0.75 }, F2 = { -10, -3.179, 0.75 }, F3 = { -10, 2.722, 0.75 }, F4 = { -10, 8.623, 0.75 },
        F5 = { -10, 14.524, 0.75 }, F6 = { -10, 20.426, 0.75 }, F7 = { -10, 26.327, 0.75 }, F8 = { -10, 32.228, 0.75 }, F9 = { -10, 38.129, 0.75 },
        F10 = { -10, 44.03, 0.75 }, F11 = { -10, 49.931, 0.75 }, F12 = { -10, 55.832, 0.75 }, F13 = { -10, 61.733, 0.75 },
        F14 = { -10, 67.634, 0.75 }, F15 = { -10, 73.535, 0.75 }, F16 = { -10, 79.436, 0.75 }, F17 = { -10, 85.338, 0.75 },
        F18 = { -10, 91.239, 0.75 }, F19 = { -10, 97.14, 0.75 },
    },
    edges = {
        { "HL", "HR" }, { "HL", "hl1" }, { "hl1", "hl2" }, { "hl2", "hl3" }, { "hl3", "hl4" }, { "hl4", "hl5" }, { "hl5", "HU" }, { "HR", "hr1" },
        { "hr1", "hr2" }, { "hr2", "hr3" }, { "hr3", "hr4" }, { "hr4", "hr5" }, { "hr5", "HU" }, { "HL", "Na" }, { "Na", "n1" }, { "n1", "n2" },
        { "n2", "N" }, { "N", "n4" }, { "n4", "n5" }, { "n5", "Nb" }, { "Nb", "Ca" }, { "Ca", "c1" }, { "c1", "c2" }, { "c2", "c3" }, { "c3", "c4" },
        { "c4", "c5" }, { "c5", "Cb" }, { "Cb", "P" }, { "HR", "Ra" }, { "Ra", "r1" }, { "r1", "r2" }, { "r2", "r3" }, { "r3", "r4" }, { "r4", "r5" },
        { "r5", "Rb" }, { "Rb", "R1" }, { "R1", "R2" }, { "R2", "R3" }, { "R3", "R4" }, { "R4", "R5" }, { "R5", "R6" }, { "R6", "R7" },
        { "HU", "F1" }, { "F1", "F2" }, { "F2", "F3" }, { "F3", "F4" }, { "F4", "F5" }, { "F5", "F6" }, { "F6", "F7" }, { "F7", "F8" },
        { "F8", "F9" }, { "F9", "F10" }, { "F10", "F11" }, { "F11", "F12" }, { "F12", "F13" }, { "F13", "F14" }, { "F14", "F15" }, { "F15", "F16" },
        { "F16", "F17" }, { "F17", "F18" }, { "F18", "F19" },
    },
}
JD7810Transmission.GATE_IVT = {
    { -2.21, 15.76, 50 }, { 32, 14.1, 50 }, { 36, 12.85, 50 }, { 40, 9.99, 50 }, { 45, 6.31, 50 }, { 48, 5.5, 50 }, { 52, 5.16, 50 }, { 78.1, 5.16, 50 },
}

-- =====================================================================
--  G) KULISA: rucice mjenjaca prate utor (AutoQuad II, Powershift 19/7, IVT)
--     Polozaji su tocke u utoru (mm, lokalno konzoli, os Blendera; igra: x, z, -y).
--     Rucica se krece po grafu utora (najkraci put PO UTORU, ne ravno kroz plocu),
--     stalnom brzinom s ubrzanjem/usporenjem i usporenjem u zavojima.
--     Kutevi iz polozaja: IK oko kugle (kardanski Lat/FA) ili okretanje oko osi (IVT).
-- =====================================================================
JD7810Transmission.GATE_VMAX = 0.20      -- m/s, najveca brzina vrha sipke u utoru
JD7810Transmission.GATE_ACC  = 1.6       -- m/s2
local GATE_CORNER_MIN = 0.3              -- brzina u ostrom zavoju (90 st.) = 30 % najvece

local function gateV3(p) return { p[1] / 1000, p[3] / 1000, -p[2] / 1000 } end
local function vsub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function vlen(a) return math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3]) end
local function vlerp(a, b, t) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t } end
local function vnorm(a) local l = vlen(a); if l < 1e-9 then return { 0, 1, 0 } end return { a[1] / l, a[2] / l, a[3] / l } end

local function gateBuild(def)
    local G = { pos = {}, adj = {}, cache = {} }
    for name, p in pairs(def.nodes) do G.pos[name] = gateV3(p); G.adj[name] = {} end
    for _, e in ipairs(def.edges) do
        local a, b = e[1], e[2]
        local w = vlen(vsub(G.pos[a], G.pos[b]))
        table.insert(G.adj[a], { b, w }); table.insert(G.adj[b], { a, w })
    end
    return G
end

-- udaljenosti do cilja i sljedeci cvor prema cilju (Dijkstra od cilja, spremljeno)
local function gateTo(G, target)
    local c = G.cache[target]
    if c ~= nil then return c end
    local dist, nxt, done = {}, {}, {}
    for n in pairs(G.pos) do dist[n] = math.huge end
    dist[target] = 0
    while true do
        local u, best = nil, math.huge
        for n, d in pairs(dist) do if not done[n] and d < best then u, best = n, d end end
        if u == nil then break end
        done[u] = true
        for _, e in ipairs(G.adj[u]) do
            local v, w = e[1], e[2]
            if best + w < dist[v] then dist[v] = best + w; nxt[v] = u end
        end
    end
    c = { dist = dist, nxt = nxt }
    G.cache[target] = c
    return c
end

local function turnAngle(a, b, c)
    local u, w = vsub(b, a), vsub(c, b)
    local lu, lw = vlen(u), vlen(w)
    if lu < 1e-6 or lw < 1e-6 then return 0 end
    local d = (u[1] * w[1] + u[2] * w[2] + u[3] * w[3]) / (lu * lw)
    return math.deg(math.acos(math.max(-1, math.min(1, d))))
end

-- S = { u, w, t, v }: rucica na bridu u->w (t 0..1), brzina v
local function gateStep(G, S, target, dt)
    local vmax, acc = JD7810Transmission.GATE_VMAX, JD7810Transmission.GATE_ACC
    if G.pos[target] == nil then return end
    local C = gateTo(G, target)
    local cur = vlerp(G.pos[S.u], G.pos[S.w], S.t)
    -- izlaz s trenutnog brida: kroz u ili w, sto je krace do cilja
    local du, dw = vlen(vsub(cur, G.pos[S.u])), vlen(vsub(cur, G.pos[S.w]))
    local e = S.u
    if dw + (C.dist[S.w] or math.huge) < du + (C.dist[S.u] or math.huge) then e = S.w end
    local remain = vlen(vsub(cur, G.pos[e])) + (C.dist[e] or 0)
    if remain < 1e-5 then S.u, S.w, S.t, S.v = target, target, 0, 0; return end
    -- ogranicenje brzine: kraj puta i sljedeci zavoji
    local vAllow = math.min(vmax, math.sqrt(2 * acc * remain))
    local prev, node, dsum = cur, e, vlen(vsub(cur, G.pos[e]))
    for _ = 1, 4 do
        local nx = C.nxt[node]
        if nx == nil then break end
        local ang = turnAngle(prev, G.pos[node], G.pos[nx])
        local vc = vmax * math.max(GATE_CORNER_MIN, math.min(1, 1 - ang / 100))
        vAllow = math.min(vAllow, math.sqrt(vc * vc + 2 * acc * dsum))
        prev = G.pos[node]; dsum = dsum + vlen(vsub(G.pos[nx], G.pos[node])); node = nx
    end
    S.v = math.min((S.v or 0) + acc * dt / 1000, vAllow)
    local step = math.max(S.v, 0.002) * dt / 1000
    -- pomak po putu
    local safety = 0
    while step > 0 and safety < 64 do
        safety = safety + 1
        local pe = G.pos[e]
        local d = vlen(vsub(pe, cur))
        if step < d then
            cur = vlerp(cur, pe, step / d)
            -- natrag u (u,w,t): cur lezi na bridu prema e
            if e == S.w then
                local L = vlen(vsub(G.pos[S.w], G.pos[S.u]))
                S.t = L > 1e-9 and vlen(vsub(cur, G.pos[S.u])) / L or 1
            elseif e == S.u then
                local L = vlen(vsub(G.pos[S.w], G.pos[S.u]))
                S.t = L > 1e-9 and vlen(vsub(cur, G.pos[S.u])) / L or 0
            end
            return
        end
        step = step - d
        cur = pe
        if e == target then S.u, S.w, S.t, S.v = target, target, 0, 0; return end
        local nx = C.nxt[e]
        if nx == nil then S.u, S.w, S.t = e, e, 0; return end
        S.u, S.w, S.t = e, nx, 0
        e = nx
    end
end

local function gatePoint(G, S) return vlerp(G.pos[S.u], G.pos[S.w], S.t) end

-- IK kardan: Lat okrece oko Z (igra), FA oko X; d0 = smjer sipke u mirovanju (lokalno pivotu)
local function ikGimbal(d0, v)
    local Rr = math.sqrt(d0[2] * d0[2] + d0[3] * d0[3])
    local ph = math.atan2(d0[3], d0[2])
    local beta = math.asin(math.max(-1, math.min(1, v[3] / Rr))) - ph
    local cb, sb = math.cos(beta), math.sin(beta)
    local uy, ux = d0[2] * cb - d0[3] * sb, d0[1]
    local alpha = math.atan2(v[2], v[1]) - math.atan2(uy, ux)
    return alpha, beta
end

-- najkraci luk (kvaternion) koji okrece smjer a u smjer b
local function quatArc(a, b)
    a, b = vnorm(a), vnorm(b)
    local cx, cy, cz = a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]
    local w = 1 + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    local l = math.sqrt(cx * cx + cy * cy + cz * cz + w * w)
    if l < 1e-9 then return 0, 0, 0, 1 end
    return cx / l, cy / l, cz / l, w / l
end

-- inicijalizacija rucice s kardanom; cvorovi po i3dMappings
local function gimbalLever(vehicle, def, ids, restNode)
    local L = { ok = false }
    local function node(id)
        local ok, n = pcall(I3DUtil.indexToObject, vehicle.components, id, vehicle.i3dMappings)
        if ok and n ~= nil and n ~= 0 then return n end
        return nil
    end
    L.console, L.pivot, L.lat, L.fa = node(ids[1]), node(ids[2]), node(ids[3]), node(ids[4])
    if L.console == nil or L.pivot == nil or L.lat == nil or L.fa == nil then return L end
    L.G = gateBuild(def)
    local q0 = L.G.pos[restNode]
    L.d0 = vnorm({ localToLocal(L.console, L.pivot, q0[1], q0[2], q0[3]) })
    L.S = { u = restNode, w = restNode, t = 0, v = 0 }
    L.ok = true
    return L
end

local function gimbalApply(L)
    local p = gatePoint(L.G, L.S)
    local v = vnorm({ localToLocal(L.console, L.pivot, p[1], p[2], p[3]) })
    local a, b = ikGimbal(L.d0, v)
    setRotation(L.lat, 0, 0, a)
    setRotation(L.fa, b, 0, 0)
end

-- parkirano: parkirna kocnica ili ugasen motor u mjestu
local function leverParked(vehicle, motor)
    local m = vehicle.spec_motorized
    if m ~= nil and m.isParkingBrakeActive then return true end
    if motor ~= nil and motor.jd7810Park then return true end                     -- v177 park (LAlt+6)
    local running = true
    if type(vehicle.getIsMotorStarted) == "function" then
        local ok, r = pcall(vehicle.getIsMotorStarted, vehicle); running = ok and r == true
    end
    return not running and getSpeedKmh(motor) < 0.5
end

-- IVT: 1D kretanje po lancu tocaka (isti profil brzine)
local function gateLen(a) return vlen(a) end
local function gateSub(a, b) return vsub(a, b) end
local function gateQuatArc(a, b) return quatArc(a, b) end
local function gateMove1D(s, v, target, dt)
    local vmax, acc = JD7810Transmission.GATE_VMAX, JD7810Transmission.GATE_ACC
    local d = target - s
    if math.abs(d) < 1e-5 then return target, 0 end
    local vAllow = math.min(vmax, math.sqrt(2 * acc * math.abs(d)))
    v = math.min(v + acc * dt / 1000, vAllow)
    local step = math.max(v, 0.002) * dt / 1000
    if step >= math.abs(d) then return target, 0 end
    return s + (d > 0 and step or -step), v
end
local function gateChainPoint(IG, s)
    for i = 2, #IG.pts do
        if s <= IG.cum[i] or i == #IG.pts then
            local seg = IG.cum[i] - IG.cum[i - 1]
            local t = seg > 1e-9 and clamp((s - IG.cum[i - 1]) / seg, 0, 1) or 0
            return vlerp(IG.pts[i - 1], IG.pts[i], t)
        end
    end
    return IG.pts[1]
end

-- =====================================================================
--  K) IVT: poluga brzine prati brzinu voznje
--     Poluga je u utoru odabrane trake (1 ili 2), polozaj = brzina prema
--     zadanim brzinama trake (OMAR195338). U mjestu je na N (straga).
-- =====================================================================
-- vrsta mjenjaca: iz imena konfiguracije motora (pouzdano), inace iz grade prijenosa
-- (FS25 i mjenjacima s brzinama postavlja minForwardGearRatio, pa samo to nije dovoljno za IVT)
function JD7810Transmission.motorKind(motor)
    if motor == nil then return nil end
    if motor.jd7810Kind ~= nil then return motor.jd7810Kind end
    local kind, cname = nil, nil
    local vehicle = motor.vehicle
    local ok = pcall(function()
        local idx = vehicle.configurations ~= nil and vehicle.configurations.motor or nil
        local item = g_storeManager ~= nil and g_storeManager:getItemByXMLFilename(vehicle.configFileName) or nil
        local list = item ~= nil and item.configurations ~= nil and item.configurations.motor or nil
        local cfg = (list ~= nil and idx ~= nil) and list[idx] or nil
        cname = cfg ~= nil and cfg.name or nil
    end)
    if ok and type(cname) == "string" then
        local n = cname:lower()
        -- v173: PowrQuad (AQ bez AUTO/ECO) i 50 km/h verzije
        motor.jd7810PowrQuad = n:find("powrquad") ~= nil
        motor.jd7810Top = n:find("50 km") ~= nil and 50 or 40
        if motor.jd7810PowrQuad then motor.jd7810AqMode = 0 end
        if n:find("ivt") or n:find("autopowr") then kind = "IVT"
        elseif n:find("powershift") then kind = "PS"
        elseif n:find("autoquad") then kind = "AQ" end
    end
    local nf = motor.forwardGears ~= nil and #motor.forwardGears or 0
    local ng = motor.gearGroups ~= nil and #motor.gearGroups or 0
    if kind == nil then
        if nf == 0 and motor.minForwardGearRatio ~= nil then kind = "IVT"
        elseif ng == 4 and nf == 5 then kind = "AQ"          -- AQ: rasponi A-E = brzine, 1-4 = grupe
        elseif ng >= 19 then kind = "PS" end                  -- PS: 19 stupnjeva = grupe
    end
    motor.jd7810Kind = kind or "?"
    log(string.format("mjenjac: %s (konfiguracija '%s', brzina naprijed %d, opsega %d, minForwardGearRatio %s)",
        motor.jd7810Kind, tostring(cname), nf, ng, tostring(motor.minForwardGearRatio)))
    return motor.jd7810Kind
end

-- v173: najveca brzina konfiguracije (40 / 50 km/h) i PowrQuad
function JD7810Transmission.motorTop(motor)
    if motor == nil then return 40 end
    JD7810Transmission.motorKind(motor)
    return motor.jd7810Top or 40
end
function JD7810Transmission.isPowrQuad(motor)
    JD7810Transmission.motorKind(motor)
    return motor ~= nil and motor.jd7810PowrQuad == true
end

function JD7810Transmission.isIVT(motor)
    return JD7810Transmission.motorKind(motor) == "IVT"
end

local function quatMul(ax, ay, az, aw, bx, by, bz, bw)
    return aw * bx + ax * bw + ay * bz - az * by,
           aw * by - ax * bz + ay * bw + az * bx,
           aw * bz + ax * by - ay * bx + az * bw,
           aw * bw - ax * bx - ay * by - az * bz
end

-- gumbi na IVT ploci: birac (OFF/1/2/3) i Field Cruise (zapamceni okretaji)
local IVT_SEL_DEG = { [0] = 0, [1] = -45, [2] = -105, [3] = -165 }   -- 0 na 7:30, 1 na 9, 2 (ECO) na 11, 3 na 1 sat
function JD7810Transmission.updateIVTKnobs(motor, dt)
    local vehicle = motor.vehicle
    if motor.jd7810KnobNodes == nil then
        motor.jd7810KnobNodes = {}
        for _, id in ipairs({ "selKnobIVTRot", "fcKnobIVTRot" }) do
            local ok, n = pcall(I3DUtil.indexToObject, vehicle.components, id, vehicle.i3dMappings)
            motor.jd7810KnobNodes[id] = (ok and n ~= nil and n ~= 0) and n or 0
        end
    end
    local cfg = JD7810Transmission.cfg
    local k = math.min(1, dt / 90)
    local sel = motor.jd7810KnobNodes.selKnobIVTRot
    if sel ~= 0 then
        local target = math.rad(IVT_SEL_DEG[motor.jd7810IvtMode or math.floor((cfg.ivtMode or 2) + 0.5)] or 0)
        motor.jd7810SelAng = (motor.jd7810SelAng or target) + (target - (motor.jd7810SelAng or target)) * k
        setRotation(sel, 0, motor.jd7810SelAng * cfg.ivtKnobDir, 0)
    end
    local fc = motor.jd7810KnobNodes.fcKnobIVTRot
    if fc ~= 0 then
        local rpm = motor.jd7810FieldCruise or 0
        local target = 0
        if rpm > 0 then
            -- iskljucen = skroz u smjeru kazaljke (5 sati, zec); nize okretaje = suprotno od kazaljke prema kornjaci (8 sati)
            target = math.rad(270) * (1 - clamp((rpm - 1000) / 1300, 0, 1))
        end
        motor.jd7810FcAng = (motor.jd7810FcAng or 0) + (target - (motor.jd7810FcAng or 0)) * k
        setRotation(fc, 0, motor.jd7810FcAng * cfg.ivtKnobDir, 0)
    end
end

-- AutoQuad II: Field Cruise kolut (aqFcKnobRot, kao IVT kolut) i klackalica AUTO/ECO (aqAutoEcoRot, kratki pritisak)
function JD7810Transmission.updateAQControls(motor, dt)
    local vehicle = motor.vehicle
    if motor.jd7810AqCtl == nil then
        motor.jd7810AqCtl = { fc = 0, rocker = 0 }
        local ok, con = pcall(I3DUtil.indexToObject, vehicle.components, "consoleAutoQuad", vehicle.i3dMappings)
        if ok and con ~= nil and con ~= 0 then
            local function ch(p, n) if p == nil or p == 0 then return 0 end local c = getChild(p, n); return (c ~= nil and c ~= 0) and c or 0 end
            motor.jd7810AqCtl.fc = ch(ch(con, "aqFcKnobFrame"), "aqFcKnobRot")
            motor.jd7810AqCtl.rocker = ch(ch(con, "aqAutoEcoFrame"), "aqAutoEcoRot")
        end
    end
    local cfg = JD7810Transmission.cfg
    local k = math.min(1, dt / 90)
    local fcN = motor.jd7810AqCtl.fc
    if fcN ~= 0 then
        local rpm = motor.jd7810FieldCruise or 0
        local target = 0
        if rpm > 0 then target = math.rad(270) * (1 - clamp((rpm - 1500) / 700, 0, 1)) end   -- iskljucen = skroz u smjeru kazaljke
        motor.jd7810AqFcAng = (motor.jd7810AqFcAng or 0) + (target - (motor.jd7810AqFcAng or 0)) * k
        setRotation(fcN, 0, motor.jd7810AqFcAng * (cfg.ivtKnobDir or 1), 0)
    end
    local rk = motor.jd7810AqCtl.rocker
    if rk ~= 0 then
        local t = motor.jd7810AqPressT or 0
        local target = 0
        if t > 0 then motor.jd7810AqPressT = t - dt; target = math.rad(8) * (motor.jd7810AqPress or 1) end
        motor.jd7810AqRkAng = (motor.jd7810AqRkAng or 0) + (target - (motor.jd7810AqRkAng or 0)) * math.min(1, dt / 40)
        setRotation(rk, motor.jd7810AqRkAng * (cfg.aqRockerDir or 1), 0, 0)
    end
end

function JD7810Transmission.updateIVTLever(motor, dt)
    local vehicle = motor.vehicle
    if motor.jd7810IvtNode == nil then
        motor.jd7810IvtNode = 0
        if I3DUtil ~= nil and I3DUtil.indexToObject ~= nil then
            local ok, node = pcall(I3DUtil.indexToObject, vehicle.components, "leverIVTRot", vehicle.i3dMappings)
            if ok and node ~= nil and node ~= 0 then
                motor.jd7810IvtNode = node
                motor.jd7810IvtBase = { getQuaternion(node) }
            end
        end
    end
    local node = motor.jd7810IvtNode
    if node == 0 then
        return
    end

    -- poluga po Z-kulisi: N (lijevi kraj) -> rampa 1 -> prolaz -> rampa 2 (40 km/h); polozaj = brzina
    if motor.jd7810IvtGate == nil then
        local IG = { ok = false }
        local okC, con = pcall(I3DUtil.indexToObject, vehicle.components, "consoleIVT", vehicle.i3dMappings)
        if okC and con ~= nil and con ~= 0 then
            IG.pts, IG.cum = {}, { 0 }
            for i, p in ipairs(JD7810Transmission.GATE_IVT) do IG.pts[i] = gateV3(p) end
            for i = 2, #IG.pts do IG.cum[i] = IG.cum[i - 1] + gateLen(gateSub(IG.pts[i], IG.pts[i - 1])) end
            IG.L = IG.cum[#IG.cum]
            IG.L1 = IG.cum[2]                    -- kraj utora trake 1 (tocka 2)
            IG.L2 = IG.cum[#IG.cum - 1]          -- pocetak utora trake 2 (predzadnja tocka)
            local px, py, pz = getTranslation(node)
            IG.p = { px, py, pz }
            IG.d0 = gateSub(IG.pts[1], IG.p)
            IG.s, IG.v = 0, 0
            IG.ok = true
        end
        motor.jd7810IvtGate = IG
    end
    local IG = motor.jd7810IvtGate
    if IG.ok then
        -- traka 1: N..kraj utora 1 = 0..F1 (R1); traka 2: pocetak..kraj utora 2 = F1..F2 (R1..R2)
        local speed = getSpeedKmh(motor)
        local target = 0
        if speed > 0.3 then
            local S = JD7810Transmission.ivtSet
            local d = JD7810Transmission.ivtDir(motor)
            local v1, v2 = S[d .. "1"], S[d .. "2"]
            if (S.auto or 0) > 0.5 and JD7810Transmission.ivtRangePoints ~= nil then   -- v172 AUTO: utor 1 do tocke prebacivanja
                local upK = JD7810Transmission.ivtRangePoints(motor)
                v1 = math.min(upK / (motor.jd7810TyreFactor or 1), v2 / 1.1)
            end
            if S.band == 2 then
                target = IG.L2 + (IG.L - IG.L2) * clamp((speed - v1) / math.max(0.1, v2 - v1), 0, 1)
            else
                target = IG.L1 * clamp(speed / math.max(0.05, v1), 0, 1)
            end
        end
        IG.s, IG.v = gateMove1D(IG.s, IG.v, target, dt)
        local q = gateChainPoint(IG, IG.s)
        local rx, ry, rz, rw = gateQuatArc(IG.d0, gateSub(q, IG.p))
        local b = motor.jd7810IvtBase
        local qx, qy, qz, qw = quatMul(rx, ry, rz, rw, b[1], b[2], b[3], b[4])
        setQuaternion(node, qx, qy, qz, qw)
    end

    -- rucica rucnog gasa na IVT konzoli: od kornjace (straga) do zeca (naprijed)
    if motor.jd7810HandNode == nil then
        motor.jd7810HandNode = 0
        local ok, hn = pcall(I3DUtil.indexToObject, vehicle.components, "handThrottleIVT", vehicle.i3dMappings)
        if ok and hn ~= nil and hn ~= 0 then
            motor.jd7810HandNode = hn
        end
    end
    if motor.jd7810HandNode ~= 0 then
        local cfgH = JD7810Transmission.cfg
        local hand = motor.jd7810HandRpm or 0
        local frac = 0
        if hand > 0 then
            frac = clamp((hand - motor.minRpm) / math.max(1, cfgH.handMax - motor.minRpm), 0, 1)
        end
        motor.jd7810HandPos = (motor.jd7810HandPos or 0) + (frac - (motor.jd7810HandPos or 0)) * math.min(1, dt / 120)
        -- rucica se okrece oko osi kotaca baze (od kornjace do zeca, ukupno ~60 stupnjeva)
        setRotation(motor.jd7810HandNode, 0, 0, -1.042 * motor.jd7810HandPos * cfgH.ivtHandDir)
    end

    -- kotacic zadane brzine na rucici (Blender rot Y = igra rot Z): 15 st. po koraku, bez granicnika
    if motor.jd7810WheelNode == nil then
        motor.jd7810WheelNode = 0
        local ok, wn = pcall(I3DUtil.indexToObject, vehicle.components, "ivtSpeedWheelRot", vehicle.i3dMappings)
        if ok and wn ~= nil and wn ~= 0 then motor.jd7810WheelNode = wn end
    end
    if motor.jd7810WheelNode ~= 0 then
        local target = math.rad(15) * (JD7810Transmission.ivtWheelSteps or 0)
        local cur = motor.jd7810WheelAng or target
        cur = cur + (target - cur) * math.min(1, dt / 60)
        motor.jd7810WheelAng = cur
        setRotation(motor.jd7810WheelNode, 0, 0, -cur * (JD7810Transmission.cfg.ivtWheelDir or 1))
    end

    JD7810Transmission.updateIVTKnobs(motor, dt)
end

-- =====================================================================
--  Konzolne naredbe
-- =====================================================================

-- ---------- rucni gas AutoQuad / Powershift: rucica u utoru lijevo od mjenjaca ----------
-- os okretanja poprijeko utora, 90 mm ispod ploce; prazni hod = straga (0), 2100 o/min = naprijed (33,5 st.)
JD7810Transmission.HAND_LEVER_DEG = 33.47
local function updateHandLever(motor, dt, id)
    local vehicle = motor.vehicle
    if motor.jd7810HandLever == nil then
        local ok, n = pcall(I3DUtil.indexToObject, vehicle.components, id, vehicle.i3dMappings)
        motor.jd7810HandLever = (ok and n ~= nil and n ~= 0) and n or 0
    end
    local n = motor.jd7810HandLever
    if n == 0 then return end
    local cfg = JD7810Transmission.cfg
    local hand = motor.jd7810HandRpm or 0
    local frac = 0
    if hand > 0 then frac = clamp((hand - motor.minRpm) / math.max(1, cfg.handMax - motor.minRpm), 0, 1) end
    motor.jd7810HandPos = (motor.jd7810HandPos or 0) + (frac - (motor.jd7810HandPos or 0)) * math.min(1, dt / 120)
    setRotation(n, -math.rad(JD7810Transmission.HAND_LEVER_DEG) * motor.jd7810HandPos, 0, 0)   -- negativno = naprijed
end


-- =====================================================================
--  AutoQuad II: rucica raspona (A-E / N / P) i tipke 1-4 na glavi rucice
--  cvorovi: aqRangeLat (bocno po kanalu), aqRangeFA (naprijed/natrag), aqBtnUp/aqBtnDown (tipke, hod 1,5 mm)
--  polozaji A-E, N, P su tocke u utoru kulise (GATE_AQ); kutevi aqRangeLat (Z) / aqRangeFA (X) iz IK oko kugle
-- =====================================================================
local AQ_GROUPS = { "A", "B", "C", "D", "E" }
function JD7810Transmission.isAutoQuad(motor)
    return JD7810Transmission.motorKind(motor) == "AQ"
end
function JD7810Transmission.updateAQLever(motor, dt)
    local vehicle = motor.vehicle
    if motor.jd7810AqNodes == nil then
        motor.jd7810AqNodes = {}
        for _, id in ipairs({ "aqRangeLat", "aqRangeFA", "aqBtnUp", "aqBtnDown" }) do
            local ok, n = pcall(I3DUtil.indexToObject, vehicle.components, id, vehicle.i3dMappings)
            motor.jd7810AqNodes[id] = (ok and n ~= nil and n ~= 0) and n or 0
        end
        for _, id in ipairs({ "aqBtnUp", "aqBtnDown" }) do
            local n = motor.jd7810AqNodes[id]
            if n ~= 0 then motor.jd7810AqNodes[id .. "Base"] = { getTranslation(n) } end
        end
        motor.jd7810AqGear = motor.activeGearGroupIndex or 0
        motor.jd7810AqBtn = { up = 0, down = 0 }
    end
    local nodes = motor.jd7810AqNodes
    local cfg = JD7810Transmission.cfg

    -- polozaj rucice: raspon A-E; N bez brzine; P parkirano (parkirna kocnica ili ugasen motor u mjestu)
    -- rucica ide PO UTORU: iz utora u poprecni kanal, kanalom do utora cilja, pa u njega
    if motor.jd7810AqGate == nil then
        motor.jd7810AqGate = gimbalLever(vehicle, JD7810Transmission.GATE_AQ, { "consoleAutoQuad", "aqRangePivot", "aqRangeLat", "aqRangeFA" }, "N")
    end
    local AG = motor.jd7810AqGate
    if AG.ok then
        local key = "N"
        if leverParked(vehicle, motor) then
            key = "P"
        elseif (motor.gear or 0) ~= 0 or (motor.targetGear or 0) ~= 0 then
            local rg = (motor.targetGear ~= nil and motor.targetGear ~= 0) and motor.targetGear or motor.gear
            key = AQ_GROUPS[rg or 3] or "C"                                  -- raspon A-E = brzina igre
        end
        gateStep(AG.G, AG.S, key, dt)
        gimbalApply(AG)
    end
    updateHandLever(motor, dt, "aqHandThrottleRot")

    -- tipke 1-4: kratki pritisak pri promjeni brzine unutar raspona (gore = zec, dolje = kornjaca)
    local g = ((motor.gear or 0) ~= 0) and (motor.activeGearGroupIndex or 0) or 0      -- 1-4 = grupa igre
    if g ~= motor.jd7810AqGear then
        if g > motor.jd7810AqGear and motor.jd7810AqGear ~= 0 then motor.jd7810AqBtn.up = 180 end
        if g < motor.jd7810AqGear and g ~= 0 then motor.jd7810AqBtn.down = 180 end
        motor.jd7810AqGear = g
    end
    for _, b in ipairs({ { "up", "aqBtnUp" }, { "down", "aqBtnDown" } }) do
        local t = motor.jd7810AqBtn[b[1]]
        local n = nodes[b[2]]
        if n ~= 0 and nodes[b[2] .. "Base"] ~= nil then
            local base = nodes[b[2] .. "Base"]
            local f = 0
            if t > 0 then f = math.sin(math.pi * t / 180); motor.jd7810AqBtn[b[1]] = math.max(0, t - dt) end
            setTranslation(n, base[1], base[2] - 0.0015 * f * (cfg.aqBtnDir or 1), base[3])   -- Blender Z tipke = Y igre
        end
    end
end


-- =====================================================================
--  Powershift 19/7 (OMAR189665): jedna rucica, utor Z + C
--  naprijed 1-19 (prednji krak), natrag R1-R7 (desni krak), N gore lijevo u C-u, P na kraju donjeg kraka
--  cvorovi: psShiftPivot (duboko ispod konzole) > psShiftLat (Z) > psShiftFA (X) > psShiftLever
-- =====================================================================
function JD7810Transmission.isPowershift(motor)
    return JD7810Transmission.motorKind(motor) == "PS"
end

function JD7810Transmission.updatePSLever(motor, dt)
    local vehicle = motor.vehicle
    if motor.jd7810PsGate == nil then
        motor.jd7810PsGate = gimbalLever(vehicle, JD7810Transmission.GATE_PS, { "consolePowershift", "psShiftPivot", "psShiftLat", "psShiftFA" }, "N")
    end
    local PG = motor.jd7810PsGate
    if not PG.ok then return end
    local key = "N"
    if leverParked(vehicle, motor) then
        key = "P"
    else
        local g = ((motor.gear or 0) ~= 0) and (motor.activeGearGroupIndex or 0) or 0       -- PS: stupanj = grupa igre
        if JD7810Transmission.isStandingNeutral ~= nil and JD7810Transmission.isStandingNeutral(motor) then g = 0 end   -- stoji u automatici: N
        if g ~= 0 then
            local dir = motor.currentDirection
            if dir == nil and motor.gearRatio ~= nil then dir = motor.gearRatio < 0 and -1 or 1 end
            if (dir or 1) < 0 then
                key = "R" .. tostring(math.floor(clamp(g, 1, 7)))
            else
                key = "F" .. tostring(math.floor(clamp(g, 1, 19)))
            end
        end
    end
    if key ~= PG.lastKey and JD7810Transmission.cfg.debug then                 -- jd7810Debug: ispis polozaja rucice
        PG.lastKey = key
        local okG, gd = pcall(motor.getGearToDisplay, motor)
        local okR, grd = pcall(motor.getGearGroupToDisplay, motor)
        log(string.format("PS rucica -> %s (gear=%s target=%s dir=%s prikaz=%s%s)", key, tostring(motor.gear), tostring(motor.targetGear),
            tostring(motor.currentDirection), okR and tostring(grd) or "?", okG and tostring(gd) or "?"))
        if not PG.dumped then
            PG.dumped = true
            local keys = {}
            for k, v in pairs(motor) do
                local tk = type(v)
                if type(k) == "string" and (tk == "number" or tk == "boolean") then
                    local lk = k:lower()
                    if lk:find("gear") or lk:find("dir") or lk:find("neutral") or lk:find("clutch") or lk:find("shift") or lk:find("manual") or lk:find("group") then
                        table.insert(keys, k .. "=" .. tostring(v))
                    end
                end
            end
            table.sort(keys)
            log("PS motor polja: " .. table.concat(keys, " "))
        end
    end
    gateStep(PG.G, PG.S, key, dt)
    gimbalApply(PG)
    updateHandLever(motor, dt, "psHandThrottleRot")
end

-- Interactive Control: klizni prekidac (kapa = sljedeci, ikone 1..4 = skok)
function JD7810Transmission.registerIcVSel()
    local env = _G["FS25_interactiveControl"]
    local IF = env ~= nil and env.InteractiveFunctions or nil
    if IF == nil or IF.addFunction == nil then return false end
    if IF.FUNCTION_ID ~= nil and IF.FUNCTION_ID["JD7810_V_SEL_NEXT"] ~= nil then return true end
    IF.addFunction("JD7810_V_SEL_NEXT", { posFunc = function(target, data, noEventSend)
        if noEventSend then return end
        if JD7810Transmission.vSelectorNext(target) and JD7810Transmission.switchClick ~= nil then pcall(JD7810Transmission.switchClick, target) end   -- v171 klik
    end })
    for i = 1, 4 do
        IF.addFunction("JD7810_V_SEL_" .. i, { posFunc = function(target, data, noEventSend)
            if noEventSend then return end
            if JD7810Transmission.vSelectorSet(target, i) and JD7810Transmission.switchClick ~= nil then pcall(JD7810Transmission.switchClick, target) end   -- v171 klik
        end })
    end
    log("Interactive Control: prekidac biraca V registriran (5)")
    return true
end
pcall(JD7810Transmission.registerIcVSel)
if JD7810Transmission.registerIC ~= nil then
    JD7810Transmission.registerIC = Utils.appendedFunction(JD7810Transmission.registerIC, function() pcall(JD7810Transmission.registerIcVSel) end)
end
