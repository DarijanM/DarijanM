-- =====================================================================
--  JD7810Draft.lua   v1.1 (+ otpor kotrljanja)  (FS25 - osobna upotreba, Darijan)
--  Realna vuca obradnih prikljucaka na ovom traktoru.
--
--  Igra (PowerConsumer) koristi STALNU silu maxForce (kN) iz XML-a prikljucka:
--  ne ovisi o sirini, brzini, dubini, tlu ni vlazi. Dok je prikljucak na
--  nasem traktoru, ovaj modul svakih 100 ms racuna silu po modelu ASABE D497
--      D [N] = F_tlo * (A + B*v + C*v^2) * sirina[m] * dubina[cm] * vlaga * scale
--  i upisuje je u spec_powerConsumer.maxForce. Silu i dalje primjenjuje kod
--  igre (PowerConsumer.onUpdate -> addForce, samo uz dodir s tlom preko
--  GroundReference). Pri otkacivanju i izlazu vraca se original.
--  Koeficijenti po metru sirine (D497 "po alatu" preracunato s razmakom alata);
--  D497 navodi rasipanje +-30..50 % - zato draftScale / draftSoil u postavkama.
-- =====================================================================

local JD = JD7810Transmission
local clamp = JD.U.clamp
local isOurs = JD.U.isOurs
local log = JD.U.log

-- A, B, C: N po m sirine i cm dubine (v u km/h); F = faktor tla {tesko, srednje, lagano}
-- noDepth = sila po m sirine bez dubine
JD.DRAFT_CAT = {
    plow  = { name = "plug",                 A = 652, B = 0,    C = 5.1, F = { 1.0, 0.70, 0.45 }, depth = "depthPlow" },  -- D497 moldboard plow
    deep  = { name = "duboki kultivator",    A = 303, B = 18,   C = 0,   F = { 1.0, 0.85, 0.65 }, depth = "depthDeep" },  -- D497 chisel plow 91+5.4v po alatu, razmak 0,30 m
    cult  = { name = "kultivator/tanjurace", A = 213, B = 12.7, C = 0,   F = { 1.0, 0.85, 0.65 }, depth = "depthCult" },  -- D497 field cultivator (sekundarna) 32+1.9v po alatu, razmak 0,15 m
    sub   = { name = "podrivac",             A = 301, B = 0,    C = 2.4, F = { 1.0, 0.70, 0.45 }, depth = "depthSub" },   -- D497 subsoiler 226+1.8v^2 po alatu, razmak 0,75 m
    power = { name = "rotacijska drljaca",   A = 1500, B = 0,   C = 0,   F = { 1.0, 1.0, 1.0 },  noDepth = true },        -- procjena (pogon PTO-om racuna igra)
    sow   = { name = "sijacica",             A = 1500, B = 0,   C = 0,   F = { 1.0, 1.0, 1.0 },  noDepth = true },        -- procjena
}

JD.draftTools = {}          -- prikljucak -> { owner, orig = {maxForce, forceNode, forceDirNode, forceDir}, cat, kN }

local function category(tool)
    if tool.spec_plow ~= nil then return "plow" end
    local c = tool.spec_cultivator
    if c ~= nil then
        if c.isSubsoiler then return "sub" end
        if c.isPowerHarrow then return "power" end
        if c.useDeepMode then return "deep" end
        return "cult"
    end
    if tool.spec_sowingMachine ~= nil then return "sow" end
    return nil
end

local function isWorking(tool)
    if type(tool.getIsLowered) == "function" then
        local ok, low = pcall(tool.getIsLowered, tool, true)
        if not (ok and low) then return false end
    end
    if tool.spec_turnOnVehicle ~= nil and type(tool.getIsTurnedOn) == "function" then
        local ok, on = pcall(tool.getIsTurnedOn, tool)
        if not (ok and on) then return false end
    end
    return true
end

local wetWarned = false
local function groundWetness()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local w = env ~= nil and env.weather or nil
    if w ~= nil and type(w.getGroundWetness) == "function" then
        local ok, v = pcall(w.getGroundWetness, w)
        if ok and type(v) == "number" then return clamp(v, 0, 1) end
    end
    if not wetWarned then wetWarned = true; log("vuca: vlaznost tla nije dostupna, racunam kao suho") end
    return 0
end

function JD.draftForceN(tool, catKey, speedKmh, width, wet)
    local cfg = JD.cfg
    local c = JD.DRAFT_CAT[catKey]
    if c == nil or width <= 0 then return 0 end
    local soil = math.floor(clamp(cfg.draftSoil or 2, 1, 3) + 0.5)
    local depth = c.noDepth and 1 or (cfg[c.depth] or 10)
    local v = math.max(speedKmh, 0)
    return c.F[soil] * (c.A + c.B * v + c.C * v * v) * width * depth * (1 + (cfg.draftWet or 0) * wet) * (cfg.draftScale or 1)
end

local function restore(tool)
    local st = JD.draftTools[tool]
    JD.draftTools[tool] = nil
    if st == nil or tool.isDeleted then return end
    local spec = tool.spec_powerConsumer
    if spec == nil then return end
    spec.maxForce = st.orig.maxForce
    spec.forceNode, spec.forceDirNode, spec.forceDir = st.orig.forceNode, st.orig.forceDirNode, st.orig.forceDir
end
JD.U.restoreDraft = restore

local noPcWarned = {}
local function take(vehicle, tool, catKey)
    local spec = tool.spec_powerConsumer
    if spec == nil then
        if not noPcWarned[tool] then noPcWarned[tool] = true; log("vuca: prikljucak bez PowerConsumer - ostaje original (" .. tostring(tool.configFileName) .. ")") end
        return nil
    end
    local st = { owner = vehicle, cat = catKey, kN = 0,
                 orig = { maxForce = spec.maxForce, forceNode = spec.forceNode, forceDirNode = spec.forceDirNode, forceDir = spec.forceDir } }
    if spec.forceNode == nil and tool.rootNode ~= nil then   -- prikljucak bez tocke sile: korijen, smjer naprijed
        spec.forceNode, spec.forceDirNode, spec.forceDir = tool.rootNode, tool.rootNode, 1
    end
    JD.draftTools[tool] = st
    log(string.format("vuca: preuzet prikljucak %s (%s), izvorna sila %s kN, forceNode %s",
        tostring(tool.configFileName), JD.DRAFT_CAT[catKey].name, tostring(st.orig.maxForce), tostring(st.orig.forceNode)))
    return st
end

-- =====================================================================
--  OTPOR KOTRLJANJA (igra ga nema: gume imaju samo trenje).
--  Po kotacu: F [kN] = koef(podloga) * teret kotaca [t] * 9,81, uzduz kotaca, suprotno gibanju,
--  hvatiste u tocki dodira. Podloga kao u igri: WheelsUtil.getGroundType(polje, cesta, mekoca)
--  iz WheelPhysics (densityType, contact, groundDepth). Primjena addForce kao PowerConsumer (u tezistu tijela)
--  (kN, t). Ispod 0,3 m/s sila se smanjuje do 0 da ne titra (stajanje drzi kocnica).
-- =====================================================================
local function collectCombo(root)
    local out, seen = {}, {}
    local function add(v)
        if v == nil or seen[v] or v.isDeleted then return end
        seen[v] = true
        table.insert(out, v)
        local aj = v.spec_attacherJoints
        if aj ~= nil and aj.attachedImplements ~= nil then
            for _, impl in pairs(aj.attachedImplements) do add(impl.object) end
        end
    end
    add(root)
    return out
end


-- =====================================================================
--  v174: GUME - vuca, proklizavanje i otpor kotrljanja prema dimenziji gume i tlu
--  Brixius (1987) / ASABE D497.4: Bn = (CI*b*d/W)*(1+5*dh)/(1+3*b/d)
--      GTR = 0,88(1-e^(-0,1Bn))(1-e^(-7,5s)) + 0,04;  MRR = 1/Bn + 0,04 + 0,5s/sqrt(Bn)
--  b/d = sirina/promjer gume (iz igre), W = teret kotaca (kN), CI = cvrstoca tla (kPa) iz podloge
--  igre (FieldGroundType) i vlage, dh = ugib gume/visina boka (tlak za polje, zadano 0,22).
--  Koristi se RELATIVNO prema tvornickoj gumi (16.9R28 / 20.8R38, 1,3 / 2,4 t po kotacu):
--  trenje (vrh krivulje) i krutost (nagib = proklizavanje pri umjerenoj vuci) skaliraju se
--  omjerom; igra i dalje mnozi teretom (utezi rade sami). Cesta/tvrdo: sirina ne mijenja nista,
--  samo kalibracija krutosti (tyreModel#stiffRoad, Nebraska 1807: 24 kN ~1,3 %, 48 kN ~2,3 %).
--  Duple gume: igra siri jedan fizicki kotac -> n = 2 gume, svaka nosi pola tereta.
--  Dodaci (Darijan 9.10.): mokra trava (sklisko), bocna krutost, dno brazde pri oranju (desni kotaci).
--  ODSTUPANJE: Brixius +-25-50 % (zato relativno); oblik krivulje PhysX gume je fiksan.
-- =====================================================================

-- =====================================================================
--  v175: TLAK U GUMAMA (RShift + Num +/-, drzi se). ODSTUPANJE: pravi 7810 nema regulaciju tlaka iz kabine.
--  Tlak se mijenja dok je tipka pritisnuta: ispumpavanje 0,01 bar/s, pumpanje 0,005 bar/s (kompresor; procjena).
--  Raspon 0,8-2,4 bar, zadano 1,6. Tlak -> ugib gume (v174 Brixius): nizi = veci otisak = vise vuce na polju.
--  Cesta: nizi tlak = veci otpor kotrljanja, mekse bocno; upozorenje < 1,2 bar iznad 30 km/h ili prenizak za teret.
-- =====================================================================
JD.TYRE_BAR_MIN, JD.TYRE_BAR_MAX, JD.TYRE_BAR_DEF = 0.8, 2.4, 1.6
function JD.tyreBar(vehicle)
    local P = JD.pmStates ~= nil and JD.pmStates[vehicle] or nil
    local b = (P ~= nil and P.tyreBar) or (vehicle ~= nil and vehicle.jd7810TyreBar) or JD.TYRE_BAR_DEF
    if b < JD.TYRE_BAR_MIN then b = JD.TYRE_BAR_DEF end           -- staro spremanje (0) -> zadano
    return math.min(b, JD.TYRE_BAR_MAX)
end
local function setTyreBar(vehicle, b)
    b = clamp(b, JD.TYRE_BAR_MIN, JD.TYRE_BAR_MAX)
    local P = JD.pmStates ~= nil and JD.pmStates[vehicle] or nil
    if P ~= nil then P.tyreBar = b end
    vehicle.jd7810TyreBar = b
end
-- ugib/visina boka iz tlaka (procjena iz tablica Michelin/Trelleborg): 2,4 -> 0,13 ... 0,8 -> 0,28
function JD.tyreDeflFromBar(b)
    if b >= 2.0 then return 0.15 - (b - 2.0) * 0.05 end
    if b >= 1.6 then return 0.18 - (b - 1.6) * 0.075 end
    if b >= 1.2 then return 0.22 - (b - 1.2) * 0.10 end
    return 0.28 - (b - 0.8) * 0.15
end
function JD.actionTyre(vehicle, actionName, inputValue, callbackState, isAnalog)
    local motor = vehicle.getMotor ~= nil and vehicle:getMotor() or nil
    if motor == nil or not isOurs(motor) then return end
    local now = g_time or 0
    if inputValue == nil or inputValue == 0 then motor.jd7810TyreKeyT = nil; return end
    local last = motor.jd7810TyreKeyT or now
    motor.jd7810TyreKeyT = now
    local dt = clamp(now - last, 0, 100) / 1000
    local dir = callbackState or 1
    local rate = dir > 0 and (JD.cfg.tyreInflate or 0.005) or (JD.cfg.tyreDeflate or 0.01)
    local b0 = JD.tyreBar(vehicle)
    local b = b0 + dir * rate * dt
    setTyreBar(vehicle, b)
    motor.jd7810TyreMsgT = motor.jd7810TyreMsgT or 0
    if now - motor.jd7810TyreMsgT > 400 or (b <= JD.TYRE_BAR_MIN or b >= JD.TYRE_BAR_MAX) then
        motor.jd7810TyreMsgT = now
        JD.U.setEvent(string.format("Tyre pressure %.2f bar %s", JD.tyreBar(vehicle), dir > 0 and "(inflating)" or "(deflating)"))
    end
end
-- upozorenja (iz updateRolling, ~1 s)
function JD.tyreWarn(motor, vehicle, loadR)
    local now = g_time or 0
    if now - (motor.jd7810TyreWarnT or 0) < 10000 then return end
    local b = JD.tyreBar(vehicle)
    local spd = math.abs(vehicle.lastSpeedReal or 0) * 3600
    local msg = nil
    if b < 1.2 and spd > 30 then msg = string.format("Tyre pressure %.1f bar too low for %.0f km/h - tyres overheat", b, spd)
    elseif b < 1.0 and (loadR or 0) > 5.2 then msg = string.format("Tyre pressure %.1f bar too low for rear axle load %.1f t", b, loadR) end
    if msg ~= nil then motor.jd7810TyreWarnT = now; JD.U.setEvent(msg) end
end

JD.TYRE_REF = { front = { b = 0.455, d = 1.435, W = 1.3 }, rear = { b = 0.541, d = 1.849, W = 2.4 } }
local CI_TAB                                    -- [densityType] = { suho, mokro, trava }
local function ciTable()
    if CI_TAB ~= nil or FieldGroundType == nil then return CI_TAB end
    CI_TAB = {}
    local function set(names, dry, wetv, grass)
        for _, n in ipairs(names) do
            local v = FieldGroundType[n]
            if v ~= nil then CI_TAB[v] = { dry, wetv, grass } end
        end
    end
    set({ "PLOWED" }, 600, 400, false)
    set({ "CULTIVATED", "STUBBLE_TILLAGE", "SEEDBED", "ROLLED_SEEDBED", "ROLLER_LINES", "RIDGE" }, 900, 550, false)
    set({ "SOWN", "DIRECT_SOWN", "PLANTED", "RIDGE_SOWN", "HARVEST_READY", "HARVEST_READY_OTHER" }, 1200, 800, false)
    set({ "GRASS", "GRASS_CUT" }, 1200, 800, true)
    return CI_TAB
end
local function brixBn(CI, b, d, Wkn, dh)
    return (CI * b * d / math.max(Wkn, 0.5)) * (1 + 5 * dh) / (1 + 3 * b / d)
end
local function brixGtr(B, s) return 0.88 * (1 - math.exp(-0.1 * B)) * (1 - math.exp(-7.5 * s)) + 0.04 end
local function brixSlope(B) return 1 - math.exp(-0.1 * B) end

-- stanje gume (svakih 0,5 s po kotacu): fric, stiff, lat (faktori), roll (koef. kotrljanja na polju/mekom ili nil), ci, bn
function JD.tyreState(ph, wheel, isFront, wet, gt, motor, now)
    local cfg = JD.cfg
    local T = ph.jd7810Ty
    if T ~= nil and now - T.t < 500 then return T end
    T = T or {}
    T.t = now
    if ph.jd7810TyreN == nil then                   -- duple: fizicki kotac igre je siri od gume
        local w0, ws = ph.width or 0.5, ph.wheelShapeWidth or ph.width or 0.5
        ph.jd7810TyreN = (ws > 1.6 * w0) and 2 or 1
        ph.jd7810TyreB = w0
    end
    local n, b = ph.jd7810TyreN, ph.jd7810TyreB
    local d = 2 * (ph.radiusOriginal or ph.radius or 0.8)
    local okL, load = pcall(ph.getTireLoad, ph)
    load = (okL and type(load) == "number" and load > 0.05) and load or 0.5
    local Wkn = load * 9.81 / n
    local dh = cfg.tyreDefl or 0.22
    if isFront ~= nil and motor ~= nil and motor.vehicle ~= nil then dh = JD.tyreDeflFromBar(JD.tyreBar(motor.vehicle)) end   -- v175: tlak traktora
    T.fric, T.stiff, T.lat, T.roll, T.ci, T.bn = 1, 1, 1, nil, 0, 0
    if cfg.tyreModel == false then return T end
    local soft = (gt == WheelsUtil.GROUND_FIELD or gt == WheelsUtil.GROUND_SOFT_TERRAIN)
    if not soft then                                -- cesta / tvrdo: sirina gume ne mijenja vucu
        T.stiff = cfg.tyreStiffRoad or 1.0
        if isFront ~= nil and motor ~= nil and motor.vehicle ~= nil then   -- v175: nizak tlak = mekse bocno na cesti
            T.lat = 0.85 + 0.15 * clamp((JD.tyreBar(motor.vehicle) - 0.8) / 0.8, 0, 1)
        end
        return T
    end
    local tab = ciTable() or {}
    local e = (gt == WheelsUtil.GROUND_FIELD) and tab[ph.densityType] or nil
    local dry, wetv, grass
    if e ~= nil then dry, wetv, grass = e[1], e[2], e[3]
    elseif gt == WheelsUtil.GROUND_FIELD then dry, wetv, grass = 900, 550, false
    else dry, wetv, grass = 1000, 600, true end     -- meki teren izvan polja = livada / trava
    -- dno brazde: pri oranju desni kotaci voze po dnu brazde (tvrde, vlaznije)
    if cfg.tyreFurrow ~= false and motor ~= nil and motor.jd7810Plowing and gt == WheelsUtil.GROUND_FIELD and wheel ~= nil and wheel.isLeft == false then
        dry, wetv, grass = 1000, 700, false
    end
    local CI = dry + (wetv - dry) * (wet or 0)
    local B = brixBn(CI, b, d, Wkn, dh)
    local ref = isFront and JD.TYRE_REF.front or JD.TYRE_REF.rear
    local Bref = brixBn(CI, ref.b, ref.d, ref.W * 9.81, dh)
    T.ci, T.bn = CI, B
    if isFront ~= nil then                          -- samo kotaci traktora (vuca)
        local f = brixGtr(B, 0.15) / math.max(brixGtr(Bref, 0.15), 0.05)
        if grass then f = f * (1 - (cfg.tyreWetGrass or 0.25) * (wet or 0)) end
        T.fric = clamp(f, 0.5, 1.6)
        T.stiff = clamp(brixSlope(B) / math.max(brixSlope(Bref), 0.05), 0.5, 1.6) * (cfg.tyreStiffField or 1.0)
        T.lat = clamp(math.sqrt(T.fric), 0.8, 1.25)
    end
    T.roll = 1 / math.max(B, 1) + 0.04             -- otpor kotrljanja (bez proklizavanja) - svi kotaci u kombinaciji
    return T
end

local function rollCoeff(cfg, ph, wet)
    local isField = FieldGroundType ~= nil and ph.densityType ~= nil and ph.densityType ~= FieldGroundType.NONE
    local isRoad = WheelContactType ~= nil and ph.contact ~= WheelContactType.GROUND
    local gt = WheelsUtil.getGroundType(isField, isRoad, ph.groundDepth or 0)
    local c
    if gt == WheelsUtil.GROUND_FIELD then
        c = cfg.rollField * (1 + cfg.rollWet * wet)
    elseif gt == WheelsUtil.GROUND_SOFT_TERRAIN then
        c = cfg.rollSoft * (1 + cfg.rollWet * wet)
    elseif gt == WheelsUtil.GROUND_HARD_TERRAIN then
        c = cfg.rollHard * (1 + 0.5 * cfg.rollWet * wet)
    else
        c = cfg.rollRoad
    end
    if ph.hasSnowContact then c = c + 0.03 end
    return c * cfg.rollScale, gt
end

local GT_NAME = {}
function JD.updateRolling(motor, dt)
    local vehicle = motor.vehicle
    local cfg = JD.cfg
    if vehicle == nil or not vehicle.isServer or not cfg.roll or (cfg.rollScale or 0) <= 0 or WheelsUtil == nil or WheelsUtil.getGroundType == nil then
        motor.jd7810RollKN = 0
        return
    end
    if next(GT_NAME) == nil then
        GT_NAME[WheelsUtil.GROUND_ROAD or -1] = "cesta"; GT_NAME[WheelsUtil.GROUND_HARD_TERRAIN or -2] = "tvrdo"
        GT_NAME[WheelsUtil.GROUND_SOFT_TERRAIN or -3] = "meko"; GT_NAME[WheelsUtil.GROUND_FIELD or -4] = "polje"
    end
    motor.jd7810RollWetT = (motor.jd7810RollWetT or 1000) + dt
    if motor.jd7810RollWetT >= 1000 then motor.jd7810RollWetT = 0; motor.jd7810RollWet = groundWetness() end
    local wet = motor.jd7810RollWet or 0
    local total, mass, gtTractor = 0, 0, nil
    local frontSet = {}
    if motor.jd7810Diff ~= nil then for _, ph in ipairs(motor.jd7810Diff.frontWheels or {}) do frontSet[ph] = true end end
    local loadF, loadR = 0, 0                                       -- traktor: teret prednje / straznje osovine (t)
    for _, v in ipairs(collectCombo(vehicle)) do
        local sw = v.spec_wheels
        if v.isAddedToPhysics and sw ~= nil and sw.wheels ~= nil then
            for _, wheel in ipairs(sw.wheels) do
                local ph = wheel.physics
                local node = wheel.node
                if ph ~= nil and ph.wheelShapeCreated and ph.hasGroundContact and node ~= nil and node ~= 0 and entityExists(node)
                   and ph.lastContactX ~= nil and type(ph.getTireLoad) == "function" then
                    local load = ph:getTireLoad() or 0                         -- t
                    -- v118b: prianjanje guma traktora na polju (igra na obradenom tlu daje ~0,38 i tek uz 50 % proklizavanja;
                    -- radijalne gume ~0,45-0,55 uz 10-15 %, ASABE D497). Test 05.10.: x1,3 nije promijenio proklizavanje -> zadano 1,0 (iskljuceno), postavka tractionField
                    if v == vehicle and ph.frictionScale ~= nil then
                        if ph.jd7810FricBase == nil then
                            ph.jd7810FricBase = ph.frictionScale
                            log(string.format("prianjanje: kotac r %.3f, tireType %s, frictionScale %.2f, trenje tlo %.2f, maxLongStiffness %s",
                                ph.radius or -1, tostring(ph.tireType), ph.frictionScale, ph.tireGroundFrictionCoeff or -1, tostring(ph.maxLongStiffness)))
                        end
                        -- v136: trenje po tlu igre (WheelsUtil.getGroundType): cesta/tvrdo x tractionRoad (zadano 0,72 -> 1,15:
                        -- guma na suhom asfaltu drzi ~0,7-0,8 g, pa u ostrom zavoju proklizava umjesto da se traktor prevrne),
                        -- polje/meko x tractionField (zadano 1,0 = vuca kao igra). Prijelaz glatko (0,5 s) da nema trzaja.
                        local _, gtF = rollCoeff(cfg, ph, wet)
                        local fac = (gtF == WheelsUtil.GROUND_ROAD or gtF == WheelsUtil.GROUND_HARD_TERRAIN) and (cfg.tractionRoad or 1.0) or (cfg.tractionField or 1.0)
                        -- v174: guma (sirina, promjer, duple, teret) x tlo (vrsta, vlaga, trava, brazda)
                        local T = JD.tyreState(ph, wheel, frontSet[ph] == true, wet, gtF, motor, g_time or 0)
                        fac = fac * T.fric
                        if ph.jd7810LongBase == nil then ph.jd7810LongBase, ph.jd7810LatBase = ph.maxLongStiffness, ph.maxLatStiffness end
                        if ph.jd7810LongBase ~= nil then
                            local wl, wa = ph.jd7810LongBase * T.stiff, (ph.jd7810LatBase or 0) * T.lat
                            if math.abs(wl - (ph.maxLongStiffness or wl)) > 0.02 * ph.jd7810LongBase
                               or (ph.jd7810LatBase ~= nil and math.abs(wa - (ph.maxLatStiffness or wa)) > 0.02 * ph.jd7810LatBase) then
                                ph.maxLongStiffness, ph.maxLatStiffness = wl, (ph.jd7810LatBase ~= nil) and wa or ph.maxLatStiffness
                                ph.isFrictionDirty = true
                            end
                        end
                        local want = ph.jd7810FricBase * fac
                        local cur = ph.frictionScale
                        local k = math.min(1, dt / 500)
                        local nxt = cur + (want - cur) * k
                        if math.abs(nxt - cur) > 0.0005 then ph.frictionScale = nxt; ph.isFrictionDirty = true end
                    end
                    if load > 0 then
                        mass = mass + load
                        if v == vehicle then
                            if frontSet[ph] then loadF = loadF + load else loadR = loadR + load end
                        end
                        local c, gt = rollCoeff(cfg, ph, wet)
                        if cfg.tyreModel ~= false and (gt == WheelsUtil.GROUND_FIELD or gt == WheelsUtil.GROUND_SOFT_TERRAIN) then
                            local T = (v == vehicle and ph.jd7810Ty ~= nil) and ph.jd7810Ty or JD.tyreState(ph, wheel, nil, wet, gt, motor, g_time or 0)   -- traktor: vec izracunato gore
                            if T.roll ~= nil then                -- v174: Brixius (1/Bn + 0,04), snijeg dodaje
                                c = (T.roll + (ph.hasSnowContact and 0.03 or 0)) * cfg.rollScale
                            end
                        end
                        if v == vehicle and cfg.tyreModel ~= false and gt ~= WheelsUtil.GROUND_FIELD and gt ~= WheelsUtil.GROUND_SOFT_TERRAIN then
                            c = c * (1 + 0.2 * math.max(0, 1.6 - JD.tyreBar(vehicle)) / 0.8)   -- v175: 0,8 bar = +20 % na asfaltu
                        end
                        if v == vehicle and gtTractor == nil then gtTractor = gt end
                        local cx, cy, cz = ph.lastContactX, ph.lastContactY, ph.lastContactZ
                        local vx, vy, vz = getVelocityAtWorldPos(node, cx, cy, cz)
                        local fx, fy, fz = localDirectionToWorld(node, 0, 0, 1)
                        local vl = vx * fx + vy * fy + vz * fz                   -- m/s uzduz kotaca
                        local F = c * load * 9.81 * math.min(math.abs(vl) / 0.3, 1)  -- kN
                        if F > 0 and not ((cfg.driveTest or 0) >= 1 and JD.testPhase == 5) then
                            local f = -F * (vl >= 0 and 1 or -1)
                            -- v118c: hvatiste u tezistu tijela (kao PowerConsumer igre). U tocki dodira kotaca sila je
                            -- (test 05.10.) izazivala 40-60 % proklizavanja i skretanje ulijevo; bez nje 5-10 %.
                            local mx, my, mz = getCenterOfMass(node)
                            addForce(node, fx * f, fy * f, fz * f, mx, my, mz, true)
                            total = total + F
                        end
                    end
                end
            end
        end
    end
    motor.jd7810RollKN, motor.jd7810RollMass = total, mass
    motor.jd7810AxleF, motor.jd7810AxleR = loadF, loadR
    if JD.tyreWarn ~= nil and cfg.tyreModel ~= false then pcall(JD.tyreWarn, motor, vehicle, loadR) end   -- v175
    if cfg.draftLog and (total > 0.05 or loadF > 0) then
        motor.jd7810RollLogT = (motor.jd7810RollLogT or 0) + dt
        if motor.jd7810RollLogT >= 2000 then
            motor.jd7810RollLogT = 0
            local okR, rpm = pcall(motor.getLastMotorRpm, motor)
            local okL, ld = pcall(motor.getSmoothLoadPercentage, motor)
            local axle = (loadF > 0 and loadF + loadR > 0) and string.format(" | traktor sprijeda %.2f t / straga %.2f t (%.0f %% naprijed), MFWD %s",
                loadF, loadR, loadF / (loadF + loadR) * 100, motor.jd7810MfwdOn and "ukljucen" or "iskljucen") or ""
            -- dijagnoza: brzina vrtnje kotaca (m/s po obodu) sprijeda/straga, brzina, stupanj, spojka, puzanje, rucni gas
            local wsF, wsR, nF, nR = 0, 0, 0, 0
            local sw = vehicle.spec_wheels
            if sw ~= nil and sw.wheels ~= nil then
                for _, wheel in ipairs(sw.wheels) do
                    local ph = wheel.physics
                    if ph ~= nil and ph.netInfo ~= nil and ph.netInfo.xDriveSpeed ~= nil then
                        local ms = ph.netInfo.xDriveSpeed * (ph.radius or 0.5)
                        if frontSet[ph] then wsF, nF = wsF + ms, nF + 1 else wsR, nR = wsR + ms, nR + 1 end
                    end
                end
            end
            local okC, clutchV = pcall(motor.getManualClutchPedal, motor)
            axle = axle .. string.format(" | kotaci sprijeda %.2f / straga %.2f m/s (vozilo %.2f m/s), brzina %s smjer %s, spojka %s, puzanje %s, rucni gas %.0f",
                nF > 0 and wsF / nF or 0, nR > 0 and wsR / nR or 0, (vehicle.lastSpeedReal or 0) * 1000 * (vehicle.movingDirection or 1),
                tostring(motor.gear) .. "/" .. tostring(motor.activeGearGroupIndex), tostring(motor.currentDirection), okC and string.format("%.2f", clutchV or 0) or "?", tostring(motor.jd7810Creep), motor.jd7810HandRpm or 0)
            -- dijagnoza po kotacu: komponenta, polumjer, kutna brzina (igra / motor), brzina tla na dodiru, proklizavanje, teret
            if sw ~= nil and sw.wheels ~= nil then
                local fx, fy, fz = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
                local parts = {}
                for i, wheel in ipairs(sw.wheels) do
                    local ph = wheel.physics
                    if ph ~= nil then
                        local r = ph.radius or 0.5
                        local wNet = ph.netInfo ~= nil and ph.netInfo.xDriveSpeed or 0
                        local wEng = nil
                        if getWheelShapeAxleSpeed ~= nil and wheel.node ~= nil and ph.wheelShape ~= nil and ph.wheelShapeCreated then
                            local okA, a = pcall(getWheelShapeAxleSpeed, wheel.node, ph.wheelShape)
                            if okA then wEng = a end
                        end
                        local vg = nil
                        if ph.hasGroundContact and ph.lastContactX ~= nil and wheel.node ~= nil then
                            local okV, vx, vy, vz = pcall(getVelocityAtWorldPos, wheel.node, ph.lastContactX, ph.lastContactY, ph.lastContactZ)
                            if okV and vx ~= nil then vg = vx * fx + vy * fy + vz * fz end
                        end
                        local w = wEng or wNet
                        local surf = w * r
                        local slip = (vg ~= nil and math.abs(surf) > 0.2) and (surf - vg) / surf * 100 or 0
                        local okT, tl = pcall(ph.getTireLoad, ph)
                        local Ty = ph.jd7810Ty
                        table.insert(parts, string.format("%d%s k%s s%s r%.3f w%.2f/%s obod %.2f tlo %s slip %.0f%% %.2ft b%.2f | guma %s n%d ci %.0f bn %.0f f%.2f k%.2f rr %s",
                            i, frontSet[ph] and "F" or "R", wheel.node == vehicle.rootNode and "1" or "2", tostring(ph.wheelShape), r, wNet,
                            wEng and string.format("%.2f", wEng) or "-", surf, vg and string.format("%.2f", vg) or "-", slip,
                            okT and (tl or 0) or -1, ph.brakeFactor or -1,
                            string.format("%.2f", ph.jd7810TyreB or ph.width or 0), ph.jd7810TyreN or 1, Ty and Ty.ci or 0, Ty and Ty.bn or 0,
                            Ty and Ty.fric or 1, Ty and Ty.stiff or 1, (Ty and Ty.roll) and string.format("%.3f", Ty.roll) or "-"))
                    end
                end
                log("TEST kotaci: " .. table.concat(parts, " | ") .. " | pogon " .. tostring(motor.jd7810DriveKey))
            end
            local gameF = ""
            for _, im in ipairs((JD.getImplements ~= nil and JD.getImplements(vehicle)) or {}) do
                local pc = im.object ~= nil and im.object.spec_powerConsumer or nil
                if pc ~= nil and (pc.maxForce or 0) > 0 then
                    local okM, mult = pcall(im.object.getPowerMultiplier, im.object)
                    gameF = gameF .. string.format(" | prikljucak maxForce %.1f kN x mnozitelj %s, forceFactor %s", pc.maxForce, okM and string.format("%.2f", mult or -1) or "?", tostring(pc.forceFactor))
                end
            end
            axle = axle .. gameF
            log(string.format("TEST kotrljanje: %.1f kN, teret na kotacima %.1f t (traktor + prikljucci), podloga traktora %s, vlaga %.2f, %.1f km/h | motor %.0f o/min, opterecenje %.0f%%%s",
                total, mass, tostring(GT_NAME[gtTractor] or gtTractor), wet, math.abs(vehicle.lastSpeedReal or 0) * 3600, okR and rpm or -1, okL and (ld or 0) * 100 or -1, axle))
        end
    end
end

function JD.updateDraft(motor, dt)
    local vehicle = motor.vehicle
    if vehicle == nil or not vehicle.isServer then return end
    motor.jd7810DraftT = (motor.jd7810DraftT or 0) + dt
    if motor.jd7810DraftT < 100 then return end
    motor.jd7810DraftT = 0
    local cfg = JD.cfg
    local attached = {}
    local totalKN, totalKW = 0, 0
    local workList = {}
    local testNoDraft = (cfg.driveTest or 0) >= 1 and JD.testPhase == 4
    local plowing = false
    if cfg.draft and not testNoDraft and JD.getImplements ~= nil then
        local wet
        for _, im in ipairs(JD.getImplements(vehicle)) do
            local tool = im.object
            local catKey = tool ~= nil and category(tool) or nil
            if catKey ~= nil then
                attached[tool] = true
                local st = JD.draftTools[tool] or take(vehicle, tool, catKey)
                if st ~= nil then
                    local kN = 0
                    if isWorking(tool) then
                        wet = wet or groundWetness()
                        local v = math.abs(tool.lastSpeedReal or 0) * 3600
                        local okW, w = pcall(JD.U.toolWidth, tool)
                        w = okW and w or 0
                        local sc = JD.pmScaled ~= nil and JD.pmScaled[tool] or nil   -- PM WDTH +10/+20 % ne mijenja stvarnu sirinu za vucu
                        if sc ~= nil and (sc.factor or 1) > 0 then w = w / sc.factor end
                        st.width = w
                        kN = JD.draftForceN(tool, catKey, v, w, wet) / 1000
                        totalKW = totalKW + kN * v / 3.6
                        -- v121: popis radnih alata - izbor brzine za kretanje racuna vucu pri brzini SVAKOG stupnja
                        -- (ASABE: Smaragd 25,8 kN pri 0 km/h, 38 kN pri 8 km/h)
                        workList[#workList + 1] = { tool = tool, cat = catKey, w = w, wet = wet }
                        if catKey == "plow" then plowing = true end                   -- v174: dno brazde (desni kotaci)
                    end
                    local pc = tool.spec_powerConsumer
                    if st.lastSet ~= nil and pc.maxForce ~= st.lastSet then
                        st.orig.maxForce = pc.maxForce        -- igra je sama promijenila silu (npr. duboko/plitko) - to je novi original
                    end
                    st.kN = kN
                    pc.maxForce = kN
                    st.lastSet = kN
                    totalKN = totalKN + kN
                    if cfg.draftLog and math.abs(tool.lastSpeedReal or 0) * 3600 > 1 then
                        st.logT = (st.logT or 0) + 1
                        if st.logT >= 20 then
                            st.logT = 0
                            local okM, mult = pcall(tool.getPowerMultiplier, tool)
                            local okR, rpm = pcall(motor.getLastMotorRpm, motor)
                            local okL, load = pcall(motor.getSmoothLoadPercentage, motor)
                            local okW, w = true, st.width or -1
                            log(string.format("TEST %s (radi %s): %.1f m, %.1f km/h, sila %.1f kN (izvorno %s), mnozitelj %s, smjer %s | motor %.0f o/min, opterecenje %.0f%% | IVT birac %s, prozor %.0f-%.0f, teret %s, ogranicenje %.1f km/h | stupanj %s, ucinak %.0f%%",
                                JD.DRAFT_CAT[catKey].name, tostring(isWorking(tool)), okW and w or -1, math.abs(tool.lastSpeedReal or 0) * 3600, kN, tostring(st.orig.maxForce),
                                okM and string.format("%.2f", mult or -1) or "?", tostring(tool.movingDirection),
                                okR and rpm or -1, okL and (load or 0) * 100 or -1,
                                tostring(motor.jd7810IvtMode), motor.jd7810IvtLo or -1, motor.jd7810IvtHi or -1, tostring(motor.jd7810IvtUnder),
                                JD.U.getSpeedLimitKmh(motor), tostring(motor.jd7810IvtRange), (motor.jd7810IvtEff or 1) * 100))
                        end
                    end
                end
            end
        end
    end
    for tool, st in pairs(JD.draftTools) do
        if st.owner == vehicle and not attached[tool] then restore(tool) end
    end
    motor.jd7810DraftKN, motor.jd7810DraftKW = totalKN, totalKW
    motor.jd7810DraftList = workList
    motor.jd7810Plowing = plowing                                         -- v174
    if cfg.debug and totalKN > 0 then
        motor.jd7810DraftLog = (motor.jd7810DraftLog or 0) + 1
        if motor.jd7810DraftLog >= 10 then
            motor.jd7810DraftLog = 0
            log(string.format("vuca: %.1f kN, %.0f kW (%.0f KS) na poteznici, brzina %.1f km/h, vlaga %.2f",
                totalKN, totalKW, totalKW * 1.36, math.abs(vehicle.lastSpeed or 0) * 3600, groundWetness()))
        end
    end
end

VehicleMotor.update = Utils.appendedFunction(VehicleMotor.update, function(self, dt)
    if isOurs(self) then
        local ok, err = pcall(JD.updateDraft, self, dt)
        if not ok and not self.jd7810DraftErr then self.jd7810DraftErr = true; log("vuca: greska " .. tostring(err)) end
        local okR, errR = pcall(JD.updateRolling, self, dt)
        if not okR and not self.jd7810RollErr then self.jd7810RollErr = true; log("kotrljanje: greska " .. tostring(errR)) end
    end
end)
