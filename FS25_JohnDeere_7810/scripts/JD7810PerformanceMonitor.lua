-- =====================================================================
--  JD7810PerformanceMonitor.lua   v8.1  (FS25 - osobna upotreba, Darijan)
--  Performance Monitor: 7-seg LCD, nacini prikaza, sirina, povrsina, spremanje stanja, piip
--  v8.2: zaslon prazan dok motor ne radi (ucitavanje, gasenje motora)
--  v8.1: podjela JD7810Transmission.lua v8.0 na module - kod premjesten
--        bez promjene ponasanja. Redoslijed ucitavanja u modDesc.xml:
--        Core, Transmission, Engine, PTO, Display, PerformanceMonitor, AgroGsm, Cockpit
-- =====================================================================

local JD = JD7810Transmission
local clamp = JD.U.clamp
local setEvent = JD.U.setEvent

-- =====================================================================
--  N) PERFORMANCE MONITOR (tvornicka opcija): 7-seg LCD, jedinice, stupac proklizavanja,
--     strelica prikljucka, ikone. Prikaz se mijenja tipkom (numpad 5), kasnije i klikom (IC).
-- =====================================================================
JD7810Transmission.PM_MODES = { "SPEED", "SLIP", "PTO", "AREA", "WORK", "WIDTH", "SERV" }
JD7810Transmission.PM_SERVICE_WARN = 0.60      -- od ove istrosenosti knjiga (servis) trepce
JD7810Transmission.PM_SINGLE = { SPEED = "pmUnit_km_h", SLIP = "pmUnit_pct", WIDTH = "pmUnit_m", SERV = "pmUnit_pct" }  -- prikazi s velikim brojem
JD7810Transmission.PM_MULTI = { PTO = { rows = 2, digits = 7, dps = false }, AREA = { rows = 2, digits = 5, dps = true }, WORK = { rows = 3, digits = 5, dps = true } }
JD7810Transmission.PM_SAVE_FILE = "jd7810_pm.xml"   -- u mapi savegamea, PO TRAKTORU (uniqueId): overall, trenutno, prikaz, sirina, IVT trake; GSM zajednicki
local SEG7 = { ["0"]="abcdef", ["1"]="bc", ["2"]="abdeg", ["3"]="abcdg", ["4"]="bcfg", ["5"]="acdfg", ["6"]="acdefg",
               ["7"]="abc", ["8"]="abcdefg", ["9"]="abcdfg", ["-"]="g", [" "]="" }
local SEGS = { "a","b","c","d","e","f","g" }
local PM_DIGITS = 4                  -- znamenke velikog broja (lijevo je mjesto za natpis prikaza)
local function vis(n, v) if n ~= nil then setVisibility(n, v) end end


-- ---------- spremanje u savegame (overall se nikad ne brise) ----------
local function pmSavePath()
    local mi = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local dir = mi ~= nil and mi.savegameDirectory or nil
    if dir == nil or dir == "" then return nil end
    return dir .. "/" .. JD7810Transmission.PM_SAVE_FILE
end
local PM_KEYS = { "areaT", "areaO", "kmT", "kmO", "mode", "widthLevel", "tyreBar" }      -- v175: tlak u gumama
local IVT_KEYS = { "band", "F1", "F2", "R1", "R2", "auto" }                       -- v172: auto (0/1)
JD7810Transmission.IVT_SET_DEFAULT = { band = 1, F1 = 15, F2 = 40, R1 = 8, R2 = 17, auto = 0 }

-- stanje se pamti PO TRAKTORU (uniqueId iz savegamea); novi traktor = tvornicke postavke
local function vehicleUid(vehicle)
    if type(vehicle.getUniqueId) == "function" then
        local ok, id = pcall(vehicle.getUniqueId, vehicle)
        if ok and id ~= nil and id ~= "" then return tostring(id) end
    end
    if vehicle.uniqueId ~= nil and vehicle.uniqueId ~= "" then return tostring(vehicle.uniqueId) end
    return nil
end
local function ivtDefaults()
    local S = {}
    for k, v in pairs(JD7810Transmission.IVT_SET_DEFAULT) do S[k] = v end
    return S
end

local function pmLoadState(P, vehicle)
    P.ivt = ivtDefaults()
    local mot = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil       -- v173: 40 ili 50 km/h
    if mot ~= nil and JD7810Transmission.ivtMaxF ~= nil then P.ivt.maxF = JD7810Transmission.ivtMaxF(mot) end
    P.uid = vehicleUid(vehicle)
    if P.uid == nil and JD.U.log ~= nil then JD.U.log("PM: traktor nema uniqueId - stanje monitora i IVT traka se nece spremati") end
    local path = pmSavePath()
    if path == nil or (fileExists ~= nil and not fileExists(path)) then return end
    local xml = loadXMLFile("jd7810pm", path)
    if xml == nil or xml == 0 then return end
    local b = getXMLFloat(xml, "jd7810pm.gsm#battery")                  -- mobitel: jedan (ide s vozacem)
    if b ~= nil then JD7810Transmission.gsmBattery = clamp(b, 0, 1) end
    local c = getXMLBool(xml, "jd7810pm.gsm#inCradle")
    if c ~= nil then JD7810Transmission.gsmInCradle = c end
    local base = nil
    if P.uid ~= nil then
        local i = 0
        while true do
            local key = string.format("jd7810pm.vehicle(%d)", i)
            if not hasXMLProperty(xml, key) then break end
            if getXMLString(xml, key .. "#uniqueId") == P.uid then base = key; break end
            i = i + 1
        end
    end
    if base ~= nil then
        for _, k in ipairs(PM_KEYS) do
            local v = getXMLFloat(xml, base .. ".monitor#" .. k)
            if v ~= nil then P[k] = v end
        end
        local S = P.ivt                                                   -- IVT trake i zadane brzine ovog traktora
        for _, k in ipairs(IVT_KEYS) do
            local v = getXMLFloat(xml, base .. ".ivt#" .. k)
            if v ~= nil then S[k] = v end
        end
        local fc = getXMLFloat(xml, base .. ".ivt#F2creep")              -- F2 prije puzajuceg nacina
        if fc ~= nil and fc > 0 then S.F2creep = fc end
        S.band = S.band == 2 and 2 or 1
        S.auto = ((S.auto or 0) > 0.5) and 1 or 0
        if JD7810Transmission.ivtNormalize ~= nil then
            JD7810Transmission.ivtNormalize(S, "F", 2); JD7810Transmission.ivtNormalize(S, "R", 2)
        end
    end
    delete(xml)
    P.mode = math.floor(clamp(P.mode or 1, 1, #JD7810Transmission.PM_MODES) + 0.5)
end
function JD7810Transmission.pmSaveAll()
    local path = pmSavePath()
    if path == nil then return end
    local xml = createXMLFile("jd7810pm", path, "jd7810pm")
    if xml == nil or xml == 0 then return end
    setXMLFloat(xml, "jd7810pm.gsm#battery", JD7810Transmission.gsmBattery or 1)
    setXMLBool(xml, "jd7810pm.gsm#inCradle", JD7810Transmission.gsmInCradle ~= false)
    local i = 0
    for vehicle, P in pairs(JD7810Transmission.pmStates or {}) do
        if P.uid ~= nil and not vehicle.isDeleted then                 -- prodani traktor se ne sprema
            local base = string.format("jd7810pm.vehicle(%d)", i)
            setXMLString(xml, base .. "#uniqueId", P.uid)
            for _, k in ipairs(PM_KEYS) do setXMLFloat(xml, base .. ".monitor#" .. k, P[k] or 0) end
            local S = P.ivt
            if S ~= nil then
                for _, k in ipairs(IVT_KEYS) do setXMLFloat(xml, base .. ".ivt#" .. k, S[k] or 0) end
                if S.F2creep ~= nil then setXMLFloat(xml, base .. ".ivt#F2creep", S.F2creep) end
            end
            i = i + 1
        end
    end
    saveXMLFile(xml); delete(xml)
end
if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, function() pcall(JD7810Transmission.pmSaveAll) end)
end

local function pmNodes(vehicle)
    if vehicle.jd7810PM ~= nil then return vehicle.jd7810PM end
    local P = { ok = false }
    vehicle.jd7810PM = P
    local ok, root = pcall(I3DUtil.indexToObject, vehicle.components, "performanceMonitor", vehicle.i3dMappings)
    if not ok or root == nil or root == 0 then return P end
    local function ch(parent, name) if parent == nil then return nil end local n = getChild(parent, name); if n ~= nil and n ~= 0 then return n end return nil end
    local seg = ch(root, "pmSeg"); P.seg = seg
    P.digits = {}
    for d = 1, PM_DIGITS do
        local dn = ch(seg, "pmD" .. d); P.digits[d] = {}
        for _, s in ipairs(SEGS) do P.digits[d][s] = ch(dn, "pmD" .. d .. s) end
    end
    P.col, P.dp1, P.dp2 = ch(seg, "pmCol"), ch(seg, "pmDp1"), ch(seg, "pmDp2")
    local units = ch(root, "pmUnits"); P.units = {}
    for _, n in ipairs({ "pmUnit_km_h", "pmUnit_pct", "pmUnit_m" }) do P.units[n] = ch(units, n) end
    local lbl = ch(root, "pmModeLbl"); P.lbl = {}
    for i = 1, #JD7810Transmission.PM_MODES do P.lbl[i] = ch(lbl, "pmLbl" .. i) end
    local icons = ch(root, "pmIcons"); P.modeIcon, P.mark = {}, {}
    for i = 1, #JD7810Transmission.PM_MODES do P.modeIcon[i] = ch(icons, "pmMode" .. i); P.mark[i] = ch(icons, "pmMark" .. i) end
    local bar = ch(root, "pmBar"); P.bar = {}
    for i = 1, 11 do P.bar[i] = ch(bar, string.format("pmBar%02d", i)) end
    local arr = ch(root, "pmArrow"); P.arrowDown, P.arrowUp = ch(arr, "pmArrowDown"), ch(arr, "pmArrowUp")
    local al = ch(root, "pmAlarm"); P.bell, P.radar = ch(al, "pmIconBell"), ch(al, "pmIconRadar")
    -- viseredni prikazi: pmMulti > pmPTO/pmAREA/pmWORK > print, znamenke pmX_red_znam > segmenti, tocke pmX_red_pN
    local multi = ch(root, "pmMulti"); P.multi = {}
    for tag, m in pairs(JD7810Transmission.PM_MULTI) do
        local g = ch(multi, "pm" .. tag)
        local M = { node = g, rows = {} }
        for r = 1, m.rows do
            local R = { d = {}, p = {} }
            for d = 1, m.digits do
                local dn = ch(g, string.format("pm%s_%d_%d", tag, r, d)); R.d[d] = {}
                for _, s in ipairs(SEGS) do R.d[d][s] = ch(dn, string.format("pm%s_%d_%d%s", tag, r, d, s)) end
            end
            if m.dps then for k = 1, m.digits - 1 do R.p[k] = ch(g, string.format("pm%s_%d_p%d", tag, r, k)) end end
            M.rows[r] = R
        end
        P.multi[tag] = M
    end
    local ws = ch(multi, "pmWidthStep"); P.width10, P.width20 = ch(ws, "pmWidth10"), ch(ws, "pmWidth20")
    P.ok = true
    -- font igre umjesto segmenata (veliki broj i visereni prikazi)
    local okF, fo = pcall(JD.U.fontDigits, P.digits, "PM")
    for tag2, M in pairs(P.multi) do
        for _, R in ipairs(M.rows) do pcall(JD.U.fontDigits, R.d, "PM_" .. tag2) end
    end
    P.mode = 1; P.areaT = 0; P.areaO = 0; P.kmT = 0; P.kmO = 0; P.widthLevel = 0; P.slip = 0; P.tyreBar = 1.6
    pmLoadState(P, vehicle)
    JD7810Transmission.ivtSet = P.ivt                                     -- IVT postavke ovog traktora
    JD7810Transmission.pmStates = JD7810Transmission.pmStates or {}
    JD7810Transmission.pmStates[vehicle] = P
    return P
end

-- broj -> tekst od n znamenki; decimale se smanjuju dok broj ne stane (12.34 -> 123.4 -> 1234)
local function fitNumber(value, decimals, n)
    local s
    for dec = decimals, 0, -1 do
        s = string.format("%." .. dec .. "f", math.max(0, value))
        if #s:gsub("%.", "") <= n then break end
    end
    local digits, dpPos = s:gsub("%.", ""), s:find("%.")
    if #digits > n then digits = string.rep("9", n); dpPos = nil end
    local pad = n - #digits
    return string.rep(" ", pad) .. digits, dpPos ~= nil and (pad + dpPos - 1) or nil    -- tocka iza znamenke k
end
local function setDigits(list, txt, first)
    for i = 1, #txt do
        local on = SEG7[txt:sub(i, i)] or ""
        local dg = list[(first or 1) + i - 1]
        if dg ~= nil and not JD.U.fontDigitSet(dg, txt:sub(i, i)) then
            for _, sg in ipairs(SEGS) do vis(dg[sg], on:find(sg, 1, true) ~= nil) end
        end
    end
end
local function showNumber(P, value, decimals)
    local txt, dp = fitNumber(value, decimals, PM_DIGITS)
    setDigits(P.digits, txt)
    vis(P.dp1, dp == 2); vis(P.dp2, dp == 3); vis(P.col, false)
end
local function showDashes(list, first, n) setDigits(list, string.rep("-", n), first) end
local function showRow(R, value, decimals, n)
    local txt, dp = fitNumber(value, decimals, n)
    setDigits(R.d, txt)
    for k, node in pairs(R.p) do vis(node, k == dp) end
end

local function wheelSlip(vehicle)
    local spec = vehicle.spec_wheels
    if spec == nil or spec.wheels == nil or vehicle.isDeleted or vehicle.isDeleting or vehicle.isAddedToPhysics == false then return 0 end
    local ground = math.abs(vehicle:getLastSpeed() or 0) / 3.6
    local sum, n = 0, 0
    for _, w in ipairs(spec.wheels) do
        local node = w.node or (w.physics and w.physics.node)
        local shape = w.wheelShape or (w.physics and w.physics.wheelShape)
        local r = w.radius or (w.physics and w.physics.radius)
        local created = w.physics == nil or w.physics.wheelShapeCreated ~= false   -- kotac jos nije u fizici (gsVehicleReload) - ne pitaj motor
        if node ~= nil and node ~= 0 and shape ~= nil and created and r ~= nil and getWheelShapeAxleSpeed ~= nil
           and (entityExists == nil or entityExists(node)) then
            local ok, av = pcall(getWheelShapeAxleSpeed, node, shape)
            if ok and av ~= nil then sum = sum + math.abs(av) * r; n = n + 1 end
        end
    end
    if n == 0 then return 0 end
    local wheelV = sum / n
    if wheelV < 0.3 then return 0 end
    return math.max(0, math.min(99, (wheelV - ground) / wheelV * 100))
end
JD7810Transmission.U.wheelSlip = wheelSlip   -- v160: i automatika mjenjaca (nema vise dok kotaci proklizavaju)

-- ---------- sirina prikljucka: citanje radnih podrucja i "varanje" +10/+20 % ----------
JD7810Transmission.pmScaled = {}        -- prikljucak -> { factor, nodes = { {node, x, y, z} } }
local function workAreaNodes(tool)
    local spec = tool.spec_workArea
    if spec == nil or spec.workAreas == nil then return nil end
    local list, seen = {}, {}
    for _, wa in pairs(spec.workAreas) do
        for _, n in ipairs({ wa.start, wa.width, wa.height }) do
            if n ~= nil and n ~= 0 and not seen[n] then seen[n] = true; table.insert(list, n) end
        end
    end
    return #list > 0 and list or nil
end
-- v122: radna sirina iz podataka trgovine (storeData specs workingWidth / workingWidthConfig po konfiguraciji).
-- Raspon radnih zona je kod nekih alata veci od stvarne sirine (test 05.10.: plug Agro-Masz POV 5 XL
-- mjeren 3,5 m, trgovina 2,5 m -> vuca i povrsina ~40 % prevelike). Zone ostaju rezerva.
local function storeWidth(tool)
    if tool.jd7810StoreWidth ~= nil then return tool.jd7810StoreWidth end
    local w = 0
    local info = "?"
    local okP, errP = pcall(function()
        if g_storeManager == nil or tool.configFileName == nil then return end
        local si = g_storeManager:getItemByXMLFilename(tool.configFileName)
        if si == nil then return end
        if si.specs == nil and StoreItemUtil ~= nil and StoreItemUtil.loadSpecsFromXML ~= nil then
            StoreItemUtil.loadSpecsFromXML(si)
        end
        local sp = si.specs
        if sp == nil then info = "nema specs"; return end
        -- FS25: specs.workingWidth = { width, minWidth }; workingWidthConfig[ime][indeks] = { width, isSelectable }
        local function num(v)
            if type(v) == "table" then return tonumber(v.width) end
            return tonumber(v)
        end
        local wc = {}
        if type(sp.workingWidthConfig) == "table" then
            for n, c in pairs(sp.workingWidthConfig) do
                for i, v in pairs(c) do wc[#wc + 1] = string.format("%s[%s]=%s", tostring(n), tostring(i), tostring(num(v))) end
            end
        end
        local cf = {}
        if type(tool.configurations) == "table" then
            for n, i in pairs(tool.configurations) do cf[#cf + 1] = string.format("%s=%s", tostring(n), tostring(i)) end
        end
        info = string.format("ww %s | wwc %s | cfg %s", tostring(num(sp.workingWidth)), table.concat(wc, ","), table.concat(cf, ","))
        if type(sp.workingWidthConfig) == "table" and type(tool.configurations) == "table" then
            for name, idx in pairs(tool.configurations) do
                local c = sp.workingWidthConfig[name]
                if type(c) == "table" and num(c[idx]) ~= nil then w = num(c[idx]) end
            end
        end
        if w <= 0 and num(sp.workingWidth) ~= nil then w = num(sp.workingWidth) end
    end)
    tool.jd7810StoreWidth = (w > 0.2 and w < 40) and w or 0
    if JD7810Transmission.U.log ~= nil then
        JD7810Transmission.U.log(string.format("sirina %s: trgovina %.2f m (%s)%s", tostring(tool.configFileName), tool.jd7810StoreWidth,
            info, okP and "" or (" GRESKA " .. tostring(errP))))
    end
    return tool.jd7810StoreWidth
end

local function toolWidth(tool)
    local sw = storeWidth(tool)
    if sw > 0 then
        local sc = JD7810Transmission.pmScaled[tool]                   -- PM WDTH +10/+20 %: vrati "trenutnu" sirinu kao i zone
        return sw * ((sc ~= nil and sc.factor) or 1)
    end
    local nodes = workAreaNodes(tool)
    if nodes ~= nil and tool.rootNode ~= nil then
        local minX, maxX = math.huge, -math.huge
        for _, n in ipairs(nodes) do
            local x = localToLocal(n, tool.rootNode, 0, 0, 0)
            minX = math.min(minX, x); maxX = math.max(maxX, x)
        end
        if maxX > minX then return maxX - minX end
    end
    return (tool.size ~= nil and tool.size.width) or 0
end
JD7810Transmission.U.toolWidth = toolWidth          -- koristi i JD7810Draft.lua
local function restoreWidth(tool)
    local st = JD7810Transmission.pmScaled[tool]
    if st == nil then return end
    for _, e in ipairs(st.nodes) do
        if entityExists == nil or entityExists(e[1]) then setTranslation(e[1], e[2], e[3], e[4]) end
    end
    JD7810Transmission.pmScaled[tool] = nil
end
local function depth(n) local d = 0; local p = getParent(n); while p ~= nil and p ~= 0 and d < 64 do d = d + 1; p = getParent(p) end return d end
local function applyWidth(tool, factor)
    restoreWidth(tool)
    if factor == 1 then return end
    local nodes = workAreaNodes(tool)
    if nodes == nil or tool.rootNode == nil then return end
    local root = tool.rootNode
    local st = { factor = factor, nodes = {} }
    local target, minX, maxX = {}, math.huge, -math.huge
    for _, n in ipairs(nodes) do
        local x, y, z = localToLocal(n, root, 0, 0, 0)
        target[n] = { x, y, z }; minX = math.min(minX, x); maxX = math.max(maxX, x)
        local ox, oy, oz = getTranslation(n); table.insert(st.nodes, { n, ox, oy, oz })
    end
    local cx = (minX + maxX) / 2                                  -- siri se jednako na obje strane
    table.sort(nodes, function(a, b) return depth(a) < depth(b) end)   -- prvo roditelji, pa djeca
    for _, n in ipairs(nodes) do
        local t = target[n]
        local px, py, pz = localToLocal(root, getParent(n), cx + (t[1] - cx) * factor, t[2], t[3])
        setTranslation(n, px, py, pz)
    end
    JD7810Transmission.pmScaled[tool] = st
end
local function updateWidthCheat(vehicle, P, implements)
    local factor = 1 + (P.widthLevel or 0) / 100
    local attached = {}
    for _, im in ipairs(implements) do
        local o = im.object; attached[o] = true
        local st = JD7810Transmission.pmScaled[o]
        if (st == nil and factor ~= 1) or (st ~= nil and st.factor ~= factor) then pcall(applyWidth, o, factor) end
    end
    for tool, _ in pairs(JD7810Transmission.pmScaled) do
        if not attached[tool] then pcall(restoreWidth, tool) end     -- otkacen: vrati original
    end
end

-- ---------- napajanje LCD-a: bez upaljenog motora zaslon je prazan (kao pravi PM) ----------
local PM_LCD_GROUPS = { "pmLcdPrint", "pmUnits", "pmIcons", "pmBar", "pmArrow", "pmSeg", "pmModeLbl", "pmAlarm", "pmMulti" }
local function pmSetPower(vehicle, on)
    if vehicle == nil or vehicle.components == nil or vehicle.i3dMappings == nil then return end
    if vehicle.i3dMappings["performanceMonitor"] == nil then return end    -- samo nas traktor (bez "Index not found" u logu)
    if vehicle.jd7810PmPower == on then return end
    local root = vehicle.jd7810PmRoot
    if root == nil then
        local ok, n = pcall(I3DUtil.indexToObject, vehicle.components, "performanceMonitor", vehicle.i3dMappings)
        root = (ok and n ~= nil and n ~= 0) and n or false
        vehicle.jd7810PmRoot = root
    end
    if not root then return end
    vehicle.jd7810PmPower = on
    for _, name in ipairs(PM_LCD_GROUPS) do
        local n = getChild(root, name)
        if n ~= nil and n ~= 0 then setVisibility(n, on) end
    end
end
JD7810Transmission.pmSetPower = pmSetPower
local function motorOn(vehicle)
    if type(vehicle.getIsMotorStarted) ~= "function" then return false end
    local ok, r = pcall(vehicle.getIsMotorStarted, vehicle); return ok and r == true
end
-- ucitan traktor (motor ugasen) i gasenje motora: zaslon prazan i kad se motor vise ne azurira
if Motorized ~= nil then
    if Motorized.onPostLoad ~= nil then
        Motorized.onPostLoad = Utils.appendedFunction(Motorized.onPostLoad, function(self) if not motorOn(self) then pcall(pmSetPower, self, false) end end)
    end
    if Motorized.stopMotor ~= nil then
        Motorized.stopMotor = Utils.appendedFunction(Motorized.stopMotor, function(self) pcall(pmSetPower, self, false) end)
    end
end

function JD7810Transmission.updatePerformanceMonitor(motor, dt)
    local vehicle = motor.vehicle
    if vehicle == nil then return end
    local P = pmNodes(vehicle)
    if not P.ok then return end
    local on = motorOn(vehicle)
    pmSetPower(vehicle, on)
    if not on then return end                                            -- ugasen motor: prazan zaslon, brojila stoje
    if P.ivt ~= nil and JD7810Transmission.ivtSet ~= P.ivt and type(vehicle.getIsActiveForInput) == "function" then
        local okA, active = pcall(vehicle.getIsActiveForInput, vehicle, true)
        if okA and active then JD7810Transmission.ivtSet = P.ivt end    -- vozac usao u ovaj traktor: njegove IVT postavke
    end
    local cfg = JD7810Transmission.cfg or {}
    local implements = JD7810Transmission.getImplements(vehicle)
    updateWidthCheat(vehicle, P, implements)
    local speed = math.abs(vehicle:getLastSpeed() or 0)                 -- km/h (stvarna)
    -- povrsina se broji samo za prikljucke koji su SPUSTENI i RADE (ukljuceni ako se ukljucuju),
    -- u voznji naprijed i unatrag (neki alati rade samo unatrag); sirina = ZBROJ aktivnih prikljucaka
    -- (vec ukljucuje +10/+20 % iz WDTH)
    local lowered, width, anyWidth = false, 0, 0
    for _, im in ipairs(implements) do
        local o = im.object
        local okW, w = pcall(toolWidth, o); w = okW and w or 0
        anyWidth = math.max(anyWidth, w)
        if type(o.getIsLowered) == "function" then
            local ok, l = pcall(o.getIsLowered, o, true)
            local working = true
            if type(o.getIsTurnedOn) == "function" and o.spec_turnOnVehicle ~= nil then
                local okT, on = pcall(o.getIsTurnedOn, o)
                working = okT and on == true
            end
            if ok and l and working and w > 0 then lowered = true; width = width + w end
        end
    end
    local m = speed / 3.6 * dt / 1000                                   -- predeni metri u ovom koraku
    if speed > 0.3 then P.kmT = P.kmT + m / 1000; P.kmO = P.kmO + m / 1000 end
    if lowered and speed > 0.5 then
        local ha = m * width / 10000
        P.areaT = P.areaT + ha; P.areaO = P.areaO + ha
    end
    local radar = cfg.pmRadar ~= false
    P.slip = P.slip + (wheelSlip(vehicle) - P.slip) * math.min(1, dt / 400)
    local slipShown = radar and P.slip or 0                                  -- bez radara nema mjerenja proklizavanja
    local dispSpeed = radar and speed or speed / math.max(0.01, 1 - P.slip / 100)   -- bez radara brzina s kotaca
    local damage = 0                                                         -- istrosenost iz igre (0..1)
    if type(vehicle.getDamageAmount) == "function" then
        local ok, d = pcall(vehicle.getDamageAmount, vehicle); if ok and type(d) == "number" then damage = math.max(0, math.min(1, d)) end
    end

    local mode = JD7810Transmission.PM_MODES[P.mode] or "SPEED"
    local single = JD7810Transmission.PM_SINGLE[mode]
    vis(P.seg, single ~= nil)
    for n, node in pairs(P.units) do vis(node, n == single) end
    for i = 1, #JD7810Transmission.PM_MODES do
        vis(P.lbl[i], i == P.mode and single ~= nil)                         -- natpis samo uz veliki broj
        vis(P.mark[i], i == P.mode)                                          -- trokutic iznad trenutnog prikaza
    end
    for tag, M in pairs(P.multi) do vis(M.node, tag == mode) end
    vis(P.width10, mode == "WIDTH" and P.widthLevel == 10); vis(P.width20, mode == "WIDTH" and P.widthLevel == 20)

    if mode == "SPEED" then showNumber(P, dispSpeed, 1)
    elseif mode == "SLIP" then
        if radar then showNumber(P, P.slip, 0) else showDashes(P.digits, 1, PM_DIGITS); vis(P.dp1, false); vis(P.dp2, false) end
    elseif mode == "WIDTH" then
        if anyWidth > 0.05 then showNumber(P, anyWidth, 2) else showDashes(P.digits, 1, PM_DIGITS); vis(P.dp1, false); vis(P.dp2, false) end
    elseif mode == "SERV" then showNumber(P, damage * 100, 0)
    elseif mode == "PTO" then
        -- F = prednji, R = straznji: okretaji PTO-a = nazivni x udio nazivnih okretaja motora; opterecenje: jos se dogovara (crtice)
        -- opterecenje = snaga koju alat trosi / snaga koju motor u tom trenutku moze dati (%)
        local rows = { { rpm = nil, load = nil }, { rpm = nil, load = nil } }
        local avail = nil
        if type(motor.getMotorAvailableTorque) == "function" then
            local okA, t = pcall(motor.getMotorAvailableTorque, motor); if okA and type(t) == "number" and t > 0 then avail = t end
        end
        local ratio = motor.ptoMotorRpmRatio or 0                         -- okretaji motora po okretaju PTO-a
        for _, im in ipairs(implements) do
            local o = im.object
            local st = JD7810Transmission.tools[o]
            if st ~= nil and st.active and (st.nominal or 0) > 0 then
                local r = im.front and 1 or 2
                rows[r].rpm = math.max(rows[r].rpm or 0, st.nominal * (st.factor or 1))
                if avail ~= nil and ratio > 0 and type(o.getConsumedPtoTorque) == "function" then
                    local okT, tq = pcall(o.getConsumedPtoTorque, o, false, true)
                    if okT and type(tq) == "number" then
                        rows[r].load = (rows[r].load or 0) + tq / ratio / avail * 100   -- moment na PTO-u preracunat na motor
                    end
                end
            end
        end
        P.ptoLoad = P.ptoLoad or { 0, 0 }
        for r = 1, 2 do
            local R = P.multi.PTO.rows[r]
            if rows[r].rpm ~= nil then setDigits(R.d, (fitNumber(rows[r].rpm, 0, 4))) else showDashes(R.d, 1, 4) end
            if rows[r].load ~= nil then
                P.ptoLoad[r] = P.ptoLoad[r] + (clamp(rows[r].load, 0, 199) - P.ptoLoad[r]) * math.min(1, dt / 500)   -- mirno, bez treperenja
                setDigits(R.d, (fitNumber(P.ptoLoad[r], 0, 3)), 5)
            else
                P.ptoLoad[r] = 0; setDigits(R.d, " --", 5)
            end
        end
    elseif mode == "AREA" then
        showRow(P.multi.AREA.rows[1], P.areaT, 2, 5); showRow(P.multi.AREA.rows[2], P.areaO, 1, 5)
    elseif mode == "WORK" then
        local ms = 0
        if type(vehicle.getOperatingTime) == "function" then local ok, t = pcall(vehicle.getOperatingTime, vehicle); if ok and type(t) == "number" then ms = t end
        elseif type(vehicle.operatingTime) == "number" then ms = vehicle.operatingTime end
        showRow(P.multi.WORK.rows[1], ms / 3600000, 1, 5); showRow(P.multi.WORK.rows[2], P.kmO, 1, 5); showRow(P.multi.WORK.rows[3], P.kmT, 1, 5)
    end

    local warn = damage >= JD7810Transmission.PM_SERVICE_WARN and math.floor((g_time or 0) / 500) % 2 == 0
    vis(P.modeIcon[7], not warn)                                             -- knjiga trepce kad je potreban servis
    -- alarm: preveliko proklizavanje ili PTO prespor pod opterecenjem (prije zacepljenja)
    local ptoWarn = false
    for _, st in pairs(JD7810Transmission.tools or {}) do if st.active and (st.clogTimer or 0) > 0 then ptoWarn = true end end
    local alarm = slipShown > (cfg.pmSlipAlarm or 15) or ptoWarn
    vis(P.bell, alarm and math.floor((g_time or 0) / 250) % 2 == 0)             -- zvono trepce 2 Hz
    vis(P.radar, radar)
    local bars = math.floor(slipShown / 3 + 0.5)                               -- 3 % po segmentu
    for i = 1, 11 do vis(P.bar[i], i <= bars) end
    vis(P.arrowDown, lowered); vis(P.arrowUp, not lowered)
end

-- kratki "piip" membranske tipkovnice (potvrda da je tipka proradila)
function JD7810Transmission.pmBeep()
    if (JD7810Transmission.cfg or {}).pmBeep == false then return end
    if JD7810Transmission.beepSample == nil then
        JD7810Transmission.beepSample = 0
        if createSample ~= nil and loadSample ~= nil then
            local ok, smp = pcall(createSample, "jd7810PmBeep")
            if ok and smp ~= nil and smp ~= 0 then
                local file = (JD7810Transmission.MOD_DIR or "") .. "sounds/jd7810_pm_beep.ogg"
                if pcall(loadSample, smp, file, false) then JD7810Transmission.beepSample = smp end
            end
        end
    end
    if JD7810Transmission.beepSample ~= 0 and playSample ~= nil then
        pcall(playSample, JD7810Transmission.beepSample, 1, 0.6, 0, 0, 0)
    end
end
-- v171: zvukovi prekidaca (Darijan 9.10., uzorci s Pixabaya - slobodna licenca): sounds/jd7810_<ime>.ogg
JD7810Transmission.uiSamples = JD7810Transmission.uiSamples or {}
function JD7810Transmission.playUiSound(name)
    local vol = (JD7810Transmission.cfg or {}).switchSound or 0.6
    if vol <= 0 then return end
    local S = JD7810Transmission.uiSamples
    if S[name] == nil then
        S[name] = 0
        if createSample ~= nil and loadSample ~= nil then
            local ok, smp = pcall(createSample, "jd7810Ui_" .. name)
            if ok and smp ~= nil and smp ~= 0 then
                local file = (JD7810Transmission.MOD_DIR or "") .. "sounds/jd7810_" .. name .. ".ogg"
                if pcall(loadSample, smp, file, false) then S[name] = smp end
            end
        end
    end
    if S[name] ~= 0 and playSample ~= nil then
        pcall(playSample, S[name], 1, vol, 0, 0, 0)
    end
end
-- klik prekidaca: samo kad je kamera u kabini (vani se mali prekidac ne cuje)
function JD7810Transmission.switchClick(vehicle)
    local e = vehicle ~= nil and vehicle.spec_enterable or nil
    local c = e ~= nil and e.activeCamera or nil
    if c ~= nil and c.isInside == false then return end
    JD7810Transmission.playUiSound("switch_click")
end

local PM_NAMES = { SPEED = "speed km/h", SLIP = "wheel slip %", PTO = "PTO front / rear", AREA = "area: trip / overall",
                   WORK = "engine hours / km overall / km trip", WIDTH = "implement width (LAlt+R: +10 / +20 %)", SERV = "service - wear %" }
function JD7810Transmission.actionPmMode(vehicle)
    local P = pmNodes(vehicle)
    if P.ok then JD7810Transmission.pmBeep() end
    if not P.ok then return end
    P.mode = P.mode % #JD7810Transmission.PM_MODES + 1
    setEvent("Performance Monitor: " .. PM_NAMES[JD7810Transmission.PM_MODES[P.mode]])
end
function JD7810Transmission.actionPmPrev(vehicle)
    local P = pmNodes(vehicle)
    if P.ok then JD7810Transmission.pmBeep() end
    if not P.ok then return end
    P.mode = (P.mode - 2) % #JD7810Transmission.PM_MODES + 1
    setEvent("Performance Monitor: " .. PM_NAMES[JD7810Transmission.PM_MODES[P.mode]])
end
-- LAlt+Num 6: stupanj sirine (samo dok je na zaslonu WIDTH)
function JD7810Transmission.actionPmWidth(vehicle)
    local P = pmNodes(vehicle)
    if P.ok then JD7810Transmission.pmBeep() end
    if not P.ok or JD7810Transmission.PM_MODES[P.mode] ~= "WIDTH" then return end
    P.widthLevel = ((P.widthLevel or 0) + 10) % 30
    setEvent(P.widthLevel == 0 and "Implement width: original (100 %)" or string.format("Implement width: +%d %%", P.widthLevel))
end
-- LAlt+Num 5: ZERO - brise samo "T" prikaza na kojem jesi
function JD7810Transmission.actionPmZero(vehicle)
    local P = pmNodes(vehicle)
    if P.ok then JD7810Transmission.pmBeep() end
    if not P.ok then return end
    local mode = JD7810Transmission.PM_MODES[P.mode]
    if mode == "AREA" then P.areaT = 0; setEvent("Performance Monitor: trip area = 0")
    elseif mode == "WORK" then P.kmT = 0; setEvent("Performance Monitor: km trip = 0") end
end


JD7810Transmission.U.SEGS = SEGS
JD7810Transmission.U.SEG7 = SEG7
JD7810Transmission.U.vis = vis

