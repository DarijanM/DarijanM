-- =====================================================================
--  JD7810Transmission.lua   v8.1  (FS25 - osobna upotreba, Darijan)
--  mjenjaci: ukljucivanje brzine, kretanje s mjesta, AutoQuad II (automatski/rucno), vlastiti automatik, radna voznja (LCtrl+1), IVT regulacija (birac OFF/1/2/3 Num 9, Field Cruise Num *), IVT trake 1/2 (Num /) i zadane brzine (LAlt+Num +/-)
--  v8.1: podjela JD7810Transmission.lua v8.0 na module - kod premjesten
--        bez promjene ponasanja. Redoslijed ucitavanja u modDesc.xml:
--        Core, Transmission, Engine, PTO, Display, PerformanceMonitor, AgroGsm, Cockpit
-- =====================================================================

local JD = JD7810Transmission
local clamp = JD.U.clamp
local getAccelerationMS2 = JD.U.getAccelerationMS2
local getShiftPoints = JD.U.getShiftPoints
local getSpeedKmh = JD.U.getSpeedKmh
local isAIActive = JD.U.isAIActive
local isOurs = JD.U.isOurs
local log = JD.U.log
local setEvent = JD.U.setEvent

-- =====================================================================
--  A) Ukljucivanje nove brzine: proklizavanje na nizu, pad snage, razmak
-- =====================================================================
VehicleMotor.applyTargetGear = Utils.overwrittenFunction(VehicleMotor.applyTargetGear, function(self, superFunc)
    local motorRotSpeed = self.motorRotSpeed or 0
    local diffRotSpeed = math.abs(self.differentialRotSpeed or 0)

    superFunc(self)

    if not isOurs(self) or self.gearShiftMode == VehicleMotor.SHIFT_MODE_MANUAL_CLUTCH then
        return
    end

    local cfg = JD7810Transmission.cfg
    local target = self.maxGearRatio or 0
    local moving = getSpeedKmh(self) > cfg.minSpeed and diffRotSpeed > 0.5
    local onThrottle = math.abs(self.lastAcceleratorPedal or 0) > 0.1

    self.jd7810LastShift = g_time or 0

    if target == 0 or not moving then
        return
    end

    -- pad snage kod powershifta (spojke se prekrivaju, nije instant)
    if onThrottle and cfg.shiftDip > 0 and cfg.shiftDipTime > 0 then
        self.jd7810DipTime = cfg.shiftDipTime
        self.jd7810DipTimer = cfg.shiftDipTime
    end

    -- proklizavanje spojke ako je niza brzina (veci omjer)
    if cfg.slip then
        local current = motorRotSpeed / diffRotSpeed
        if math.abs(target) > current * 1.03 then
            local slipTime = math.abs(self.lastAcceleratorPedal or 0) > 0.3 and cfg.slipTimeLoad or cfg.slipTime
            if slipTime > 0 then
                self.jd7810SlipFrom = math.max(current, math.abs(target) * 0.5) * math.sign(target)
                self.jd7810SlipTime = slipTime
                self.jd7810SlipTimer = slipTime
            end
        end
    end
end)

VehicleMotor.getMinMaxGearRatio = Utils.overwrittenFunction(VehicleMotor.getMinMaxGearRatio, function(self, superFunc)
    local minRatio, maxRatio = superFunc(self)
    -- Powershift natrag: R1-R7 prema tablici (grupe su stupnjevi naprijed)
    if (minRatio < 0 or maxRatio < 0) and JD7810Transmission.psReverseRatio ~= nil and JD7810Transmission.isStepBox ~= nil
       and JD7810Transmission.isStepBox(self) and JD7810Transmission.motorKind(self) == "PS" then
        local r = JD7810Transmission.psReverseRatio(self, self.activeGearGroupIndex)
        if r ~= nil then minRatio, maxRatio = -r, -r end
    end
    if self.jd7810SlipTimer ~= nil and self.jd7810SlipTimer > 0 then
        if (minRatio ~= 0 or maxRatio ~= 0) and math.sign(maxRatio) == math.sign(self.jd7810SlipFrom) then
            local alpha = self.jd7810SlipTimer / math.max(self.jd7810SlipTime or 1, 1)
            minRatio = MathUtil.lerp(minRatio, self.jd7810SlipFrom, alpha)
            maxRatio = MathUtil.lerp(maxRatio, self.jd7810SlipFrom, alpha)
        else
            self.jd7810SlipTimer = 0
        end
    end
    return minRatio, maxRatio
end)

-- =====================================================================
--  C) Gas: turbo rupa + pad snage pri prebacivanju
-- =====================================================================
-- ---------------------------------------------------------------------
--  BRZINA ZA KRETANJE prema tezini (traktor + prikljucci + prikolice), nagibu i vuci
--  potrebna sila  F = m * (g * (otpor kotrljanja + nagib) + zeljeno ubrzanje) + vuca prikljucka   [kN, m u t]
--  sila u stupnju F = moment motora pri kretanju * omjer (omjer = rad/s motora po m/s)          [kN]
--  bira se NAJVISI stupanj koji jos krene s rezervom (preskace stupnjeve); naprijed i natrag.
--  Powershift: najvise 16F / 6R (OMAR206904: iz N izravno do 16F ili 6R).
--  Zamjenjuje VehicleMotor.getBestStartGear igre (igra ga zove kad stoji i kad se doda gas).
-- ---------------------------------------------------------------------
local function startForceNeeded(motor)
    local cfg = JD7810Transmission.cfg
    local v = motor.vehicle
    local mass = 0
    if v.getTotalMass ~= nil then local ok, m = pcall(v.getTotalMass, v, false); if ok and type(m) == "number" then mass = m end end
    if mass <= 0 then mass = 6 end
    local slope = 0
    if v.rootNode ~= nil then
        local dx, dy, dz = localDirectionToWorld(v.rootNode, 0, 0, 1)
        slope = dy or 0
        -- v121: nagib iz TERENA (+-2 m ispred/iza), ne iz nagiba tijela: pri kocenju s prikljuckom tijelo se nagne
        -- pa je 'rad' skakao 34-49 kN za isti kultivator (izbor B1-B3). Rezerva: nagib tijela.
        local tr = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
        local hl = math.sqrt((dx or 0) ^ 2 + (dz or 0) ^ 2)
        if tr ~= nil and hl > 0.5 and getTerrainHeightAtWorldPos ~= nil then
            local x, _, z = getWorldTranslation(v.rootNode)
            local ux, uz = dx / hl, dz / hl
            local okF, hF = pcall(getTerrainHeightAtWorldPos, tr, x + ux * 2, 0, z + uz * 2)
            local okB, hB = pcall(getTerrainHeightAtWorldPos, tr, x - ux * 2, 0, z - uz * 2)
            if okF and okB and type(hF) == "number" and type(hB) == "number" then
                slope = (hF - hB) / 4
            end
        end
        slope = slope * ((motor.currentDirection or 1) >= 0 and 1 or -1)   -- uzbrdo u smjeru voznje > 0
    end
    local draft = (motor.jd7810DraftKN or 0)
    return mass * (9.81 * ((cfg.startRoll or 0.08) + math.max(slope, -0.05)) + (cfg.startAcc or 0.35)) + draft, mass, slope
end

-- ---------------------------------------------------------------------
--  S) MJENJACI SA STUPNJEVIMA POD OPTERECENJEM (GIANTS konvencija: GRUPE = powershift)
--     AutoQuad II: brzine A-E = rasponi (spojka), grupe 1-4 = powershift
--     Powershift 19/7: jedna brzina, grupe 1-19 = stupnjevi; natrag R1-R7 (omjer iz tablice)
-- ---------------------------------------------------------------------
function JD7810Transmission.isStepBox(motor)
    if not isOurs(motor) or motor.gearGroups == nil or JD7810Transmission.motorKind == nil then return false end
    local k = JD7810Transmission.motorKind(motor)
    return k == "AQ" or k == "PS"
end
local isStepBox = JD7810Transmission.isStepBox

-- PS natrag R1-R7 km/h pri 2100 (OMAR206904, 20.8R38)
JD7810Transmission.PS_REVERSE = { 2.6, 3.7, 5.7, 6.6, 7.4, 8.6, 16.6 }
function JD7810Transmission.psReverseRatio(motor, step)
    local k = math.max(1, math.min(step or 1, #JD7810Transmission.PS_REVERSE))
    local v = JD7810Transmission.PS_REVERSE[k] * (motor.maxRpm or 2300) / 2100 / 3.6      -- m/s pri maxRpm
    return ((motor.maxRpm or 2300) * math.pi / 30) / v * (motor.jd7810TyreFactor or 1)
end

-- omjer (rad/s motora po m/s) za brzinu + stupanj; PS natrag po tablici
local function stepRatio(motor, gears, gear, step, reverse)
    if JD7810Transmission.motorKind(motor) == "PS" and reverse then
        return JD7810Transmission.psReverseRatio(motor, step)
    end
    local g = gears ~= nil and gears[gear] or nil
    local gr = motor.gearGroups[step] ~= nil and math.abs(motor.gearGroups[step].ratio or 1) or 1
    if g == nil or type(g.ratio) ~= "number" then return nil end
    return math.abs(g.ratio * gr)
end
JD7810Transmission.stepRatio = stepRatio

-- automatsko mijenjanje stupnjeva: automatski nacin igre; u rucnom i rucnom sa spojkom samo AQ AUTO/ECO naprijed
-- (stupnjevi 1-4; rasponi, smjer i Powershift su tvoji; igra i dalje gasi motor bez spojke kao pravi traktor)
function JD7810Transmission.stepAutoActive(motor)
    if not isStepBox(motor) or isAIActive(motor.vehicle) or not JD7810Transmission.cfg.autoShift then return false end
    local mode = motor.gearShiftMode
    if mode == VehicleMotor.SHIFT_MODE_AUTOMATIC then return true end
    -- rucno i rucno sa spojkom: samo AQ AUTO/ECO naprijed mijenja 1-4 sam (kao pravi AQ II - spojku ima uvijek);
    -- rasponi A-E i Powershift ostaju tvoji
    return JD7810Transmission.motorKind(motor) == "AQ" and (motor.jd7810AqMode or 1) >= 1 and (motor.currentDirection or 1) > 0
end

-- najbolja brzina + stupanj za kretanje (najvisi koji krene s rezervom)
function JD7810Transmission.bestStart(motor)
    local cfg = JD7810Transmission.cfg
    local gears = motor.currentGears
    if gears == nil or #gears == 0 then return nil end
    local ok, need = pcall(startForceNeeded, motor)
    if not ok then return nil end
    local tq = 0.785
    local okT, t = pcall(motor.getTorqueCurveValue, motor, cfg.startRpm or 1300)
    if okT and type(t) == "number" and t > 0 then tq = t end
    local reserve = cfg.startReserve or 1.3
    local maxRad = (motor.maxRpm or 2300) * math.pi / 30
    local reverse = (motor.currentDirection or 1) < 0
    local kind = JD7810Transmission.motorKind(motor)
    local maxStep = #motor.gearGroups
    if kind == "PS" then maxStep = reverse and 6 or 16 end                  -- OMAR206904: iz N izravno do 16F / 6R
    local gearList = { (motor.gear ~= nil and motor.gear ~= 0) and motor.gear or 1 }
    if kind == "AQ" and cfg.startRange and motor.gearShiftMode == VehicleMotor.SHIFT_MODE_AUTOMATIC then
        gearList = {}
        for i = 1, #gears do gearList[i] = i end
    end
    -- v120: pod radnim teretom (spusten obradni prikljucak) brzina za kretanje mora i VUCI na radnim okretajima:
    -- sila rada (vuca + kotrljanje + nagib) x rezerva <= k x moment(workRpm) x omjer. k = iskoristivost pogona
    -- kako je igra stvarno mjeri (sila / (teret x moment x omjer)), uci se u voznji (zadano 0,73 iz testa 05.10.:
    -- Smaragd 30 kN, C1 7,7 km/h, 1950 o/min, 90 %). Prije je krenuo u C2/C3 i odmah spustio u C1.
    local draft = motor.jd7810DraftKN or 0
    local workNeed = 0
    local okN2, _, massW, slopeW = pcall(startForceNeeded, motor)
    if draft > 1 and okN2 and massW ~= nil then
        -- vuca pri stajanju je manja od radne (ovisi o brzini) - uzmi zapamcenu radnu vucu ovog prikljucka
        local dUse = math.max(draft * (cfg.startDraftGrow or 1.05), motor.jd7810WorkDraft or 0)
        workNeed = massW * 9.81 * ((cfg.rollField or 0.05) + math.max(slopeW or 0, 0)) + dUse
    end
    local workBase = workNeed > 0 and (workNeed - math.max(draft * (cfg.startDraftGrow or 1.05), motor.jd7810WorkDraft or 0)) or 0
    -- v121: vuca alata ovisi o brzini (ASABE) - za svaki stupanj racunaj vucu pri njegovoj radnoj brzini
    -- (brzina pri workSpeedRpm 2000 o/min), ne jedan broj za sve stupnjeve
    local list = motor.jd7810DraftList
    local function draftAt(vKmh)
        if list == nil or #list == 0 or JD7810Transmission.draftForceN == nil then return nil end
        local n = 0
        for _, e in ipairs(list) do
            local okD, f = pcall(JD7810Transmission.draftForceN, e.tool, e.cat, vKmh, e.w, e.wet)
            if okD and type(f) == "number" then n = n + f / 1000 end
        end
        return n
    end
    local maxRpmS = motor.maxRpm or 2300
    local workSpeedRpm = cfg.startWorkSpeedRpm or 2000
    -- v121: test 05.10. (Smaragd, rad ~42 kN): B4/C1 vukao na 1880 o/min uz 80 % tereta -> provjera na 1750 o/min
    -- bez dodatne rezerve (motor ima porast momenta do 1400); 1900 + 1,1 bilo je prestrogo (B1-B3).
    local workRpm = cfg.startWorkRpm or 1750
    local tqW = tq
    local okW, tw = pcall(motor.getTorqueCurveValue, motor, workRpm)
    if okW and type(tw) == "number" and tw > 0 then tqW = tw end
    local eff = motor.jd7810DriveEff or 0.76
    -- v152: provjera kretanja racunala je silu bez gubitaka pogona (moment x omjer) -> s 33,7 t PS je krenuo u 13F
    -- (test 07.10.) pa odmah pao u 10F. Sada sila na kotacima = iskoristivost x moment x omjer (kao igra mjeri).
    local effS = math.max(0.6, math.min(0.9, eff))
    local bestGear, bestStep, bestSpeed = gearList[1], 1, -1
    local bestNeed = workNeed
    local lowGear, lowStep, lowSpeed = gearList[1], 1, math.huge     -- rezerva: najsporija (ako nista ne zadovoljava)
    for _, gi in ipairs(gearList) do
        for st = 1, maxStep do
            local ratio = stepRatio(motor, gears, gi, st, reverse)
            if ratio ~= nil and ratio > 0 then
                local vmax = maxRad / ratio * 3.6
                local needG = workNeed
                if workNeed > 0 then
                    local dG = draftAt(vmax * workSpeedRpm / maxRpmS)
                    if dG ~= nil then needG = workBase + dG end
                end
                local workOk = needG <= 0 or needG * (cfg.startWorkReserve or 1.0) <= eff * tqW * ratio
                if workOk and needG > 0 and vmax > bestSpeed and effS * tq * ratio >= need * reserve and vmax <= (cfg.startMaxKmh or 15) then
                    bestNeed = needG
                end
                if effS * tq * ratio >= need * reserve and workOk and vmax <= (cfg.startMaxKmh or 15) and vmax > bestSpeed then
                    bestGear, bestStep, bestSpeed = gi, st, vmax
                end
                if vmax < lowSpeed then lowGear, lowStep, lowSpeed = gi, st, vmax end
            end
        end
    end
    if bestSpeed < 0 then bestGear, bestStep = lowGear, lowStep end
    motor.jd7810StartInfo = workNeed > 0 and string.format("needed %.1f kN, work %.1f kN (draft + rolling %.1f + slope), k %.2f", need, bestNeed, workBase, eff) or string.format("needed %.1f kN", need)
    -- v161: kotaci se vrte na mjestu (test 08.10.: zapeo uz ogradu s tempomatom, 99 % proklizavanja, izbor za kretanje
    -- digao 6F -> 8F). Dok kotaci proklizavaju izbor za kretanje ne dize stupanj/raspon - zadrzi trenutni, nizi smije.
    -- (Vazi za tempomat; AI vozi bez nase logike mjenjaca.)
    local slip = JD.U.wheelSlip ~= nil and JD.U.wheelSlip(motor.vehicle) or 0
    local curG, curS = motor.gear or 0, motor.activeGearGroupIndex or 1
    if slip > (cfg.upSlipMax or 15) and curG ~= 0 and bestGear ~= nil and bestStep ~= nil then
        if bestGear > curG or (bestGear == curG and bestStep > curS) then
            if (motor.jd7810StartSlipLogT or 0) < (g_time or 0) - 3000 then
                motor.jd7810StartSlipLogT = g_time or 0
                JD.U.log(string.format("automatika: kretanje bez vise - proklizavanje %.0f %% (ostaje %s)", slip, tostring(curG) .. "/" .. tostring(curS)))
            end
            bestGear, bestStep = curG, curS
            motor.jd7810StartInfo = (motor.jd7810StartInfo or "") .. string.format(", wheel slip %.0f%% - no higher", slip)
        end
    end
    return bestGear, bestStep
end

VehicleMotor.getBestStartGear = Utils.overwrittenFunction(VehicleMotor.getBestStartGear, function(self, superFunc, gears)
    if isStepBox(self) and JD7810Transmission.cfg.startGearAuto and not isAIActive(self.vehicle) then
        local g, st = JD7810Transmission.bestStart(self)
        if g ~= nil then return g, st end
    end
    return superFunc(self, gears)
end)

-- stoji u automatici bez gasa vise od 0,4 s: prikazuje se N (rucica i LCD)
function JD7810Transmission.isStandingNeutral(motor)
    return (motor.jd7810StandT or 0) > 400
end

local function stepName(motor, gear, step)
    local kind = JD7810Transmission.motorKind(motor)
    if kind == "AQ" then
        local g = motor.currentGears ~= nil and motor.currentGears[gear] or nil
        return string.format("%s%d", (g ~= nil and g.name) or "?", step or 0)
    end
    return (motor.currentDirection or 1) < 0 and ("R" .. math.min(step or 1, 7)) or tostring(step or 0)
end

local function setStep(motor, step)
    if step == nil or step == motor.activeGearGroupIndex then return end
    motor.jd7810InternalGroupChange = true
    motor:setGearGroup(step)
    motor.jd7810InternalGroupChange = false
end

-- kad traktor stane: odaberi brzinu/stupanj za kretanje, kao vozac
local function selectStopGear(self)
    if self.currentGears == nil or (self.gearChangeTimer or 0) > 0 then return end
    local gear, step = JD7810Transmission.bestStart(self)
    if gear == nil then return end
    local old = stepName(self, self.gear, self.activeGearGroupIndex)
    local changed = false
    if self.gear ~= 0 and gear ~= self.gear and self.gearShiftMode == VehicleMotor.SHIFT_MODE_AUTOMATIC then
        self.targetGear = gear
        self:applyTargetGear()
        changed = true
    end
    if step ~= self.activeGearGroupIndex then setStep(self, step); changed = true end
    if changed then
        setEvent(string.format("stop: %s -> %s for take-off (%s)", old, stepName(self, gear, step), self.jd7810StartInfo or ""))
    end
end

-- automatika stupnjeva u voznji (grupe); u automatskom nacinu igre AQ mijenja i raspon na kraju (4 -> sljedeci, 1 -> prethodni)
local function updateSteps(self, dt)
    local cfg = JD7810Transmission.cfg
    if not JD7810Transmission.stepAutoActive(self) or self.gear == nil or self.gear == 0 or self.currentGears == nil then return end
    local governed = (self.jd7810FieldCruise or 0) > 0 or ((self.jd7810HandRpm or 0) > 0 and getSpeedKmh(self) > 1)
    if (math.abs(self.lastAcceleratorPedal or 0) < 0.05 and not governed) or (self.gearChangeTimer or 0) > 0 then return end   -- rucni gas/FC voze i bez papucice
    if self.gearShiftMode == VehicleMotor.SHIFT_MODE_MANUAL_CLUTCH and self.getManualClutchPedal ~= nil then
        local okC, c = pcall(self.getManualClutchPedal, self)
        if okC and type(c) == "number" and c > 0.3 then return end            -- spojka stisnuta: AUTO ne mijenja
    end
    local diffRpm = math.abs(self.differentialRotSpeed or 0) * 30 / math.pi
    local gears, gear, step = self.currentGears, self.gear, self.activeGearGroupIndex or 1
    local reverse = (self.currentDirection or 1) < 0
    local kind = JD7810Transmission.motorKind(self)
    local maxStep = #self.gearGroups
    if kind == "PS" and reverse then maxStep = 7 end
    -- v151: promjena smjera s gasom (S drzan odmah) - stupanj naprijed (npr. 13F) ostajao je i radio kao R7 (omjer
    -- se reze na 7). Kao pravi PS: iz N unatrag najvise R6 (OMAR206904) -> odmah stupanj za kretanje unatrag.
    if kind == "PS" and reverse and step > 6 and getSpeedKmh(self) < 3 then
        local okB, _, bs = pcall(JD7810Transmission.bestStart, self)
        local st = (okB and type(bs) == "number") and math.min(bs, 6) or 6
        setStep(self, st)
        setEvent(string.format("reverse: %d -> R%d for take-off", step, st))
        self.jd7810LastShift = g_time or 0
        return
    end
    local function rpmAt(g, st) local r = stepRatio(self, gears, g, st, reverse); return r ~= nil and diffRpm * r or nil end
    local up, down, loadFactor = getShiftPoints(self)
    local ptoT = JD7810Transmission.ptoTargetRpm ~= nil and JD7810Transmission.ptoTargetRpm(self) or 0
    if cfg.ptoAuto and ptoT > 0 then up, down = ptoT * 1.04, ptoT * 0.90 end      -- PTO: drzi nazivne okretaje
    -- regulirani okretaji: Field Cruise ili RUCNI GAS (bez noznog gasa) - motor stoji na zadanim okretajima
    -- dok ima rezerve, pa okretaji nikad ne prijedu obicnu tocku "vise" (2150) -> AUTO nije mijenjao.
    -- Kao AQ II AUTO s rucnim gasom: visa kad motor drzi zadane okretaje i nakon promjene ostaje rezerve
    -- (predvideni teret <= 85 %), niza kad teret povuce motor 20 % ispod zadanih.
    local fc = self.jd7810FieldCruise or 0
    local hand = self.jd7810HandRpm or 0
    local gov = fc > 0 and fc or ((hand > 0 and not self.jd7810FootThrottle) and hand or 0)
    local governed2 = gov > 0 and not (cfg.ptoAuto and ptoT > 0)
    if governed2 then
        up = gov - 25
        down = gov * 0.80
    end
    -- predvideni teret nakon promjene (ista snaga na kotacima): teret x (okretaji sada / nakon) x (moment sada / nakon)
    local function torqueAt(n)
        local okT, tq = pcall(self.getTorqueCurveValue, self, n)
        return (okT and type(tq) == "number" and tq > 0) and tq or 1
    end
    local rpm = rpmAt(gear, step) or 0
    local now = g_time or 0
    -- v120: iskoristivost pogona kako je igra mjeri (za izbor brzine za kretanje pod teretom)
    local draftNow = self.jd7810DraftKN or 0
    if draftNow > 1 and getSpeedKmh(self) > 2 then
        self.jd7810WorkDraft = (self.jd7810WorkDraft or draftNow) + (draftNow - (self.jd7810WorkDraft or draftNow)) * math.min(1, dt / 3000)
    elseif draftNow <= 1 then
        self.jd7810WorkDraft = nil                                         -- prikljucak podignut / otkacen
    end
    if draftNow > 1 and getSpeedKmh(self) > 2 and loadFactor > 0.5 and math.abs(getAccelerationMS2(self)) < 0.1 then
        local r0 = stepRatio(self, gears, gear, step, reverse)
        local realRpm = JD.U.engineRpm(self)
        local okS, _, massS, slopeS = pcall(startForceNeeded, self)
        if r0 ~= nil and r0 > 0 and realRpm > 900 and okS and massS ~= nil then
            local f = draftNow + (self.jd7810RollKN or 0) + massS * 9.81 * (slopeS or 0)
            local k = f / (loadFactor * torqueAt(realRpm) * r0)
            if k > 0.3 and k < 1.2 then
                self.jd7810DriveEff = (self.jd7810DriveEff or 0.76) + (k - (self.jd7810DriveEff or 0.76)) * math.min(1, dt / 5000)
            end
        end
    end

    -- kretanje: u stupnju za kretanje nema spustanja dok spojka ne izjednaci okretaje
    if self.jd7810LaunchGear ~= nil then
        if gear ~= self.jd7810LaunchGear or step ~= self.jd7810LaunchGroup or rpm >= down or now - (self.jd7810LaunchT or 0) > (cfg.launchTime or 5000) then
            self.jd7810LaunchGear = nil
        else
            return
        end
    end
    if diffRpm < 0.01 then return end
    local since = now - (self.jd7810LastShift or -100000)
    local target = down + (up - down) * 0.6
    local function best(dir)
        local b, bd = nil, math.huge
        for st = 1, maxStep do
            if (dir > 0 and st > step) or (dir < 0 and st < step) then
                local r = rpmAt(gear, st)
                local okLoad = true
                if governed2 and dir > 0 and r ~= nil and r > 0 and rpm > 0 then
                    -- log 04.10. 19:16: C1 1900 -> C2 pa odmah natrag (teret 70-80 %): visa samo ako motor nakon nje drzi zadane okretaje
                    local pl = loadFactor * (rpm / r) * (torqueAt(rpm) / torqueAt(r))
                    okLoad = pl <= (cfg.govUpLoad or 0.85) and r >= down + 100
                end
                if r ~= nil and okLoad and r <= self.maxRpm - 100 and r >= down + 50 then
                    local d = math.abs(r - target)
                    if d < bd then b, bd = st, d end
                end
            end
        end
        return b
    end
    local autoRange = kind == "AQ" and self.gearShiftMode == VehicleMotor.SHIFT_MODE_AUTOMATIC
    -- regulirani okretaji: nakon vise 2,5 s nema nize (osim ako motor jako padne), nakon nize 3 s nema vise
    local lastUp = self.jd7810LastShiftDir == 1
    local upWait = (governed2 and not lastUp) and math.max(cfg.shiftInterval, 3000) or cfg.shiftInterval
    local downOk = not (governed2 and lastUp and since < 2500 and rpm > down - 150)
    -- v152: PUN TERET NA RAVNOM / NIZBRDO (Darijan 07.10.): s 33,7 t motor pod punim gasom stoji na ~2100 o/min
    -- (moment 2200 je 0,30), a tocka "vise" pod teretom je 2150 -> PS nikad nije prebacio dok vuce i ubrzava.
    -- Teret motora dijelom je UBRZAVANJE (masa x a). Stalni teret = teret x otpor / (otpor + masa x a);
    -- visa kad nakon promjene (ista sila, okretaji / omjer) stalni teret ostaje <= loadUpMax (0,85).
    -- Uzbrdo pod punim teretom (stalan teret ~1) ne mijenja, kao i do sada.
    local loadUp = false
    local loadUpRangeStep = nil          -- v153: AQ - stupanj u sljedecem rasponu (promjena raspona pod teretom)
    if not governed2 and not (cfg.ptoAuto and ptoT > 0) and loadFactor > 0.5 and since > upWait
        and rpm > (cfg.loadUpRpm or 2000) and rpm <= up and (step < maxStep or (autoRange and gear < #gears)) then
        local okS, _, massS, slopeS = pcall(startForceNeeded, self)
        if rpm > 0 and okS and type(massS) == "number" then
            local floorR = reverse and math.max(1100, (cfg.downLight or 1250) - 150) or ((cfg.downLight or 1250) + 100)
            local acc = getAccelerationMS2(self)
            local res = math.max(0.3, (self.jd7810RollKN or massS * 9.81 * 0.02) + massS * 9.81 * (slopeS or 0) + (self.jd7810DraftKN or 0))
            local steady = loadFactor * res / (res + massS * math.max(acc, 0))
            -- kandidat: sljedeci stupanj; AQ u 4. stupnju (v153): stupanj sljedeceg raspona s okretajima najblize cilju
            -- (test-logika kao kod PS-a: pun gas pod teretom drzi ~2100, tocka 'vise' po gasu 2150 je nedostizna
            -- -> AQ nije mijenjao raspon, npr. zastoj oko 12-13 km/h)
            local r, rangeStep = nil, nil
            if step < maxStep then
                r = rpmAt(gear, step + 1)
            else
                local bd = math.huge
                for s2 = 1, maxStep do
                    local r2 = rpmAt(gear + 1, s2)
                    if r2 ~= nil and r2 >= floorR and r2 <= self.maxRpm - 100 and math.abs(r2 - target) < bd then
                        r, rangeStep, bd = r2, s2, math.abs(r2 - target)
                    end
                end
            end
            if r ~= nil and r > 0 then
                local pl = steady * (rpm / r) * (torqueAt(rpm) / torqueAt(r))
                if r >= floorR and r <= self.maxRpm - 100 and acc >= (cfg.loadUpAcc or -0.02) and pl <= (cfg.loadUpMax or 0.85) then
                    loadUp = true
                    loadUpRangeStep = rangeStep
                    self.jd7810LoadUpInfo = string.format("res %.1f kN, a %.2f, steady %.0f%%, after %.0f%%", res, acc, steady * 100, pl * 100)
                end
            end
        end
    end
    -- v160: PROKLIZAVANJE (test 08.10., 33,8 t uzbrdo na strmini): kotaci su se vrtjeli ~35-45 % brze od traktora,
    -- okretaji (racunati iz kotaca) ostali su ~2000 pa je automatika isla 5F -> 6F -> 9F -> 10F pod 97-100 % tereta
    -- pri 5 km/h i traktor je zapeo. Kao vozac: dok kotaci proklizavaju nema vise (visa samo jos vise proklizava).
    local slipNow = (JD.U.wheelSlip ~= nil and getSpeedKmh(self) < 25) and JD.U.wheelSlip(self.vehicle) or 0
    self.jd7810AutoSlip = (self.jd7810AutoSlip or slipNow) + (slipNow - (self.jd7810AutoSlip or slipNow)) * math.min(1, dt / 500)
    -- v164: bez uvjeta tereta (test 08.10.: PS udario u ogradu, prednji kotac u zraku, teret na trenutak < 50 %
    -- -> blokada nije vrijedila i automatika je dignula 8F -> 9F pri 0 km/h i 100 % proklizavanja).
    if (rpm > up or loadUp) and since > upWait and self.jd7810AutoSlip > (cfg.upSlipMax or 15) then
        if (self.jd7810SlipBlockLogT or 0) < now - 3000 then
            self.jd7810SlipBlockLogT = now
            setEvent(string.format("upshift blocked: wheel slip %.0f%% (%.0f rpm, load %.0f%%)", self.jd7810AutoSlip, rpm, loadFactor * 100))
            JD.U.log(string.format("automatika: nema vise - proklizavanje %.0f %% (%.0f o/min, teret %.0f %%, %.1f km/h)", self.jd7810AutoSlip, rpm, loadFactor * 100, getSpeedKmh(self)))
        end
        return
    end
    if (rpm > up or loadUp) and since > upWait then
        if not loadUp and loadFactor > 0.5 and getAccelerationMS2(self) < cfg.blockAcc then return end
        local st = nil
        if loadUp then st = (loadUpRangeStep == nil) and (step + 1) or nil else st = best(1) end
        -- v149: SIROKI KORAK (PS 17F -> 18F, omjer 1,40): nakon vise okretaji padnu ispod tocke "nize" pod teretom
        -- (1650), pa best() nije nasao kandidata i PS je ostao u 17F na 27 km/h (test 07.10.). Dopusti sljedeci stupanj
        -- kad nakon promjene ostaje rezerve momenta (predvideni teret <= govUpLoad) i okretaji su iznad tocke vuce.
        if st == nil and step < maxStep and not governed2 then
            local r = rpmAt(gear, step + 1)
            -- v151: unatrag R6 -> R7 je skok 1,93 (8,6 -> 16,6 km/h, OMAR206904): nakon promjene ~1190 o/min -> donja granica
            -- unatrag 1100 (moment 1200 o/min je blizu vrha); naprijed ostaje downLight + 100
            local floorR = reverse and math.max(1100, (cfg.downLight or 1250) - 150) or ((cfg.downLight or 1250) + 100)
            if r ~= nil and r > 0 and rpm > 0 and r >= floorR and r <= self.maxRpm - 100 then
                local pl = loadFactor * (rpm / r) * (torqueAt(rpm) / torqueAt(r))
                if pl <= (cfg.govUpLoad or 0.85) then
                    st = step + 1
                    self.jd7810WideUpStep, self.jd7810WideUpRpm = st, r
                end
            end
        end
        if st ~= nil then
            -- v152: nakon SVAKE vise drzi stupanj dok okretaji ne padnu 150 ispod ocekivanih (test 07.10.: 17F -> 18F pa odmah
            -- 18F -> 17F na 1474 o/min - nakon promjene teret naraste pa tocka 'nize' skoci na ~1600 = lov)
            self.jd7810WideUpStep, self.jd7810WideUpRpm = st, rpmAt(gear, st)
            setStep(self, st)
            setEvent(string.format("up%s: %s -> %s (%.0f rpm)%s", loadUp and " (load)" or "", stepName(self, gear, step), stepName(self, gear, st), rpm, loadUp and (" " .. (self.jd7810LoadUpInfo or "")) or ""))
            self.jd7810LastShiftDir = 1
            self.jd7810LastShift = now
        elseif step >= maxStep and autoRange and gear < #gears then
            -- sljedeci raspon: stupanj s okretajima najblize cilju
            local bs, bd = 1, math.huge
            for s2 = 1, maxStep do
                local r = rpmAt(gear + 1, s2)
                if r ~= nil and r >= down + 50 and math.abs(r - target) < bd then bs, bd = s2, math.abs(r - target) end
            end
            if loadUpRangeStep ~= nil then bs = loadUpRangeStep end
            self.jd7810WideUpStep, self.jd7810WideUpRpm = bs, rpmAt(gear + 1, bs)   -- v153: bez lova natrag
            self.targetGear = gear + 1; self:applyTargetGear(); setStep(self, bs)
            setEvent(string.format("higher range: %s -> %s", stepName(self, gear, step), stepName(self, gear + 1, bs)))
            self.jd7810LastShiftDir = 1
            self.jd7810LastShift = now
        end
    end
    -- v119: ispod minSpeed (3 km/h) automatika nije spustala ni kad je motor pod teretom pao na prazni hod
    -- (test 05.10.: ~20 s u C na 851 o/min i 1,7 km/h, spojka klizi). Sada spusta i tada - kao pravi AQ AUTO
    -- osjeca pad okretaja motora; stajanje i kretanje i dalje bira "stop" / zastita kretanja (launch).
    local lugging = getSpeedKmh(self) > 0.3 and JD.U.engineRpm(self) < down
    -- v121: dok traktor jos ubrzava (nakon kretanja) a motor je iznad tocke vuce (downLight 1250), ne spustaj:
    -- test 05.10.: B3 krenuo, na 1600 o/min pri 3-5 km/h (jos ubrzava) spustio u B2 - nepotrebno.
    if getAccelerationMS2(self) > (cfg.downAccHold or 0.15) and rpm > (cfg.downLight or 1250) then downOk = false end
    -- v149: nakon sirokog koraka nema odmah natrag (lov 17F <-> 18F): drzi dok okretaji ne padnu 150 ispod
    -- ocekivanih nakon promjene (ili ispod tocke vuce downLight)
    if self.jd7810WideUpStep ~= nil then
        if step ~= self.jd7810WideUpStep then
            self.jd7810WideUpStep = nil
        elseif rpm > math.max(950, (self.jd7810WideUpRpm or 0) - 150) then   -- v151: prag iz ocekivanih okretaja (R7 krece na ~1190)
            downOk = false
        end
    end
    if not (rpm > up and since > upWait) and rpm < down and downOk and since > cfg.shiftInterval * 0.5 and (getSpeedKmh(self) > (cfg.minSpeed or 3) or lugging) then   -- stajanje/kretanje: stupanj bira "stop"
        local st = best(-1)
        if st == nil and step > 1 then st = step - 1 end
        if st ~= nil then
            setStep(self, st)
            setEvent(string.format("down: %s -> %s (%.0f rpm)", stepName(self, gear, step), stepName(self, gear, st), rpm))
        elseif step <= 1 and autoRange and gear > 1 then
            local bs, br = maxStep, -1
            for s2 = maxStep, 1, -1 do
                local r = rpmAt(gear - 1, s2)
                if r ~= nil and r <= up and r > br then bs, br = s2, r end
            end
            self.targetGear = gear - 1; self:applyTargetGear(); setStep(self, bs)
            setEvent(string.format("lower range: %s -> %s", stepName(self, gear, step), stepName(self, gear - 1, bs)))
        end
        self.jd7810LastShift = now
        self.jd7810LastShiftDir = -1
    end
end
VehicleMotor.update = Utils.appendedFunction(VehicleMotor.update, function(self, dt)
    if isStepBox(self) then
        local ok, err = pcall(updateSteps, self, dt)
        if not ok and not self.jd7810StepErr then self.jd7810StepErr = true; log("stupnjevi: greska " .. tostring(err)) end
    end
end)

VehicleMotor.updateGear = Utils.overwrittenFunction(VehicleMotor.updateGear, function(self, superFunc, acceleratorPedal, brakePedal, dt)
    local acc, brake = superFunc(self, acceleratorPedal, brakePedal, dt)

    if not isOurs(self) or acc == nil then
        return acc, brake
    end
    local cfg = JD7810Transmission.cfg
    if self.jd7810Creep then
        -- puzanje: regulator drzi prazni hod, ali TI nisi dao gas -> papucica/zvuk/automatika vide gas 0
        self.lastAcceleratorPedal = 0
    end

    -- stoji i nema gasa: pripremi brzinu za kretanje (provjera svake sekunde, npr. dok se puni prikolica)
    if cfg.startGearAuto and JD7810Transmission.stepAutoActive(self)
    and math.abs(self.vehicle.lastSpeed or 0) < 0.0003 and math.abs(acceleratorPedal or 0) < 0.01 then
        -- odmah po zaustavljanju (i odmah nakon promjene smjera), zatim svake sekunde (teret se moze mijenjati)
        local dir = self.currentDirection or 1
        local fresh = not self.jd7810Stopped or dir ~= self.jd7810StopDir
        if fresh or (g_time or 0) - (self.jd7810StopCheck or -100000) > 1000 then
            self.jd7810StopCheck = g_time or 0
            self.jd7810Stopped, self.jd7810StopDir = true, dir
            selectStopGear(self)
        end
    elseif math.abs(self.vehicle.lastSpeed or 0) > 0.0006 then
        self.jd7810Stopped = false
    end
    -- pocetak kretanja: zapamti brzinu u kojoj krece (stajao + doda gas)
    if self.jd7810Stopped and math.abs(acceleratorPedal or 0) > 0.01 and self.jd7810LaunchGear == nil then
        self.jd7810LaunchGear = (self.targetGear ~= nil and self.targetGear ~= 0) and self.targetGear or self.gear
        self.jd7810LaunchGroup = self.activeGearGroupIndex                -- AQ/PS: stupanj (grupa)
        self.jd7810LaunchT = g_time or 0
        self.jd7810Stopped = false
    end
    -- stoji bez gasa u automatici: vozac drzi ruciku u N (prikaz/rucica), mjenjac ceka pripremljenu brzinu za kretanje
    if math.abs(self.vehicle.lastSpeed or 0) < 0.0003 and math.abs(acceleratorPedal or 0) < 0.01 and JD7810Transmission.stepAutoActive(self) then
        self.jd7810StandT = (self.jd7810StandT or 0) + (dt or 0)
    else
        self.jd7810StandT = 0
    end
    local cap = 1

    -- turbo: tlak raste postupno, pada brze kad se pusti gas
    if cfg.turbo then
        local rpm = JD.U.engineRpm(self)
        local target = 0
        if math.abs(acc) > 0.1 then
            target = clamp((rpm - 850) / 350, 0, 1)
        end
        local boost = self.jd7810Boost or 0
        local rate = dt / math.max(cfg.turboTime, 1)
        if target > boost then
            boost = math.min(target, boost + rate)
        else
            boost = math.max(target, boost - rate * 2)
        end
        self.jd7810Boost = boost
        cap = cfg.turboMin + (1 - cfg.turboMin) * boost
    else
        self.jd7810Boost = 1
    end

    -- pad snage pri powershiftu
    local dipTimer = self.jd7810DipTimer or 0
    if dipTimer > 0 then
        dipTimer = math.max(dipTimer - dt, 0)
        self.jd7810DipTimer = dipTimer
        cap = cap * (1 - cfg.shiftDip * (dipTimer / math.max(self.jd7810DipTime or 1, 1)))
    end

    self.jd7810PedalIn = acc
    if math.abs(acc) > cap then
        acc = cap * math.sign(acc)
    end
    self.jd7810PedalOut = acc
    return acc, brake
end)

-- =====================================================================
--  D) AutoQuad II / Powershift prema nacinu voznje iz igre:
--     AUTOMATSKI      -> stupnjevi (grupe) automatski, AQ i rasponi A-E
--     RUCNO           -> AQ: raspon biras ti, 1-4 prema prekidacu MANUAL/AUTO/ECO; PS: stupnjeve biras ti
--     RUCNO+SPOJKA    -> kao RUCNO (AQ 1-4 prema prekidacu, ne dok je spojka stisnuta); igra gasi motor ako stanes bez spojke
-- =====================================================================
-- AQ/PS: stupnjeve (grupe) mijenja vlastita automatika (S), ne igra; AI vozi s automatikom igre
VehicleMotor.getUseAutomaticGroupShifting = Utils.overwrittenFunction(VehicleMotor.getUseAutomaticGroupShifting, function(self, superFunc)
    if isStepBox(self) and not isAIActive(self.vehicle) then return false end
    return superFunc(self)
end)

-- =====================================================================
--  E) Vlastita logika automatika (dok je gas pritisnut)
-- =====================================================================
local function rpmInGear(motor, gears, gear, groupIndex, diffRpm)
    local groupRatio = 1
    if motor.gearGroups ~= nil and groupIndex ~= nil and motor.gearGroups[groupIndex] ~= nil then
        groupRatio = motor.gearGroups[groupIndex].ratio
    end
    return diffRpm * math.abs(gears[gear].ratio * groupRatio)
end

-- najbolja brzina 1-4 u zadanom opsegu za trenutnu brzinu voznje
--   mode "up":   okretaji najblize sredini podrucja (ubrzavanje)
--   mode "down": najvisi okretaji koji jos ne prelaze gornju tocku (vuca, kocenje motorom)
local function pickGearInGroup(motor, gears, groupIndex, diffRpm, up, down, mode)
    local mid = (up + down) / 2
    local best, bestScore = nil, math.huge
    local fallback, fallbackRpm = nil, -1
    for g = 1, #gears do
        local rpm = rpmInGear(motor, gears, g, groupIndex, diffRpm)
        if mode == "down" then
            if rpm <= up and rpm >= down + 100 then
                local score = -rpm   -- visi okretaji = bolje
                if score < bestScore then best, bestScore = g, score end
            end
        else
            if rpm >= down + 100 and rpm <= up - 50 then
                local score = math.abs(rpm - mid)
                if score < bestScore then best, bestScore = g, score end
            end
        end
        -- rezerva: najvisi okretaji koji ne prelaze maksimum motora
        if rpm <= motor.maxRpm - 150 and rpm > fallbackRpm then
            fallback, fallbackRpm = g, rpm
        end
    end
    return best or fallback
end

local function changeRange(motor, newGroup)
    motor.jd7810InternalGroupChange = true
    motor:setGearGroup(newGroup)
    motor.jd7810InternalGroupChange = false
    -- prekid snage kontroliramo sami (kao spojka pri promjeni opsega)
    motor.groupChangeTimer = 0
    motor.gearChangeTime = JD7810Transmission.cfg.rangeShiftTime   -- GIANTS ga vraca na original nakon ukljucenja
end

-- najbolja brzina u trenutnom opsegu: okretaji najblize ciljanim (izmedu down i up),
-- dozvoljeno preskakanje brzina (npr. 4 -> 2 uzbrdo)
local function pickBestGear(motor, gears, groupIndex, diffRpm, up, down, fromGear, direction)
    local target = down + (up - down) * 0.6
    local best, bestDiff = nil, math.huge
    for g = 1, #gears do
        if direction == 0 or (direction > 0 and g > fromGear) or (direction < 0 and g < fromGear) then
            local rpm = rpmInGear(motor, gears, g, groupIndex, diffRpm)
            if rpm <= motor.maxRpm - 100 and rpm >= down + 50 then
                local d = math.abs(rpm - target)
                if d < bestDiff then
                    best, bestDiff = g, d
                end
            end
        end
    end
    return best
end

local function jd7810Predict(self, curGear, gears)
    local cfg = JD7810Transmission.cfg
    if gears == nil or gears[curGear] == nil then
        return nil
    end
    local group = self.activeGearGroupIndex
    local diffRpm = math.abs(self.differentialRotSpeed or 0) * 30 / math.pi

    -- KRETANJE: u brzini izabranoj prema tezini se ne spusta nize dok spojka ne izjednaci okretaje
    -- (okretaji kotaca ispod "nize" su normalni pri kretanju - prije je zbog toga C3 -> B1)
    if self.jd7810LaunchGear ~= nil then
        local upL, downL = getShiftPoints(self)
        local rpmL = diffRpm > 0.01 and rpmInGear(self, gears, curGear, group, diffRpm) or 0
        if curGear ~= self.jd7810LaunchGear or group ~= self.jd7810LaunchGroup or rpmL >= downL
           or (g_time or 0) - (self.jd7810LaunchT or 0) > (cfg.launchTime or 5000) then
            self.jd7810LaunchGear = nil                                   -- kretanje gotovo (ili vozac/igra promijenio brzinu)
        else
            return curGear
        end
    end
    if diffRpm < 0.01 then
        return nil
    end

    local rpm = rpmInGear(self, gears, curGear, group, diffRpm)
    local up, down, loadFactor = getShiftPoints(self)
    local canShiftGroups = self.gearGroups ~= nil and self:getUseAutomaticGroupShifting()
    local numGroups = self.gearGroups ~= nil and #self.gearGroups or 0
    local sinceShift = (g_time or 0) - (self.jd7810LastShift or -100000)
    local forceEval = self.jd7810ForceEval
    self.jd7810ForceEval = false
    local groupName = function(i) return self.gearGroups ~= nil and self.gearGroups[i] ~= nil and (self.gearGroups[i].name or "?") or "" end

    -- VISA
    if rpm > up then
        if not forceEval and sinceShift < cfg.shiftInterval then
            return curGear
        end
        if loadFactor > 0.5 and getAccelerationMS2(self) < cfg.blockAcc then
            setEvent(string.format("upshift blocked: slowing under load (%.0f rpm)", rpm))
            return curGear
        end
        local g = pickBestGear(self, gears, group, diffRpm, up, down, curGear, 1)
        if g ~= nil then
            setEvent(string.format("up: %s%d -> %s%d  (%.0f -> %.0f rpm)", groupName(group), curGear, groupName(group), g, rpm, rpmInGear(self, gears, g, group, diffRpm)))
            return g
        end
        if curGear == #gears then
            if canShiftGroups and group < numGroups then
                local ng = pickGearInGroup(self, gears, group + 1, diffRpm, up, down, "up")
                if ng ~= nil then
                    setEvent(string.format("higher range: %s%d -> %s%d", groupName(group), curGear, groupName(group + 1), ng))
                    changeRange(self, group + 1)
                    return ng
                end
            elseif not canShiftGroups and group < numGroups and (g_time or 0) - JD7810Transmission.lastEventTime > 3000 then
                setEvent(string.format("%s%d is the end of the range (%.0f rpm) - shift range up to %s", groupName(group), curGear, rpm, groupName(group + 1)))
            end
        end
        return curGear
    end

    -- NIZA
    if rpm < down then
        if not forceEval and sinceShift < cfg.shiftInterval * 0.5 then
            return curGear
        end
        local g = pickBestGear(self, gears, group, diffRpm, up, down, curGear, -1)
        if g == nil and curGear > 1 then
            -- nijedna nije u podrucju: uzmi najvisu koja ne prelazi maksimum
            for i = curGear - 1, 1, -1 do
                if rpmInGear(self, gears, i, group, diffRpm) <= self.maxRpm - 100 then
                    g = i
                    break
                end
            end
        end
        if g ~= nil then
            self.allowGearChangeTimer = 0   -- ukida GIANTS-ovu zabranu nize brzine 3 s nakon vise
            setEvent(string.format("down: %s%d -> %s%d  (%.0f -> %.0f rpm)", groupName(group), curGear, groupName(group), g, rpm, rpmInGear(self, gears, g, group, diffRpm)))
            return g
        end
        if curGear == 1 then
            if canShiftGroups and group > 1 then
                local ng = pickGearInGroup(self, gears, group - 1, diffRpm, up, down, "down")
                if ng ~= nil then
                    setEvent(string.format("lower range: %s%d -> %s%d", groupName(group), curGear, groupName(group - 1), ng))
                    self.allowGearChangeTimer = 0
                    changeRange(self, group - 1)
                    return ng
                end
            elseif not canShiftGroups and group > 1 then
                setEvent(string.format("rpm too low in %s1 - shift range down to %s!", groupName(group), groupName(group - 1)))
            end
        end
        return curGear
    end

    -- u podrucju, ali nakon rucne promjene opsega provjeri je li ovo najbolja brzina
    if forceEval then
        local g = pickBestGear(self, gears, group, diffRpm, up, down, curGear, 0)
        if g ~= nil and g ~= curGear then
            setEvent(string.format("range %s: gear %d -> %d", groupName(group), curGear, g))
            return g
        end
    end

    return curGear
end

-- =====================================================================
--  D0) Rucna promjena opsega u automatiku: odmah ukljuci brzinu koja
--      odgovara trenutnoj brzini voznje (GIANTS zadrzi isti broj brzine)
-- =====================================================================
VehicleMotor.setGearGroup = Utils.overwrittenFunction(VehicleMotor.setGearGroup, function(self, superFunc, groupIndex, isLocked)
    local oldGroup = self.activeGearGroupIndex
    local diffRot = math.abs(self.differentialRotSpeed or 0)
    local curRatio = diffRot > 0.5 and (self.motorRotSpeed or 0) / diffRot or nil
    superFunc(self, groupIndex, isLocked)
    -- powershift NA NIZE (svi nacini, i rucno sa spojkom): spojke stupnja se pune postupno -> okretaji rastu
    -- i kocenje motorom raste glatko umjesto skoka omjera (nagli pad brzine i okretaja)
    if isStepBox(self) and oldGroup ~= self.activeGearGroupIndex and curRatio ~= nil and JD7810Transmission.cfg.slip
       and getSpeedKmh(self) > JD7810Transmission.cfg.minSpeed then
        local rev = (self.currentDirection or 1) < 0
        local newRatio = stepRatio(self, self.currentGears, self.gear, self.activeGearGroupIndex, rev)
        local cfg = JD7810Transmission.cfg
        local t = 0
        if newRatio ~= nil and newRatio > curRatio * 1.03 then
            t = math.abs(self.lastAcceleratorPedal or 0) > 0.3 and cfg.slipTimeLoad or cfg.slipTime
        elseif newRatio ~= nil and newRatio < curRatio * 0.97 then
            t = cfg.slipTimeUp or 300   -- NA VISE: okretaji se spustaju glatko, bez trzaja (zamasnjak ne udari u kotace)
        end
        if t > 0 then
            self.jd7810SlipFrom = curRatio * (rev and -1 or 1)
            self.jd7810SlipTime = t
            self.jd7810SlipTimer = t
        end
    end
    if isStepBox(self) and oldGroup ~= self.activeGearGroupIndex then
        local cfg = JD7810Transmission.cfg
        self.jd7810LastShift = g_time or 0
        if not self.jd7810InternalGroupChange then self.jd7810LaunchGear = nil end        -- vozac sam mijenja
        -- kratki pad snage (spojke powershifta se prekrivaju)
        if math.abs(self.lastAcceleratorPedal or 0) > 0.1 and getSpeedKmh(self) > cfg.minSpeed and cfg.shiftDip > 0 and cfg.shiftDipTime > 0 then
            self.jd7810DipTime = cfg.shiftDipTime
            self.jd7810DipTimer = cfg.shiftDipTime
        end
    end
end)

VehicleMotor.findGearChangeTargetGearPrediction = Utils.overwrittenFunction(VehicleMotor.findGearChangeTargetGearPrediction,
    function(self, superFunc, curGear, gears, gearSign, gearChangeTimer, acceleratorPedal, dt)
        if isStepBox(self) and not isAIActive(self.vehicle) then
            return curGear                                            -- AQ/PS: raspon mijenja S) samo kad treba
        end
        if isOurs(self) and JD7810Transmission.cfg.ptoAuto and (self.jd7810PtoActive or 0) > 0 and not isAIActive(self.vehicle) then
            local g = JD7810Transmission.ptoPredict(self, curGear, gears, acceleratorPedal)
            if g ~= nil then
                return g
            end
        end
        if isOurs(self) and (self.jd7810HandRpm or 0) > 0 and self.jd7810HandDrive and not self.jd7810FootThrottle then
            return curGear   -- rucni gas: brzina ostaje kakvu si izabrao
        end
        if JD7810Transmission.cfg.autoShift and isOurs(self) and math.abs(acceleratorPedal or 0) > 0.05 then
            local newGear = jd7810Predict(self, curGear, gears)
            if newGear ~= nil then
                return newGear
            end
        end
        return superFunc(self, curGear, gears, gearSign, gearChangeTimer, acceleratorPedal, dt)
    end)

-- =====================================================================
--  J) RADNA VOZNJA (LCtrl+1, prije Num 7 / LCtrl+Num 7): tempomat na radnu brzinu alata
-- =====================================================================
local function getWorkSpeed(vehicle)
    local best, name = nil, nil
    local ok, children = pcall(vehicle.getChildVehicles, vehicle)
    if ok and type(children) == "table" then
        for _, tool in ipairs(children) do
            if tool ~= vehicle and type(tool.speedLimit) == "number" and tool.speedLimit > 0 and tool.speedLimit < 60 then
                local working = false
                local st = JD7810Transmission.tools[tool]
                if st ~= nil and st.active then
                    working = true
                end
                if not working and tool.getIsLowered ~= nil then
                    local okL, lowered = pcall(tool.getIsLowered, tool, false)
                    working = okL and lowered == true
                end
                if not working and tool.getIsTurnedOn ~= nil then
                    local okT, on = pcall(tool.getIsTurnedOn, tool)
                    working = okT and on == true
                end
                if working and (best == nil or tool.speedLimit < best) then
                    best = tool.speedLimit
                    name = tool.getName ~= nil and tool:getName() or "alat"
                end
            end
        end
    end
    return best, name
end

-- AQ: najveca brzina raspona (stupanj 4) pri zadanim okretajima, km/h
local function rangeTopSpeed(motor, gearIndex, rpm)
    local gears = motor.forwardGears or motor.currentGears
    if gears == nil or gears[gearIndex] == nil or motor.gearGroups == nil then return nil end
    local r = stepRatio(motor, gears, gearIndex, #motor.gearGroups, false)
    if r == nil or r == 0 then return nil end
    return (rpm * math.pi / 30) / r * 3.6
end

local function checkRangeForSpeed(motor, speed, rpm)
    if JD7810Transmission.motorKind(motor) ~= "AQ" then return end
    local gears = motor.forwardGears or motor.currentGears
    local wanted = nil
    for i = 1, #gears do
        local top = rangeTopSpeed(motor, i, rpm)
        if top ~= nil and top >= speed * 1.05 then wanted = i; break end
    end
    if wanted == nil or wanted == motor.gear then return end
    local name = gears[wanted].name or tostring(wanted)
    if getSpeedKmh(motor) < 1 and JD7810Transmission.cfg.startRange and motor.gearShiftMode == VehicleMotor.SHIFT_MODE_AUTOMATIC then
        motor.targetGear = wanted
        motor:applyTargetGear()
        setEvent(string.format("Work drive: range %s for %.0f km/h", name, speed))
    else
        local top = rangeTopSpeed(motor, motor.gear or 1, rpm) or 0
        if top < speed * 0.95 or wanted < (motor.gear or 1) then
            setEvent(string.format("For %.0f km/h shift range to %s", speed, name))
        end
    end
end

function JD7810Transmission.toggleWorkDrive(vehicle)
    local motor = vehicle.getMotor ~= nil and vehicle:getMotor() or nil
    if motor == nil or not isOurs(motor) or vehicle.getCruiseControlState == nil or Drivable == nil then
        return
    end
    local state = vehicle:getCruiseControlState()
    if motor.jd7810WorkDrive and state ~= Drivable.CRUISECONTROL_STATE_OFF then
        vehicle:setCruiseControlState(Drivable.CRUISECONTROL_STATE_OFF)
        motor.jd7810WorkDrive = false
        setEvent("Work drive off")
        return
    end

    local speed, name = getWorkSpeed(vehicle)
    if speed == nil then
        setEvent("Work drive: no lowered or running implement")
        return
    end

    -- ako PTO radi, a rucni gas nije postavljen: nazivni PTO okretaji (kao vozac)
    if (motor.jd7810HandRpm or 0) <= 0 and (motor.jd7810PtoActive or 0) > 0 then
        local rated = 0
        for _, st in pairs(JD7810Transmission.tools) do
            if st.active then
                rated = math.max(rated, st.ratedEngine or 0)
            end
        end
        if rated > 0 then
            JD7810Transmission.setHandThrottle(motor, rated)
        end
    end

    local rpm = (motor.jd7810HandRpm or 0) > 0 and motor.jd7810HandRpm or JD7810Transmission.cfg.pto1000Rpm
    checkRangeForSpeed(motor, speed, rpm)

    vehicle:setCruiseControlMaxSpeed(speed, nil)
    vehicle:setCruiseControlState(Drivable.CRUISECONTROL_STATE_ACTIVE)
    motor.jd7810WorkDrive = true
    motor.jd7810WorkSpeed = speed
    if not string.find(JD7810Transmission.lastEvent or "", "opseg", 1, true) or (g_time or 0) - JD7810Transmission.lastEventTime > 100 then
        setEvent(string.format("Work drive: %.0f km/h (%s)", speed, name))
    end
end

function JD7810Transmission.actionWorkDrive(vehicle, actionName, inputValue, callbackState, isAnalog)
    if JD7810Transmission.switchClick ~= nil then JD7810Transmission.switchClick(vehicle) end   -- v171
    JD7810Transmission.toggleWorkDrive(vehicle)
end

-- =====================================================================
--  L) IVT REGULACIJA OKRETAJA (birac OFF/1/2/3 + Field Cruise)
--     Prema OMAR206904 (7710/7810 IVT) "IVT Selector Examples":
--     1/2/3 pod teretom: IVT mijenja omjer da drzi 1950 o/min (regulacija tereta)
--     bez tereta: najmanje 2000 (1) / 1500 (2) / 1200 (3) o/min;
--       2 i 3 = stednja goriva: ista brzina na nizim okretajima
--     OFF: IVT ne mijenja omjer pod teretom - motor i brzina padaju zajedno
--     Gornja granica = gas (rucni ili papucica), nikad iznad Field Cruisea.
--     Omjer bira fizika igre unutar prozora okretaja (controlVehicle);
--     ovdje se zadaje samo prozor okretaja (getRequiredMotorRpmRange).
-- =====================================================================
JD7810Transmission.IVT_MODE_NAMES = { [0] = "OFF", [1] = "1", [2] = "2", [3] = "3" }

local function ivtState(motor)
    if motor.jd7810IvtMode == nil then
        motor.jd7810IvtMode = math.floor(clamp(JD7810Transmission.cfg.ivtMode or 2, 0, 3) + 0.5)
        motor.jd7810FieldCruise = 0
        motor.jd7810IvtUnder = false
    end
end

-- snaga motora (kW) pri okretajima n prema krivulji momenta (kNm)
local function powerAt(motor, n)
    local ok, t = pcall(motor.getTorqueCurveValue, motor, n)
    if not ok or type(t) ~= "number" then return 0 end
    return t * n * math.pi / 30
end

-- najnizi okretaji (>= nMin) koji daju potrebnu snagu s rezervom i brzinu (stednja goriva, polozaj 2/3)
local function ivtEcoRpm(motor, nMin, nMax, load)
    local cfg = JD7810Transmission.cfg
    local cur = motor.getLastMotorRpm ~= nil and motor:getLastMotorRpm() or nMax
    local need = load * powerAt(motor, math.max(cur, motor.minRpm or 850)) * (cfg.ivtEcoReserve or 1.5)
    -- okretaji potrebni za ciljanu brzinu (gas x ogranicenje) pri najmanjem omjeru
    local pedal = math.abs(motor.lastAcceleratorPedal or 0)
    local vTarget = math.min(JD7810Transmission.U.getSpeedLimitKmh(motor), JD7810Transmission.ivtMaxF(motor)) * pedal
    local ratio = math.max(motor.minForwardGearRatio or 21.7, 1)
    local nSpeed = vTarget / 3.6 * ratio * 30 / math.pi * 1.05
    local n = math.max(nMin, nSpeed)
    while n < nMax and powerAt(motor, n) < need do n = n + 50 end
    return clamp(n, nMin, nMax)
end

function JD7810Transmission.ivtRange(motor, minRpm, maxRpm)
    if not JD7810Transmission.isIVT(motor) or isAIActive(motor.vehicle) then
        return minRpm, maxRpm
    end
    ivtState(motor)
    local cfg = JD7810Transmission.cfg
    local now = g_time or 0
    local dtS = clamp((now - (motor.jd7810IvtT or now)) / 1000, 0, 0.2)
    if JD7810Transmission.ivtUpdateRange ~= nil then JD7810Transmission.ivtUpdateRange(motor) end   -- v172: LOW/HIGH + AUTO traka
    motor.jd7810IvtT = now

    -- Field Cruise: najvise okretaje
    local fc = motor.jd7810FieldCruise or 0
    if fc > 0 then
        maxRpm = math.min(maxRpm, fc)
    end
    motor.jd7810IvtGovRpm = maxRpm                    -- okretaji gasa (za OFF omjer)

    -- opterecenje s histerezom
    local load = 0
    local okL, l = pcall(motor.getSmoothLoadPercentage, motor)
    if okL and type(l) == "number" then load = l end
    if motor.jd7810IvtUnder then
        motor.jd7810IvtUnder = load > cfg.ivtLoadOff
    else
        motor.jd7810IvtUnder = load > cfg.ivtLoadOn
    end

    local mode = motor.jd7810IvtMode
    local target, top = minRpm, maxRpm
    local moving = getSpeedKmh(motor) > 0.5
    -- gas pusten (papucica i rucni gas): IVT ne drzi minimum polozaja, motor pada na prazni hod
    local throttleOn = math.abs(motor.lastAcceleratorPedal or 0) > 0.05 or (motor.jd7810HandRpm or 0) > 0
    if not throttleOn then motor.jd7810IvtUnder = false end
    if mode > 0 and moving and throttleOn then
        local light = ({ cfg.ivtMin1, cfg.ivtMin2, cfg.ivtMin3 })[mode]
        if motor.jd7810IvtUnder then
            target = cfg.ivtLoadRpm                       -- regulacija tereta: drzi 1950, uspori voznju
        else
            target = light
            if mode >= 2 then                             -- stednja goriva: niza gornja granica
                top = ivtEcoRpm(motor, light, maxRpm, load)
            end
        end
        target = math.max(target, minRpm)
    elseif mode == 0 and moving and throttleOn then
        -- OFF: IVT ne mijenja omjer da spasi okretaje - pod teretom motor "guta" do ivtOffLugRpm
        -- (prozor lug..lug+200, manje snage nego 1950 u polozajima 1-3); bez tereta slobodno
        if motor.jd7810IvtUnder then
            local lug = cfg.ivtOffLugRpm or 1300
            target, top = lug, lug + 200
        end
    end
    target = math.min(target, maxRpm)                     -- nikad iznad gasa / Field Cruisea

    -- glatki prijelaz granica
    local step = cfg.ivtRate * dtS
    local cur = motor.jd7810IvtMin or target
    if target > cur then cur = math.min(target, cur + step) else cur = math.max(target, cur - step * (throttleOn and 1 or 4)) end
    motor.jd7810IvtMin = cur
    local curTop = motor.jd7810IvtTop or top
    if top > curTop then curTop = math.min(top, curTop + step * 2) else curTop = math.max(top, curTop - step) end
    motor.jd7810IvtTop = curTop
    motor.jd7810IvtLoad = load

    if cfg.debug and now - (motor.jd7810IvtLog or 0) > 1000 then
        motor.jd7810IvtLog = now
        log(string.format("IVT %s: opterecenje %.0f%% %s, prozor %.0f-%.0f o/min, FC %s, stupanj %s, hidro %.0f%%, ucinak %.0f%%",
            JD7810Transmission.IVT_MODE_NAMES[mode], load * 100, motor.jd7810IvtUnder and "(regulacija tereta)" or "",
            cur, curTop, fc > 0 and string.format("%.0f", fc) or "iskl.", tostring(motor.jd7810IvtRange),
            (motor.jd7810IvtHydro or 0) * 100, (motor.jd7810IvtEff or 1) * 100))
    end
    local lo = math.max(cur, motor.minRpm or 0)
    local hi = math.max(math.min(maxRpm, curTop), lo + 50)
    motor.jd7810IvtLo, motor.jd7810IvtHi = lo, hi
    return lo, hi
end


function JD7810Transmission.actionIvtMode(vehicle, actionName, inputValue, callbackState, isAnalog)
    local motor = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil
    if motor == nil or not JD7810Transmission.isIVT(motor) then return end
    if JD7810Transmission.switchClick ~= nil then JD7810Transmission.switchClick(vehicle) end   -- v171
    ivtState(motor)
    motor.jd7810IvtMode = (motor.jd7810IvtMode + 1) % 4
    local txt = ({ [0] = "OFF - bez regulacije tereta", [1] = "1 - PTO/utovarivac (pod teretom 1950, min 2000)",
                   [2] = "2 - obrada (pod teretom 1950, min 1500, stednja goriva)", [3] = "3 - transport/laka obrada (pod teretom 1950, min 1200, stednja goriva)" })[motor.jd7810IvtMode]
    setEvent("IVT selector: " .. txt)
end

-- Field Cruise: IVT = najvise okretaje; AutoQuad II / Powershift = stalni okretaji 1500-2200 (OMAR206904 "Using Field Cruise")
function JD7810Transmission.actionFieldCruise(vehicle, actionName, inputValue, callbackState, isAnalog)
    local motor = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil
    if motor == nil or not isOurs(motor) then return end
    if not JD7810Transmission.cfg.fieldCruise then motor.jd7810FieldCruise = 0; return end   -- v131: iskljuceno
    local ivt = JD7810Transmission.isIVT(motor)
    if ivt then ivtState(motor) end
    if (motor.jd7810FieldCruise or 0) > 0 then
        motor.jd7810FieldCruise = 0
        setEvent("Field Cruise off")
    else
        local rpm = JD.U.engineRpm(motor)
        if ivt then
            rpm = clamp(math.floor(rpm / 50 + 0.5) * 50, 1000, motor.maxRpm or 2300)
        else
            rpm = clamp(math.floor(rpm / 50 + 0.5) * 50, 1500, 2200)
        end
        motor.jd7810FieldCruise = rpm
        setEvent(string.format(ivt and "Field Cruise: max %.0f rpm" or "Field Cruise: constant %.0f rpm", rpm))
    end
end

-- AutoQuad II: prekidac AUTO/ECO (klackalica aqAutoEcoRot) - MANUAL -> AUTO -> ECO -> MANUAL
JD7810Transmission.AQ_MODE_NAMES = { [0] = "MANUAL (1-4 by you)", [1] = "AUTO (1-4 automatic)", [2] = "ECO (earlier upshift)" }
function JD7810Transmission.actionAqMode(vehicle, actionName, inputValue, callbackState, isAnalog)
    local motor = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil
    if motor == nil or not isOurs(motor) or JD7810Transmission.isAutoQuad == nil or not JD7810Transmission.isAutoQuad(motor) then return end
    if JD7810Transmission.isPowrQuad ~= nil and JD7810Transmission.isPowrQuad(motor) then   -- v173: PowrQuad nema AUTO/ECO
        motor.jd7810AqMode = 0
        setEvent("PowrQuad: gears 1-4 manual only")
        return
    end
    if JD7810Transmission.switchClick ~= nil then JD7810Transmission.switchClick(vehicle) end   -- v171
    local m = ((motor.jd7810AqMode or 1) + 1) % 3
    motor.jd7810AqMode = m
    motor.jd7810AqPress = (m == 2) and -1 or 1                -- klackalica: gore AUTO, dolje ECO
    motor.jd7810AqPressT = 250
    local note = ""
    if motor.gearShiftMode == VehicleMotor.SHIFT_MODE_AUTOMATIC then note = "  (game mode AUTOMATIC: everything automatic)"
    elseif motor.gearShiftMode == VehicleMotor.SHIFT_MODE_MANUAL_CLUTCH then note = "  (game mode MANUAL WITH CLUTCH: ranges A-E with clutch by you, 1-4 by the switch)" end
    setEvent("AutoQuad II: " .. JD7810Transmission.AQ_MODE_NAMES[m] .. note)
end

-- =====================================================================
--  M) GUME: brzine u stupnjevima prema odabranim gumama
--     Omjeri u XML-u su za 20.8R38 (OMAR206904 tablice brzina). Igra racuna
--     omjer po m/s, pa bez ovoga sve gume daju iste brzine. Ovdje se omjeri
--     (stupnjevi, IVT raspon) skaliraju s refRadius / polumjer straznjeg kotaca.
-- =====================================================================
local function copyGears(list)
    if list == nil then return nil end
    local out = {}
    for i, g in ipairs(list) do local c = {}; for k, v in pairs(g) do c[k] = v end; out[i] = c end
    return out
end
function JD7810Transmission.applyTyreScale(motor)
    motor.jd7810TyreDone = true
    local cfg = JD7810Transmission.cfg
    local vehicle = motor.vehicle
    if not cfg.tyreScale or vehicle == nil or vehicle.spec_wheels == nil or vehicle.spec_wheels.wheels == nil then return end
    local r = 0
    for _, w in ipairs(vehicle.spec_wheels.wheels) do
        local rad = (w.physics ~= nil and w.physics.radius) or w.radius
        if type(rad) == "number" and rad > r then r = rad end
    end
    if r < 0.3 then log("gume: polumjer nije pronaden, brzine ostaju kao u XML-u"); return end
    local f = (cfg.tyreRefRadius or 0.908) / r
    motor.jd7810TyreFactor = f
    if math.abs(f - 1) > 0.002 then
        local oldF, oldB = motor.forwardGears, motor.backwardGears
        local newF, newB = copyGears(oldF), copyGears(oldB)      -- vlastite kopije (tablice mogu biti zajednicke)
        for _, g in ipairs(newF or {}) do if type(g.ratio) == "number" then g.ratio = g.ratio * f end end
        for _, g in ipairs(newB or {}) do if type(g.ratio) == "number" then g.ratio = g.ratio * f end end
        if newF ~= nil then motor.forwardGears = newF end
        if newB ~= nil then motor.backwardGears = newB end
        if motor.currentGears == oldF and newF ~= nil then motor.currentGears = newF
        elseif motor.currentGears == oldB and newB ~= nil then motor.currentGears = newB end
        for _, k in ipairs({ "minForwardGearRatio", "maxForwardGearRatio", "minBackwardGearRatio", "maxBackwardGearRatio" }) do
            if type(motor[k]) == "number" then motor[k] = motor[k] * f end
        end
    end
    log(string.format("gume: polumjer straznjeg kotaca %.3f m (referenca 20.8R38 %.3f m) -> omjeri x%.3f, brzine x%.3f", r, cfg.tyreRefRadius or 0.908, f, 1 / f))
end
VehicleMotor.update = Utils.appendedFunction(VehicleMotor.update, function(self, dt)
    if not self.jd7810TyreDone and isOurs(self) then
        local ok, err = pcall(JD7810Transmission.applyTyreScale, self)
        if not ok then self.jd7810TyreDone = true; log("gume: greska " .. tostring(err)) end
    end
end)


-- =====================================================================
--  L2) IVT TRAKE 1 / 2 I ZADANE BRZINE  (OMAR195338: "IVT Description",
--      "Adjusting Set Speeds", "Set Speeds - Guidelines", "Creeper Mode")
--      - rucica ima dva utora (traka 1, traka 2); svaka traka ima zadanu brzinu
--        = najveca brzina na kraju utora pri punom gasu (kotacic na rucici)
--      - zadana brzina 1 uvijek >= 10 % niza od zadane brzine 2
--      - naprijed do 40 km/h, natrag do 18 km/h (zasebne R1 / R2)
--      - puzajuci nacin: F1 < 2 km/h -> F2 = 2,5 x F1 (F2 najvise 10 km/h dok traje)
--      U igri: Num / = traka, LAlt + Num +/- = kotacic (zadana brzina aktivne trake
--      i aktivnog smjera); gas W = koliko je rucica gurnuta u utor.
-- =====================================================================
JD7810Transmission.IVT_MAX_F = 40
JD7810Transmission.IVT_MAX_R = 17      -- v172: natrag samo LOW, do 17 km/h (ASME IMECE2002 / Nebraska 1807)
-- v173: najveca brzina naprijed iz konfiguracije (40 ili 50 km/h)
function JD7810Transmission.ivtMaxF(motor)
    if motor ~= nil and JD7810Transmission.motorTop ~= nil then return JD7810Transmission.motorTop(motor) end
    return JD7810Transmission.IVT_MAX_F
end
JD7810Transmission.ivtSet = JD7810Transmission.ivtSet or { band = 1, F1 = 15, F2 = 40, R1 = 8, R2 = 17, auto = 0 }

local function ivtDir(motor)
    local d = motor.currentDirection
    if d == nil and motor.vehicle ~= nil then d = motor.vehicle.movingDirection end
    return (d ~= nil and d < 0) and "R" or "F"
end
JD7810Transmission.ivtDir = ivtDir

-- aktivna zadana brzina (km/h) i smjer ("F"/"R")
function JD7810Transmission.ivtSetSpeed(motor)
    local S = JD7810Transmission.ivtSet
    local d = ivtDir(motor)
    if (S.auto or 0) > 0.5 then return S[d .. "2"], d end      -- v172 AUTO: granica = zadana brzina 2
    return S[d .. (S.band == 2 and "2" or "1")], d
end

local function ivtStep(v) return v < 2 and 0.1 or 0.5 end

-- pravila iz prirucnika; changed = 1 ili 2 (koja je traka podesena)
local function ivtNormalize(S, d, changed)
    local maxV = d == "R" and JD7810Transmission.IVT_MAX_R or (S.maxF or JD7810Transmission.IVT_MAX_F)
    local k1, k2 = d .. "1", d .. "2"
    S[k1] = clamp(S[k1], 0.05, maxV / 1.1)
    S[k2] = clamp(S[k2], 0.1, maxV)
    if changed == 1 then
        if d == "F" and S[k1] < 2 then
            if S.F2creep == nil then S.F2creep = S[k2] end         -- ulaz u puzajuci nacin: zapamti F2
            S[k2] = math.min(10, S[k1] * 2.5)                      -- puzajuci nacin
        else
            if d == "F" and S.F2creep ~= nil then S[k2] = S.F2creep; S.F2creep = nil end   -- izlaz: vrati F2
            if S[k2] < S[k1] * 1.1 then
                S[k2] = math.min(maxV, S[k1] * 1.1)
            end
        end
    else
        if d == "F" and S[k2] > 10 then S.F2creep = nil end      -- F2 iznad 10 km/h = kraj puzajuceg nacina
        if S[k1] > S[k2] / 1.1 then S[k1] = S[k2] / 1.1 end
    end
end
JD7810Transmission.ivtNormalize = ivtNormalize

function JD7810Transmission.actionIvtBand(vehicle, actionName, inputValue, callbackState, isAnalog)
    local motor = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil
    if motor == nil or not JD7810Transmission.isIVT(motor) then return end
    if JD7810Transmission.switchClick ~= nil then JD7810Transmission.switchClick(vehicle) end   -- v171
    local S = JD7810Transmission.ivtSet
    -- v172: Num / kruzi 1 -> 2 -> AUTO -> 1 (AUTO: traka 1/2 prema mehanickom stupnju LOW/HIGH, rucica se sama pomice)
    if (S.auto or 0) > 0.5 then
        S.auto, S.band = 0, 1
    elseif S.band == 2 then
        S.auto = 1
        S.band = (motor.jd7810IvtRange == "HIGH") and 2 or 1
        local v, d = JD7810Transmission.ivtSetSpeed(motor)
        setEvent(string.format("IVT band AUTO (%s2 %.1f km/h)", d, v))
        return
    else
        S.band = 2
    end
    local v, d = JD7810Transmission.ivtSetSpeed(motor)
    setEvent(string.format("IVT band %d (%s%d): set speed %.1f km/h", S.band, d, S.band, v))
end

local function stepIvtSet(motor, direction)
    local S = JD7810Transmission.ivtSet
    local d = ivtDir(motor)
    local band = S.band == 2 and 2 or 1
    local k = d .. band
    local v = S[k]
    local st = ivtStep(direction > 0 and v or math.max(0.05, v - 0.001))
    v = math.floor(v / st + 0.5) * st + direction * st
    S[k] = v
    ivtNormalize(S, d, band)
    JD7810Transmission.ivtWheelSteps = (JD7810Transmission.ivtWheelSteps or 0) + direction   -- animacija kotacica
    local creep = d == "F" and S.F1 < 2 and S.F2 <= 10
    setEvent(string.format("IVT %s%d: %.1f km/h  (%s1 %.1f / %s2 %.1f)%s", d, band, S[k], d, S[d .. "1"], d, S[d .. "2"],
        creep and "  - creeper mode" or ""))
end

-- tipka: kratki pritisak = jedan korak, drzanje = ponavljanje
function JD7810Transmission.actionIvtSet(vehicle, actionName, inputValue, callbackState, isAnalog)
    local motor = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil
    if motor == nil or not JD7810Transmission.isIVT(motor) then return end
    local now = g_time or 0
    if inputValue == nil or inputValue == 0 then
        motor.jd7810SetKeyDown = nil
        return
    end
    if motor.jd7810SetKeyDown == nil or now - (motor.jd7810SetKeyLast or 0) > 250 then
        motor.jd7810SetKeyDown = now
        motor.jd7810SetKeyStep = now
        stepIvtSet(motor, callbackState or 1)
    elseif now - motor.jd7810SetKeyDown > 400 and now - (motor.jd7810SetKeyStep or 0) > 150 then
        motor.jd7810SetKeyStep = now
        stepIvtSet(motor, callbackState or 1)
    end
    motor.jd7810SetKeyLast = now
end

-- zadana brzina aktivne trake = najveca brzina (kraj utora pri punom gasu); AI vozi bez ogranicenja
VehicleMotor.getSpeedLimit = Utils.overwrittenFunction(VehicleMotor.getSpeedLimit, function(self, superFunc)
    local limit = superFunc(self)
    if isOurs(self) and JD7810Transmission.isIVT ~= nil and JD7810Transmission.isIVT(self) and not isAIActive(self.vehicle) then
        local v = JD7810Transmission.ivtSetSpeed(self)
        if v ~= nil then limit = math.min(limit, v) end
    end
    return limit
end)


-- =====================================================================
--  L3) v172: IVT MEHANICKI STUPNJEVI LOW / HIGH  +  AUTO TRAKA
--      Nebraska test 1807 (2002): "Infinity variable with two ranges with automatic shifting
--      between ranges. Low range 0-17 km/h, high range 0-42 km/h". Patent US 6,485,387
--      (Deere + Sauer-Danfoss): hidromehanicka podjela snage, spojka CL (low) / CH (high),
--      kocnica BR (natrag). Natrag samo LOW (do 17 km/h, ASME IMECE2002).
--      - stupanj prema PRIJENOSU: brzina svedena na 2100 o/min i referentnu gumu 20.8R38
--      - sinkrono prebacivanje: okretaji ne skacu; kratki pad momenta (shiftDip)
--      - gubitak hidraulike: 0 u mehanickoj tocki stupnja, raste prema krajevima (pila)
--      PROCJENA (izvori ne navode): tocke prebacivanja 16 / 14,7 km/h, mehanicke tocke
--      LOW 8 / HIGH 28 km/h, najveci gubitak 10 %. Sve x (najveca brzina / 40) za 50 km/h.
--      AUTO traka (Num / -> AUTO): traka prati stupanj (LOW = 1, HIGH = 2), rucica se sama
--      pomice iz utora 1 u utor 2. ODSTUPANJE: pravi 7810 nema automatski izbor trake.
-- =====================================================================
function JD7810Transmission.ivtRangePoints(motor)
    local cfg = JD7810Transmission.cfg
    local k = JD7810Transmission.ivtMaxF(motor) / 40
    return (cfg.ivtRangeUp or 16) * k, (cfg.ivtRangeDown or 14.7) * k, 8 * k, 28 * k, 40 * k
end

-- brzina pri 2100 o/min s referentnom gumom (= prijenos mjenjaca, km/h)
local function ivtRefSpeed(motor)
    local rpm = JD.U.engineRpm(motor)
    if rpm == nil or rpm < 300 then return 0 end
    return getSpeedKmh(motor) * (motor.jd7810TyreFactor or 1) * 2100 / rpm
end

function JD7810Transmission.ivtUpdateRange(motor)
    local cfg = JD7810Transmission.cfg
    local now = g_time or 0
    local last = motor.jd7810IvtRangeT0 or now
    motor.jd7810IvtRangeT0 = now
    local dt = clamp(now - last, 0, 200)
    if motor.jd7810IvtRange == nil then motor.jd7810IvtRange = "LOW"; motor.jd7810IvtRangeT = now end
    if cfg.ivtRanges == false or isAIActive(motor.vehicle) then
        motor.jd7810IvtEff = 1
        return
    end
    local up, down, mechL, mechH, top = JD7810Transmission.ivtRangePoints(motor)
    local v = ivtRefSpeed(motor)
    local back = (motor.currentDirection or 1) < 0
    local range = motor.jd7810IvtRange
    local since = now - (motor.jd7810IvtRangeT or 0)
    -- proklizavanje (za AUTO traku: dok kotaci proklizavaju nema vise)
    local slipNow = (JD.U.wheelSlip ~= nil and getSpeedKmh(motor) < 25) and JD.U.wheelSlip(motor.vehicle) or 0
    motor.jd7810IvtSlip = (motor.jd7810IvtSlip or slipNow) + (slipNow - (motor.jd7810IvtSlip or slipNow)) * math.min(1, dt / 500)

    local new = range
    if back then
        new = "LOW"
    elseif range == "LOW" and v > up and since > 1000 then
        new = "HIGH"
    elseif range == "HIGH" and v < down and since > 1000 then
        new = "LOW"
    end
    if new ~= range then
        motor.jd7810IvtRange, motor.jd7810IvtRangeT = new, now
        -- sinkrona promjena: bez skoka okretaja, kratki pad momenta
        motor.jd7810IvtDipT = cfg.ivtRangeDipTime or 150
        if cfg.debug or cfg.draftLog then
            log(string.format("TEST ivt stupanj %s -> %s pri %.1f km/h (%.0f o/min, prijenos %.1f km/h@2100)",
                range, new, getSpeedKmh(motor), JD.U.engineRpm(motor) or 0, v))
        end
    end

    -- udio hidraulike i ucinkovitost (pila po stupnju)
    local share
    if motor.jd7810IvtRange == "LOW" then
        share = math.abs(v - mechL) / math.max(1, mechL)
    else
        share = math.abs(v - mechH) / math.max(1, mechH - up)
    end
    share = clamp(share, 0, 1)
    motor.jd7810IvtHydro = share
    local eff = 1 - (cfg.ivtHydroLoss or 0.10) * share
    local dip = motor.jd7810IvtDipT or 0
    if dip > 0 then
        dip = math.max(0, dip - dt)
        motor.jd7810IvtDipT = dip
        eff = eff * (1 - (cfg.ivtRangeDip or 0.05))
    end
    motor.jd7810IvtEff = eff

    -- AUTO traka: traka 1 = LOW, traka 2 = HIGH (uz blokadu vise dok kotaci proklizavaju)
    local S = JD7810Transmission.ivtSet
    local P = JD7810Transmission.pmStates ~= nil and JD7810Transmission.pmStates[motor.vehicle] or nil
    if S ~= nil and (S.auto or 0) > 0.5 and (P == nil or P.ivt == S) then   -- samo traktor u kojem se sjedi
        local want = (motor.jd7810IvtRange == "HIGH") and 2 or 1
        if want == 2 and S.band ~= 2 and (motor.jd7810IvtSlip or 0) > (cfg.upSlipMax or 15) then
            want = 1                                -- dok kotaci proklizavaju traka ostaje 1
        end
        if want ~= S.band and now - (motor.jd7810IvtBandT or 0) > 2000 then
            S.band = want
            motor.jd7810IvtBandT = now
        end
    end
end

-- =====================================================================
--  L4) v172: FAKTOR MOMENTA MOTORA (gubitak hidraulike IVT, v173 power boost)
--      Fizika igre dobiva krivulju momenta preko getTorqueCurveValue -> updateMotorProperties
--      (isto kako igra radi za stetu). Novi faktor se salje tek kad se promijeni >= 1 % i
--      najvise svakih 250 ms (bez poziva svaki frame).
-- =====================================================================
-- v173: power boost verzija 50 km/h (Farmers Journal: 175 -> 196 KS "for PTO applications, or at speeds above 30km/h")
function JD7810Transmission.updateBoost(motor)
    local cfg = JD7810Transmission.cfg
    local now = g_time or 0
    local dt = math.min(math.max(now - (motor.jd7810BoostT0 or now), 0), 200)
    motor.jd7810BoostT0 = now
    local full = cfg.powerBoost or 1.12
    local target = 1
    if JD7810Transmission.motorTop(motor) >= 50 and full > 1 then
        local spd = getSpeedKmh(motor)
        local on = motor.jd7810BoostOn
        if (motor.jd7810PtoActive or 0) > 0 or spd > 30 then on = true elseif spd < 28 then on = false end
        if on ~= motor.jd7810BoostOn then
            motor.jd7810BoostOn = on
            if cfg.debug or cfg.draftLog then log(string.format("TEST power boost %s (%.1f km/h, PTO %s)", on and "ON" or "off", spd, tostring((motor.jd7810PtoActive or 0) > 0))) end
        end
        if on then target = full end
    end
    local f = motor.jd7810BoostF or 1
    local step = (full - 1) * dt / 2000                    -- 2 s do punog boosta
    if target > f then f = math.min(target, f + step) else f = math.max(target, f - step) end
    motor.jd7810BoostF = f
end

VehicleMotor.getTorqueCurveValue = Utils.overwrittenFunction(VehicleMotor.getTorqueCurveValue, function(self, superFunc, rpm)
    local t = superFunc(self, rpm)
    local f = self.jd7810TorqueApplied
    if f ~= nil and f ~= 1 and type(t) == "number" then t = t * f end
    return t
end)

function JD7810Transmission.updateTorqueFactor(motor)
    local f = 1
    if not isAIActive(motor.vehicle) then
        JD7810Transmission.updateBoost(motor)
        f = (motor.jd7810IvtEff or 1) * (motor.jd7810BoostF or 1)
    end
    local cur = motor.jd7810TorqueApplied or 1
    local now = g_time or 0
    if math.abs(f - cur) >= 0.01 and now - (motor.jd7810TorqueT or 0) >= 250 then
        motor.jd7810TorqueApplied = f
        motor.jd7810TorqueT = now
        local v = motor.vehicle
        if v ~= nil and v.isServer and v.updateMotorProperties ~= nil then pcall(v.updateMotorProperties, v) end
    end
end
VehicleMotor.update = Utils.appendedFunction(VehicleMotor.update, function(self, dt)
    if isOurs(self) then
        local ok, err = pcall(JD7810Transmission.updateTorqueFactor, self)
        if not ok and not self.jd7810TorqueErr then self.jd7810TorqueErr = true; log("moment: greska " .. tostring(err)) end
    end
end)
