-- =====================================================================
--  JD7810Engine.lua   v8.1  (FS25 - osobna upotreba, Darijan)
--  motor: kocenje motorom, proklizavanje spojke, zvukovi mjenjaca, glavna petlja motora (VehicleMotor.update), rucni gas (numpad +/-), registracija tipki
--  v8.1: podjela JD7810Transmission.lua v8.0 na module - kod premjesten
--        bez promjene ponasanja.
--  v8.2: rucica Powershift mjenjaca; greske rucica jednom u log. Redoslijed ucitavanja u modDesc.xml:
--        Core, Transmission, Engine, PTO, Display, PerformanceMonitor, AgroGsm, Cockpit
-- =====================================================================

local JD = JD7810Transmission
local getSpeedKmh = JD.U.getSpeedKmh
local isOurs = JD.U.isOurs
local ptoIsManual = JD.U.ptoIsManual
local setEvent = JD.U.setEvent
local isAIActive = JD.U.isAIActive

-- =====================================================================
--  B) Motor: kocenje motorom, kretanje s mjesta, odbrojavanja
-- =====================================================================
-- zvukovi: svaki uzorak pamti svoju originalnu glasnocu, mnozimo je postavkom
JD7810Transmission.GEAR_SAMPLES = { "gearEngaged", "gearDisengaged", "gearGroupChange", "gearRangeChange",
    "gearLeverStart", "gearLeverEnd", "gearGroupLeverStart", "gearGroupLeverEnd", "clutchCracking" }

local function scaleSample(sample, factor)
    if type(sample) ~= "table" then
        return
    end
    if sample.volumeScale == nil and sample[1] ~= nil then   -- lista uzoraka
        for _, s in ipairs(sample) do
            scaleSample(s, factor)
        end
        return
    end
    if sample.jd7810BaseVolume == nil then
        sample.jd7810BaseVolume = sample.volumeScale or 1
    end
    sample.volumeScale = sample.jd7810BaseVolume * factor
end

local function scaleSampleList(list, factor)
    if type(list) == "table" then
        for _, sample in pairs(list) do
            scaleSample(sample, factor)
        end
    end
end

function JD7810Transmission.applySounds(vehicle)
    local cfg = JD7810Transmission.cfg
    local m = vehicle.spec_motorized
    if m ~= nil then
        scaleSampleList(m.motorSamples, cfg.engineSound)
        scaleSampleList(m.gearboxSamples, cfg.gearboxSound)
        if m.samples ~= nil then
            for _, name in ipairs(JD7810Transmission.GEAR_SAMPLES) do
                scaleSample(m.samples[name], cfg.gearSound)
            end
        end
    end
    local w = vehicle.spec_wheels
    if w ~= nil then
        local motor = m ~= nil and m.motor or nil
        scaleSampleList(w.surfaceSounds, (motor ~= nil and motor.jd7810TireVol) or cfg.tireSound)
    end
end

-- =====================================================================
--  v176: ZVUK GUMA PREMA SIRINI I BRZINI (Darijan 9.10.)
--  W = ukupna sirina gaznog sloja straznje osovine / tvornicka 20.8R38 (2 x 0,541 m); duple = 2 gume.
--  Glasnoca = sound#tires x W^e, e = 0,3 + 0,7 x (brzina / najveca brzina) - sporo male razlike,
--  na najvecoj brzini puna razlika (duple ~2x, uske 1,5 m ~0,7x). Komunalne (cestovni profil) x 0,7.
--  sound#tireWidth = jacina ucinka (1 = puno, 0 = iskljuceno). Svakih 0,25 s, najvise 3x izvorno.
-- =====================================================================
local TIRE_REF_W = 2 * 0.541
function JD7810Transmission.tireWidthFactor(vehicle)
    local sw = vehicle.spec_wheels
    if sw == nil or sw.wheels == nil then return 1, false end
    if vehicle.jd7810TireW ~= nil then return vehicle.jd7810TireW, vehicle.jd7810TireStreet end
    local maxR = 0
    for _, wh in ipairs(sw.wheels) do
        local ph = wh.physics
        if ph ~= nil then maxR = math.max(maxR, ph.radiusOriginal or ph.radius or 0) end
    end
    local total, street = 0, false
    local streetType = (WheelsUtil ~= nil and WheelsUtil.getTireType ~= nil) and WheelsUtil.getTireType("street") or nil
    for _, wh in ipairs(sw.wheels) do
        local ph = wh.physics
        if ph ~= nil and (ph.radiusOriginal or ph.radius or 0) >= 0.95 * maxR then      -- straznja osovina (veci kotaci)
            local w0 = ph.jd7810TyreB or ph.width or 0.5
            local n = ph.jd7810TyreN or (((ph.wheelShapeWidth or w0) > 1.6 * w0) and 2 or 1)
            total = total + n * w0
            if streetType ~= nil and ph.tireType == streetType then street = true end
        end
    end
    if total <= 0 then return 1, false end
    vehicle.jd7810TireW, vehicle.jd7810TireStreet = total / TIRE_REF_W, street
    JD.U.log(string.format("zvuk guma: sirina straga %.2f m -> faktor %.2f%s", total, vehicle.jd7810TireW, street and ", cestovni profil" or ""))
    return vehicle.jd7810TireW, street
end
local function updateTireSound(motor)
    local cfg = JD7810Transmission.cfg
    local base = cfg.tireSound or 1
    local k = cfg.tireWidthSound or 1.0
    local vol = base
    if k > 0 then
        local W, street = JD7810Transmission.tireWidthFactor(motor.vehicle)
        local top = (JD7810Transmission.motorTop ~= nil and JD7810Transmission.motorTop(motor)) or 40
        local x = math.min(math.max(getSpeedKmh(motor) / math.max(top, 1), 0), 1)
        local e = (0.3 + 0.7 * x) * k
        vol = base * math.max(W, 0.2) ^ e * (street and 0.7 or 1)
    end
    vol = math.min(vol, 3.0)
    if motor.jd7810TireVol == nil or math.abs(vol - motor.jd7810TireVol) > 0.02 then
        motor.jd7810TireVol = vol
        local w = motor.vehicle.spec_wheels
        if w ~= nil then scaleSampleList(w.surfaceSounds, vol) end
    end
end

-- PTO: pravi 7810 ima 540 i 1000 PTO, oba na nazivnih 2100 o/min motora.
-- Igra ima samo jedan omjer (3.89), pa 1000 PTO trazi 3890 o/min = motor na maksimumu.
local function updatePtoRatio(motor)
    local cfg = JD7810Transmission.cfg
    if motor.jd7810BasePtoRatio == nil then
        motor.jd7810BasePtoRatio = motor.ptoMotorRpmRatio
    end
    if not cfg.ptoFix or PowerConsumer == nil or PowerConsumer.getMaxPtoRpm == nil then
        motor.ptoMotorRpmRatio = motor.jd7810BasePtoRatio
        return
    end
    local ok, ptoRpm = pcall(PowerConsumer.getMaxPtoRpm, motor.vehicle)
    if ok and type(ptoRpm) == "number" and ptoRpm > 0 then
        if ptoRpm > 700 then
            motor.ptoMotorRpmRatio = cfg.pto1000Rpm / 1000
        else
            motor.ptoMotorRpmRatio = cfg.pto540Rpm / 540
        end
        motor.jd7810PtoRpm = ptoRpm
    else
        motor.jd7810PtoRpm = 0
    end
end

VehicleMotor.update = Utils.overwrittenFunction(VehicleMotor.update, function(self, superFunc, dt)
    if isOurs(self) then
        updatePtoRatio(self)
        if ptoIsManual(self) then
            self.lastPtoRpm = self.minRpm   -- igra ne prikazuje/ne drzi PTO okretaje umjesto motora
        end
    end

    -- RUCNI GAS u N / sa stisnutom spojkom (rucni nacini igre): igra tada okretaje motora racuna samo iz papucice gasa
    -- (VehicleMotor:update, motorRotSpeedClutchEngaged = min + (max - min) x papucica) - ne iz regulatora;
    -- zato za taj izracun rucni gas glumi papucicu toliko koliko odgovara zadanim okretajima
    local savedPedal = nil
    local hand = self.jd7810HandRpm or 0
    if hand > 0 and isOurs(self) and not self:getUseAutomaticGearShifting() then
        local span = math.max((self.maxRpm or 2300) - (self.minRpm or 850), 1)
        local frac = math.min(math.max((hand - (self.minRpm or 850)) / span, 0), 1)
        if math.abs(self.lastAcceleratorPedal or 0) < frac then
            savedPedal = self.lastAcceleratorPedal or 0
            local dir = (self.currentDirection or 1) >= 0 and 1 or -1
            self.lastAcceleratorPedal = frac * dir        -- igra mnozi s currentDirection -> pozitivno
        end
    end

    superFunc(self, dt)

    if savedPedal ~= nil then self.lastAcceleratorPedal = savedPedal end

    -- v131: Field Cruise iskljucen (Darijan 6.10.) - kolutovi AQ/IVT ostaju u polozaju "iskljuceno"
    if isOurs(self) and not JD7810Transmission.cfg.fieldCruise then self.jd7810FieldCruise = 0 end

    -- v131: okretaji s inercijom zamasnjaka (fizika daje sirovu vrijednost svaki frame -> broj "plese")
    if isOurs(self) then
        local raw = self:getLastRealMotorRpm() or 0
        local tau = JD7810Transmission.cfg.rpmTau or 0
        if self.jd7810Rpm == nil or tau <= 0 or dt <= 0 then
            self.jd7810Rpm = raw
        else
            self.jd7810Rpm = self.jd7810Rpm + (raw - self.jd7810Rpm) * (1 - math.exp(-dt / (tau * 1000)))
        end
    end

    if isOurs(self) and JD7810Transmission.updateConsoleControls ~= nil then
        JD7810Transmission.updateConsoleControls(self, dt)
        pcall(JD7810Transmission.updatePerformanceMonitor, self, dt)
        pcall(JD7810Transmission.updateAgroGsm, self.vehicle, dt)       -- mobitel radi s vozilom (ne s motorom)
        pcall(JD7810Transmission.updateHms, self, dt)                  -- HMS + GreenStar terminal (JD7810Hms.lua)
        if JD7810Transmission.updateSeatAndTele ~= nil then pcall(JD7810Transmission.updateSeatAndTele, self, dt) end   -- sjedalo + telemetrija (JD7810Seat.lua)
        pcall(JD7810Transmission.updateBoostGauge, self, dt)
        if JD7810Transmission.updateCenterLcd ~= nil then
            local okL, errL = pcall(JD7810Transmission.updateCenterLcd, self, dt)
            if not okL and not self.jd7810LcdErr then self.jd7810LcdErr = true; print("JD7810: greska srednjeg LCD-a: " .. tostring(errL)) end
        end
    end
    if isOurs(self) and JD7810Transmission.updateTools ~= nil then
        JD7810Transmission.updateTools(self, dt)
        local fn = nil
        if JD7810Transmission.isIVT(self) then
            fn = JD7810Transmission.updateIVTLever
        elseif JD7810Transmission.isAutoQuad ~= nil and JD7810Transmission.isAutoQuad(self) then
            fn = JD7810Transmission.updateAQLever
            if JD7810Transmission.updateAQControls ~= nil then pcall(JD7810Transmission.updateAQControls, self, dt) end
        elseif JD7810Transmission.isPowershift ~= nil and JD7810Transmission.isPowershift(self) then
            fn = JD7810Transmission.updatePSLever
        end
        if fn ~= nil then
            local ok, err = pcall(fn, self, dt)
            if not ok and not self.jd7810LeverErr then
                self.jd7810LeverErr = true                                 -- jednom u log, ne svaki frame
                print("JD7810: greska rucice mjenjaca: " .. tostring(err))
            end
        end
    end

    if not isOurs(self) then
        return
    end
    local cfg = JD7810Transmission.cfg

    -- zvukovi (jednom u sekundi, da jd7810Set djeluje odmah)
    self.jd7810SoundTimer = (self.jd7810SoundTimer or 0) - dt
    if self.jd7810SoundTimer <= 0 then
        self.jd7810SoundTimer = 1000
        JD7810Transmission.applySounds(self.vehicle)
    end
    -- v176: zvuk guma prema sirini i brzini (4x u sekundi)
    self.jd7810TireSndT = (self.jd7810TireSndT or 0) - dt
    if self.jd7810TireSndT <= 0 then
        self.jd7810TireSndT = 250
        local okT, errT = pcall(updateTireSound, self)
        if not okT and not self.jd7810TireSndErr then self.jd7810TireSndErr = true; JD.U.log("zvuk guma: greska " .. tostring(errT)) end
    end

    if self.jd7810SlipTimer ~= nil and self.jd7810SlipTimer > 0 then
        self.jd7810SlipTimer = math.max(self.jd7810SlipTimer - dt, 0)
    end

    -- jacina kocenja motorom
    if self.dampingRateZeroThrottleClutchEngaged ~= nil then
        if self.jd7810BaseEngineBrake == nil then
            self.jd7810BaseEngineBrake = self.dampingRateZeroThrottleClutchEngaged
        end
        self.dampingRateZeroThrottleClutchEngaged = self.jd7810BaseEngineBrake * cfg.engineBrake
    end

    -- proklizavanje spojke pri kretanju (mijenja se samo kad spojka ne proklizava)
    if self.clutchSlippingTimer ~= nil and self.clutchSlippingTimer == 0 then
        self.clutchSlippingTime = cfg.startSlipTime
    end
end)

-- =====================================================================
--  G) RUCNI GAS (numpad + / -)
--   - drzi zadane okretaje (regulator), nozni gas moze dodati iznad
--   - u mjestu: motor na zadanim okretajima (npr. PTO rad)
--   - u voznji: kad jednom dodas gas, traktor vozi i bez gasa
--     (kao pravi traktor s ukljucenom brzinom); kocenjem do stop se prekida
--   - dok vozi na rucni gas, automatik ne mijenja brzine
-- =====================================================================
function JD7810Transmission.setHandThrottle(motor, rpm)
    local cfg = JD7810Transmission.cfg
    if rpm == nil or rpm < cfg.handMin then
        motor.jd7810HandRpm = 0
        motor.jd7810HandDrive = false
        setEvent("Hand throttle off")
    else
        motor.jd7810HandRpm = math.min(rpm, cfg.handMax, motor.maxRpm or rpm)
        setEvent(string.format("Hand throttle: %.0f rpm", motor.jd7810HandRpm))
    end
end

local function stepHandThrottle(motor, direction)
    local cfg = JD7810Transmission.cfg
    local cur = motor.jd7810HandRpm or 0
    if direction > 0 then
        if cur == 0 then
            local rpm = JD.U.engineRpm(motor) or cfg.handMin
            cur = math.max(cfg.handMin, math.ceil((rpm + 1) / cfg.handStep) * cfg.handStep)
        else
            cur = cur + cfg.handStep
        end
        JD7810Transmission.setHandThrottle(motor, cur)
    elseif cur > 0 then
        JD7810Transmission.setHandThrottle(motor, cur - cfg.handStep)
    end
end

-- tipka: kratki pritisak = jedan korak, drzanje = ponavljanje
function JD7810Transmission.actionHandThrottle(vehicle, actionName, inputValue, callbackState, isAnalog)
    local motor = vehicle.getMotor ~= nil and vehicle:getMotor() or nil
    if motor == nil or not isOurs(motor) then
        return
    end
    local now = g_time or 0
    if inputValue == nil or inputValue == 0 then
        motor.jd7810KeyDown = nil
        return
    end
    if motor.jd7810KeyDown == nil or now - (motor.jd7810KeyLast or 0) > 250 then
        motor.jd7810KeyDown = now
        motor.jd7810KeyStep = now
        stepHandThrottle(motor, callbackState or 1)
    elseif now - motor.jd7810KeyDown > 400 and now - (motor.jd7810KeyStep or 0) > 120 then
        motor.jd7810KeyStep = now
        stepHandThrottle(motor, callbackState or 1)
    end
    motor.jd7810KeyLast = now
end

if Motorized ~= nil and Motorized.onRegisterActionEvents ~= nil then
    Motorized.onRegisterActionEvents = Utils.appendedFunction(Motorized.onRegisterActionEvents, function(self, isActiveForInput, isActiveForInputIgnoreSelection)
        local spec = self.spec_motorized
        if not self.isClient or spec == nil or spec.motor == nil or not isOurs(spec.motor) then
            return
        end
        if isActiveForInputIgnoreSelection and InputAction.JD7810_HAND_THROTTLE_UP ~= nil and InputAction.JD7810_HAND_THROTTLE_DOWN ~= nil then
            local _, idUp = self:addActionEvent(spec.actionEvents, InputAction.JD7810_HAND_THROTTLE_UP, self, JD7810Transmission.actionHandThrottle, false, true, true, true, 1)
            local _, idDown = self:addActionEvent(spec.actionEvents, InputAction.JD7810_HAND_THROTTLE_DOWN, self, JD7810Transmission.actionHandThrottle, false, true, true, true, -1)
            local idWork = nil
            -- v185: work drive uklonjen (Darijan 9.10.)
            -- v155: zakljucavanje smjera po kompasu (JD7810Heading.lua)
            if InputAction.JD7810_HEADING_LOCK ~= nil and JD7810Transmission.actionHeadingLock ~= nil then
                local _, idHead = self:addActionEvent(spec.actionEvents, InputAction.JD7810_HEADING_LOCK, self, JD7810Transmission.actionHeadingLock, false, true, false, true, nil)
                if idHead ~= nil and GS_PRIO_LOW ~= nil then g_inputBinding:setActionEventTextPriority(idHead, GS_PRIO_LOW) end
            end
            local idMode, idFc, idBand, idSetUp, idSetDown, idAq = nil, nil, nil, nil, nil, nil
            if InputAction.JD7810_FIELD_CRUISE ~= nil and JD7810Transmission.cfg.fieldCruise then   -- v131: iskljuceno (kolut samo vizualno)
                _, idFc = self:addActionEvent(spec.actionEvents, InputAction.JD7810_FIELD_CRUISE, self, JD7810Transmission.actionFieldCruise, false, true, false, true, nil)
            end
            local idAq2 = nil
            if InputAction.JD7810_AQ_MODE ~= nil and JD7810Transmission.isAutoQuad ~= nil and JD7810Transmission.isAutoQuad(spec.motor) then
                _, idAq = self:addActionEvent(spec.actionEvents, InputAction.JD7810_AQ_MODE, self, JD7810Transmission.actionAqMode, false, true, false, true, nil)
                -- v177: nacin mjenjaca = jedna tipka (LCtrl+Num 9) za AQ i IVT
                if InputAction.JD7810_IVT_MODE ~= nil then
                    _, idAq2 = self:addActionEvent(spec.actionEvents, InputAction.JD7810_IVT_MODE, self, JD7810Transmission.actionAqMode, false, true, false, true, nil)
                end
            end
            if JD7810Transmission.isIVT(spec.motor) then
                if InputAction.JD7810_IVT_MODE ~= nil then
                    _, idMode = self:addActionEvent(spec.actionEvents, InputAction.JD7810_IVT_MODE, self, JD7810Transmission.actionIvtMode, false, true, false, true, nil)
                end
                -- IVT trake 1/2 i kotacic zadane brzine
                if InputAction.JD7810_IVT_BAND ~= nil then
                    _, idBand = self:addActionEvent(spec.actionEvents, InputAction.JD7810_IVT_BAND, self, JD7810Transmission.actionIvtBand, false, true, false, true, nil)
                end
                if InputAction.JD7810_IVT_SET_UP ~= nil and InputAction.JD7810_IVT_SET_DOWN ~= nil then
                    _, idSetUp = self:addActionEvent(spec.actionEvents, InputAction.JD7810_IVT_SET_UP, self, JD7810Transmission.actionIvtSet, false, true, true, true, 1)
                    _, idSetDown = self:addActionEvent(spec.actionEvents, InputAction.JD7810_IVT_SET_DOWN, self, JD7810Transmission.actionIvtSet, false, true, true, true, -1)
                end
            end
            local idHud = nil
            if InputAction.JD7810_HUD ~= nil and JD7810Transmission.actionHud ~= nil then
                _, idHud = self:addActionEvent(spec.actionEvents, InputAction.JD7810_HUD, self, JD7810Transmission.actionHud, false, true, false, true, nil)
            end
            local idMfwd, idDiff = nil, nil
            if InputAction.JD7810_MFWD ~= nil then
                _, idMfwd = self:addActionEvent(spec.actionEvents, InputAction.JD7810_MFWD, self, JD7810Transmission.actionMfwd, false, true, false, true, nil)
            end
            if InputAction.JD7810_DIFFLOCK ~= nil then
                _, idDiff = self:addActionEvent(spec.actionEvents, InputAction.JD7810_DIFFLOCK, self, JD7810Transmission.actionDiffLock, false, true, false, true, nil)
            end
            local idBoth = nil
            if InputAction.JD7810_IMPLEMENT_BOTH ~= nil then
                _, idBoth = self:addActionEvent(spec.actionEvents, InputAction.JD7810_IMPLEMENT_BOTH, self, JD7810Transmission.actionImplementBoth, false, true, false, true, nil)
            end
            local idPm, idPmW, idPmZ = nil, nil, nil
            if InputAction.JD7810_PM_MODE ~= nil then
                _, idPm = self:addActionEvent(spec.actionEvents, InputAction.JD7810_PM_MODE, self, JD7810Transmission.actionPmMode, false, true, false, true, nil)
            end
            local idPmP = nil
            if InputAction.JD7810_PM_PREV ~= nil then
                _, idPmP = self:addActionEvent(spec.actionEvents, InputAction.JD7810_PM_PREV, self, JD7810Transmission.actionPmPrev, false, true, false, true, nil)
            end
            if InputAction.JD7810_PM_WIDTH ~= nil then
                _, idPmW = self:addActionEvent(spec.actionEvents, InputAction.JD7810_PM_WIDTH, self, JD7810Transmission.actionPmWidth, false, true, false, true, nil)
            end
            if InputAction.JD7810_PM_ZERO ~= nil then
                _, idPmZ = self:addActionEvent(spec.actionEvents, InputAction.JD7810_PM_ZERO, self, JD7810Transmission.actionPmZero, false, true, false, true, nil)
            end
            -- v175: tlak u gumama (RShift + Num +/-, drzi se dok se tlak mijenja)
            local idTyU, idTyD = nil, nil
            if InputAction.JD7810_TYRE_UP ~= nil and InputAction.JD7810_TYRE_DOWN ~= nil and JD7810Transmission.actionTyre ~= nil then
                _, idTyU = self:addActionEvent(spec.actionEvents, InputAction.JD7810_TYRE_UP, self, JD7810Transmission.actionTyre, false, true, true, true, 1)
                _, idTyD = self:addActionEvent(spec.actionEvents, InputAction.JD7810_TYRE_DOWN, self, JD7810Transmission.actionTyre, false, true, true, true, -1)
            end
            -- F1 izbornik: samo tipka HUD-a; sve ostale tipke i stanja prikazuje HUD
            -- v177: park (LAlt+6)
            local idPark = nil
            if InputAction.JD7810_PARK ~= nil then
                _, idPark = self:addActionEvent(spec.actionEvents, InputAction.JD7810_PARK, self, JD7810Transmission.actionPark, false, true, false, true, nil)
            end
            -- v180: svjetla Ctrl+F (natrag) i Shift+F (radna)
            local idLd, idWl = nil, nil
            if InputAction.JD7810_LIGHTS_DOWN ~= nil and self.spec_lights ~= nil then
                _, idLd = self:addActionEvent(spec.actionEvents, InputAction.JD7810_LIGHTS_DOWN, self, JD7810Transmission.actionLightsDown, false, true, false, true, nil)
            end
            if InputAction.JD7810_WORK_LIGHTS ~= nil and self.spec_lights ~= nil then
                _, idWl = self:addActionEvent(spec.actionEvents, InputAction.JD7810_WORK_LIGHTS, self, JD7810Transmission.actionWorkLights, false, true, false, true, nil)
            end
            for _, id in pairs({ idLd, idWl, idPark, idAq2, idTyU, idTyD, idUp, idDown, idWork, idMode, idFc, idAq, idBand, idSetUp, idSetDown, idBoth, idPm, idPmP, idPmW, idPmZ, idMfwd, idDiff }) do
                if id ~= nil then
                    g_inputBinding:setActionEventTextVisibility(id, false)
                end
            end
            if idHud ~= nil then
                g_inputBinding:setActionEventTextPriority(idHud, GS_PRIO_VERY_HIGH or GS_PRIO_HIGH)
                g_inputBinding:setActionEventTextVisibility(idHud, true)
            end
            -- srednji LCD: tipke na dodir A/B/C/D
            for i, a in ipairs({ "JD7810_LCD_A", "JD7810_LCD_B", "JD7810_LCD_C", "JD7810_LCD_D" }) do
                if InputAction[a] ~= nil and JD7810Transmission.actionLcd ~= nil then
                    local _, id = self:addActionEvent(spec.actionEvents, InputAction[a], self, JD7810Transmission.actionLcd, false, true, false, true, i)
                    if id ~= nil then g_inputBinding:setActionEventTextVisibility(id, false) end
                end
            end
        end
    end)
end

-- okretaji: rucni gas je regulator (max), u mjestu i minimum (kao PTO)
-- v178: automatski PTO okretaji - nazivni okretaji alata koji radi I spusten je (0 = nista)
-- ODSTUPANJE od pravog 7810 (tamo okretaje uvijek das rucnim gasom); iskljucivo u izborniku
-- alat koji se ne spusta (vuceni, preso s pickupom gleda pickup) vrijedi kao spusten
-- v179: snaga koju alati traze na PTO-u (kW, kao igra: neededMin + opterecenje x (max - min), pri nazivnom PTO-u)
--       i najveca snaga motora (peakMotorPower). Racuna se najvise 4x u sekundi.
function JD7810Transmission.ptoPower(motor)
    local now = g_time or 0
    if motor.jd7810PtoKwT ~= nil and now - motor.jd7810PtoKwT < 250 then return motor.jd7810PtoKw or 0, motor.jd7810PtoKwLow or 0 end
    motor.jd7810PtoKwT = now
    local kw, kwLow = 0, 0
    for tool, st in pairs(JD7810Transmission.tools) do
        local pc = tool.spec_powerConsumer
        if st.active and pc ~= nil and (pc.ptoRpm or 0) > 0 and type(tool.getConsumedPtoTorque) == "function" then
            local ok, tq = pcall(tool.getConsumedPtoTorque, tool, false, true)
            if ok and type(tq) == "number" then
                local k = tq * pc.ptoRpm * math.pi / 30
                kw = kw + k
                local okL, low = pcall(tool.getIsLowered, tool, true)
                if (not okL) or low ~= false then kwLow = kwLow + k end
            end
        end
    end
    motor.jd7810PtoKw, motor.jd7810PtoKwLow = kw, kwLow
    return kw, kwLow
end

function JD7810Transmission.ptoAutoTarget(motor)
    if not JD.cfg.ptoAutoRpm or (motor.jd7810PtoActive or 0) <= 0 then return 0 end
    if (motor.jd7810HandRpm or 0) > 0 or isAIActive(motor.vehicle) then return 0 end
    local target = 0
    for tool, st in pairs(JD7810Transmission.tools) do
        if st.active then
            local ok, low = pcall(tool.getIsLowered, tool, true)
            if (not ok) or low ~= false then target = math.max(target, st.ratedEngine or 0) end
        end
    end
    if target <= 0 or not JD.cfg.ptoAutoLoad then
        motor.jd7810AutoF, motor.jd7810AutoBump = nil, nil
        return target
    end
    -- v179 LOAD-BASED (ODSTUPANJE, praksa "gear up - throttle back"): lagan alat = nizi okretaji.
    -- Udio snage motora koji alat trazi: <= autoLoadLow -> autoMinPct nazivnih, >= autoLoadHigh -> nazivni, linearno izmedju.
    -- Zastita: motor iznad 92 % opterecenja (vuca + PTO) -> okretaji rastu dok ne padne. Nikad ispod autoMinPct
    -- (iznad praga zacepljenja clogPct); nizi PTO znaci i sporiji alat / nizu dopustenu radnu brzinu (vec u modelu).
    local cfg = JD.cfg
    local now = g_time or 0
    local dt = math.min(math.max(now - (motor.jd7810AutoFT or now), 0), 200) / 1000
    motor.jd7810AutoFT = now
    local _, kwLow = JD7810Transmission.ptoPower(motor)
    local peak = math.max(motor.peakMotorPower or 0, 1)
    local frac = kwLow / peak
    local lo, hi = cfg.ptoAutoLoadLow or 0.30, math.max(cfg.ptoAutoLoadHigh or 0.70, (cfg.ptoAutoLoadLow or 0.30) + 0.05)
    local minP = math.max(cfg.ptoAutoMinPct or 0.85, (cfg.clogPct or 0.6) + 0.1)
    local f = minP + (1 - minP) * math.min(math.max((frac - lo) / (hi - lo), 0), 1)
    local okE, eload = pcall(motor.getSmoothLoadPercentage, motor)
    eload = okE and type(eload) == "number" and eload or 0
    local bump = motor.jd7810AutoBump or 0
    if eload > 0.92 then bump = math.min(bump + 0.10 * dt, 1 - minP) else bump = math.max(bump - 0.03 * dt, 0) end
    motor.jd7810AutoBump = bump
    f = math.min(f + bump, 1)
    local fs = motor.jd7810AutoF or f                        -- 2 s filtar: bez lova okretaja kad se mijenja masa usjeva
    fs = fs + (f - fs) * math.min(1, dt / 2)
    motor.jd7810AutoF = fs
    return target * fs
end

-- v179: AQ/PS PTO automatik drzi okretaje oko cilja; u Load-based cilj je nizi od nazivnog
local function autoLoadTarget(motor)
    if JD.cfg.ptoAutoLoad and motor.jd7810AutoRpmOn and (motor.jd7810HandRpm or 0) <= 0 then return motor.jd7810AutoTgt or 0 end
    return 0
end
local function hookPtoTarget()
    if JD7810Transmission.jd7810AutoHooked or JD7810Transmission.ptoTargetRpm == nil or JD7810Transmission.ptoPredict == nil then return end
    JD7810Transmission.jd7810AutoHooked = true
    local origT, origP = JD7810Transmission.ptoTargetRpm, JD7810Transmission.ptoPredict
    JD7810Transmission.ptoTargetRpm = function(motor)
        local a = autoLoadTarget(motor)
        if a > 0 then return a end
        return origT(motor)
    end
    JD7810Transmission.ptoPredict = function(motor, curGear, gears, acceleratorPedal)
        local a = autoLoadTarget(motor)
        if a <= 0 then return origP(motor, curGear, gears, acceleratorPedal) end
        motor.jd7810HandRpm = a                         -- ptoPredict uzima rucni gas kao cilj; vraca se odmah
        local ok, g = pcall(origP, motor, curGear, gears, acceleratorPedal)
        motor.jd7810HandRpm = 0
        if not ok then return nil end
        return g
    end
end

VehicleMotor.getRequiredMotorRpmRange = Utils.overwrittenFunction(VehicleMotor.getRequiredMotorRpmRange, function(self, superFunc)
    local minRpm, maxRpm = superFunc(self)
    if ptoIsManual(self) then
        minRpm = self.minRpm
    end
    local hand = self.jd7810HandRpm or 0
    if self.jd7810Creep and hand <= 0 and isOurs(self) then
        maxRpm = math.max(minRpm, (self.minRpm or 850) + 30)   -- puzanje: regulator na praznom hodu
    end
    if hand > 0 and isOurs(self) then
        hand = math.min(hand, self.maxRpm)
        if getSpeedKmh(self) < 1.5 and not self.jd7810HandDrive then
            minRpm = math.max(minRpm, hand)          -- stoji: motor na zadanim okretajima
        end
        if not self.jd7810FootThrottle then
            maxRpm = math.max(hand, minRpm)          -- regulator: ne ide iznad rucnog gasa
        end
    end
    -- v178: auto PTO okretaji - glatko gore na nazivne kad je alat spusten, glatko dolje kad se digne
    if ptoIsManual(self) and hand <= 0 and JD7810Transmission.ptoAutoTarget ~= nil then
        hookPtoTarget()
        local tgt = JD7810Transmission.ptoAutoTarget(self)
        self.jd7810AutoTgt = math.min(tgt, self.maxRpm)
        local now = g_time or 0
        local dt = math.min(math.max(now - (self.jd7810AutoRpmT or now), 0), 200) / 1000
        self.jd7810AutoRpmT = now
        local idle = self.minRpm or 850
        local cur = self.jd7810AutoRpm or idle
        if tgt > 0 then
            tgt = math.min(tgt, self.maxRpm)
            cur = math.min(cur + (JD.cfg.ptoAutoRpmUp or 700) * dt, tgt)
            if cur < idle then cur = idle end
        else
            cur = math.max(cur - (JD.cfg.ptoAutoRpmDown or 900) * dt, idle)
        end
        self.jd7810AutoRpm = cur
        self.jd7810AutoRpmOn = tgt > 0
        if cur > idle + 1 then
            minRpm = math.max(minRpm, cur)
            maxRpm = math.max(maxRpm, minRpm)
        end
    else
        self.jd7810AutoRpm, self.jd7810AutoRpmOn = nil, false
    end
    if JD7810Transmission.ivtRange ~= nil and isOurs(self) then
        minRpm, maxRpm = JD7810Transmission.ivtRange(self, minRpm, maxRpm)
    end
    -- AutoQuad II / Powershift Field Cruise: regulator drzi stalne okretaje (gornja granica = zadani okretaji)
    local fc = self.jd7810FieldCruise or 0
    if fc > 0 and isOurs(self) and not JD7810Transmission.isIVT(self) and not isAIActive(self.vehicle) then
        maxRpm = math.max(math.min(maxRpm, fc), minRpm)
    end
    return minRpm, maxRpm
end)

-- voznja: nakon prvog gasa traktor vozi dalje i bez pritisnutog gasa
if WheelsUtil ~= nil and WheelsUtil.updateWheelsPhysics ~= nil then
    WheelsUtil.updateWheelsPhysics = Utils.overwrittenFunction(WheelsUtil.updateWheelsPhysics,
        function(self, superFunc, dt, currentSpeed, acceleration, doHandbrake, stopAndGoBraking)
            local motor = self.spec_motorized ~= nil and self.spec_motorized.motor or nil
            local accIn = acceleration or 0                 -- stvarni ulaz igraca (prije puzanja)
            if motor ~= nil and isOurs(motor) then
                -- kocnica igraca (za MFWD AUTO / BRAKE ASSIST i blokadu diferencijala)
                local umd = self.getIsManualDirectionChangeActive ~= nil and self:getIsManualDirectionChangeActive()
                local rev = self.spec_drivable ~= nil and self.spec_drivable.reverserDirection or 1
                local sgn = umd and 1 or (motor.currentDirection or 1) * rev
                motor.jd7810Braking = (acceleration or 0) * sgn < -0.05 and math.abs(currentSpeed or 0) > 0.0002
            end
            -- stisnuta spojka (ili N): igra bez gasa automatski koci (lowBrakeForceScale) - pravi traktor se s
            -- iskljucenom spojkom slobodno kotrlja; zato dok je spojka stisnuta tog kocenja nema (stajanje i dalje drzi)
            if motor ~= nil and isOurs(motor) and motor.lowBrakeForceScale ~= nil then
                if motor.jd7810LowBrakeBase == nil then motor.jd7810LowBrakeBase = motor.lowBrakeForceScale end
                local clutch = 0
                if motor.getManualClutchPedal ~= nil then
                    local okC, c = pcall(motor.getManualClutchPedal, motor); if okC and type(c) == "number" then clutch = c end
                end
                local ivt = JD7810Transmission.isIVT ~= nil and JD7810Transmission.isIVT(motor)
                -- AQ/PS u voznji bez gasa: koci samo motor (kocenje motorom) i kocnica kad je TI pritisnes - bez automatske kocnice igre
                local coasting = not ivt and JD7810Transmission.isStepBox ~= nil and JD7810Transmission.isStepBox(motor)
                    and math.abs(currentSpeed or 0) > 0.0003 and not isAIActive(self)
                local free = (clutch > 0.9 or coasting) and not doHandbrake and not ivt
                motor.lowBrakeForceScale = free and 0 or motor.jd7810LowBrakeBase

                -- PUZANJE: rucno sa spojkom, ukljucena brzina, pustena spojka, bez gasa i kocnice -> regulator drzi prazni hod
                -- (ili rucni gas) i traktor krene/vozi sam, kao pravi (solo u niskom rasponu)
                motor.jd7810Creep = false
                if not ivt and motor.gearShiftMode == VehicleMotor.SHIFT_MODE_MANUAL_CLUTCH and JD7810Transmission.isStepBox ~= nil
                   and JD7810Transmission.isStepBox(motor) and (motor.gear or 0) ~= 0 and clutch < 0.95 and not doHandbrake
                   and math.abs(acceleration or 0) < 0.001 and not isAIActive(self)
                   and self.getIsMotorStarted ~= nil and self:getIsMotorStarted() then
                    local cruiseOff = true
                    if self.getCruiseControlState ~= nil and Drivable ~= nil and Drivable.CRUISECONTROL_STATE_OFF ~= nil then
                        cruiseOff = self:getCruiseControlState() == Drivable.CRUISECONTROL_STATE_OFF
                    end
                    if cruiseOff then
                        local useManualDirection = self.getIsManualDirectionChangeActive ~= nil and self:getIsManualDirectionChangeActive()
                        local reverser = self.spec_drivable ~= nil and self.spec_drivable.reverserDirection or 1
                        acceleration = useManualDirection and 1 or (motor.currentDirection or 1) * reverser
                        motor.jd7810Creep = true
                    end
                end
            end
            if motor ~= nil and (motor.jd7810HandRpm or 0) > 0 and isOurs(motor) then
                local useManualDirection = self.getIsManualDirectionChangeActive ~= nil and self:getIsManualDirectionChangeActive()
                local reverser = self.spec_drivable ~= nil and self.spec_drivable.reverserDirection or 1
                local throttleSign = useManualDirection and 1 or (motor.currentDirection or 1) * reverser
                local input = accIn * throttleSign             -- puzanje (regulator) nije nozni gas

                local cruiseOff = true
                if self.getCruiseControlState ~= nil and Drivable ~= nil and Drivable.CRUISECONTROL_STATE_OFF ~= nil then
                    cruiseOff = self:getCruiseControlState() == Drivable.CRUISECONTROL_STATE_OFF
                end

                if not cruiseOff then
                    -- tempomat (radna voznja) vozi, rucni gas drzi okretaje
                    motor.jd7810FootThrottle = false
                    motor.jd7810HandDrive = false
                elseif JD7810Transmission.cfg.handLatch then
                    motor.jd7810FootThrottle = input > 0.05
                    if input > 0.05 then
                        motor.jd7810HandDrive = true                          -- dodao gas: vozi
                    elseif input < -0.05 and math.abs(currentSpeed or 0) < 0.0003 then
                        motor.jd7810HandDrive = false                         -- zakocio do stop
                    end
                    if motor.jd7810HandDrive and not doHandbrake and math.abs(acceleration or 0) < 0.001 then
                        acceleration = throttleSign   -- puni "gas", okretaje drzi regulator rucnog gasa
                    end
                else
                    -- papucica = voznja, rucni gas = okretaje motora
                    motor.jd7810FootThrottle = false
                    motor.jd7810HandDrive = false
                end
            end
            return superFunc(self, dt, currentSpeed, acceleration, doHandbrake, stopAndGoBraking)
        end)
end



-- =====================================================================
--  F) MFWD (AUTO / ON / BRAKE ASSIST) i blokada diferencijala - OMAR206904:
--     "Using Mechanical Front-Wheel Drive": ON = ukljucen; AUTO = ukljucen, iskljuci se kocnicom ili
--     iznad 19 km/h, ukljuci se ispod 18 km/h, ukljuci se kad se koci iznad 19 km/h; BRAKE ASSIST =
--     iskljucen osim kocenja iznad 19 km/h. "Using Differential Lock": prekidac ukljucuje, kocnica iskljucuje.
--     Igra: diferencijali iz XML-a (Motorized:addToPhysics -> addDifferential redom); u voznji ih postavljamo
--     istim putem (removeAllDifferentials + addDifferential). Kocnica po kotacu: WheelPhysics.brakeFactor.
--     Isklj. MFWD: sav moment straga, prednji kotaci slobodni i ne koce (prave kocnice su samo straga).
-- =====================================================================
JD7810Transmission.MFWD_NAMES = { [0] = "AUTO", [1] = "ON", [2] = "BRAKE ASSIST" }

local function diffSetup(motor)
    if motor.jd7810Diff ~= nil then return motor.jd7810Diff end
    local v = motor.vehicle
    local spec = v ~= nil and v.spec_motorized or nil
    if spec == nil or spec.motorizedNode == nil or spec.differentials == nil or updateDifferential == nil then return nil end
    local list, wheelDiffs, center = {}, {}, nil
    for i, d in ipairs(spec.differentials) do
        list[i] = d
        if d.diffIndex1IsWheel and d.diffIndex2IsWheel then table.insert(wheelDiffs, i) elseif not d.diffIndex1IsWheel and not d.diffIndex2IsWheel then center = i end
    end
    if center == nil or #wheelDiffs < 2 then return nil end
    local D = { node = spec.motorizedNode, list = list, center = center, front = wheelDiffs[1], rear = wheelDiffs[2], frontWheels = {} }
    local fd = list[D.front]
    for _, wi in ipairs({ fd.diffIndex1, fd.diffIndex2 }) do
        local ok, w = pcall(v.getWheelFromWheelIndex, v, wi)
        if ok and w ~= nil and w.physics ~= nil then
            w.physics.jd7810BrakeOrig = w.physics.jd7810BrakeOrig or w.physics.brakeFactor or 1
            table.insert(D.frontWheels, w.physics)
        end
    end
    motor.jd7810Diff = D
    JD.U.log(string.format("MFWD: diferencijali %d (prednji %d, straznji %d, sredina %d), prednjih kotaca %d; sredina XML %.2f / %.2f; motorizedNode %s rootNode %s",
        #list, D.front, D.rear, D.center, #D.frontWheels, list[center].torqueRatio or -1, list[center].maxSpeedRatio or -1,
        tostring(spec.motorizedNode), tostring(v.rootNode)))
    for i, d in ipairs(list) do
        local s = string.format("MFWD: dif %d: %s%s / %s%s, omjer %.3f, maxSpeedRatio %.3f", i, tostring(d.diffIndex1), d.diffIndex1IsWheel and "(kotac)" or "(dif)",
            tostring(d.diffIndex2), d.diffIndex2IsWheel and "(kotac)" or "(dif)", d.torqueRatio or -1, d.maxSpeedRatio or -1)
        for _, k in ipairs({ { d.diffIndex1, d.diffIndex1IsWheel }, { d.diffIndex2, d.diffIndex2IsWheel } }) do
            if k[2] then
                local okW, w = pcall(v.getWheelFromWheelIndex, v, k[1])
                if okW and w ~= nil and w.physics ~= nil then
                    s = s .. string.format(" | kotac %d: node %s (%s), wheelShape %s, r %.3f", k[1], tostring(w.node),
                        w.node == v.rootNode and "glavna komponenta" or "DRUGA komponenta", tostring(w.physics.wheelShape), w.physics.radius or -1)
                end
            end
        end
        JD.U.log(s)
    end
    return D
end

-- v118b (test 05.10.): removeAllDifferentials + addDifferential je RUSIO diferencijale - straznji kotaci su se
-- vrtjeli 0,40 / 1,88 m/s (omjer 4,7, XML dopusta 1,55), prednji 65-75 % proklizavanja. Prednja osovina je na
-- DRUGOJ komponenti, pa ponovno dodani kotacni diferencijal (wheelShape) ne odgovara. Sada samo mijenjamo
-- postojece diferencijale kao FS25_EnhancedVehicle: updateDifferential(rootNode, redni broj od 0, omjer, maxSpeedRatio);
-- maxSpeedRatio 1 = zakljucano, velik = otvoreno; 2WD = omjer -0.00001 (sav moment na drugi izlaz = straga).
-- Drugi test (v118b): ni "zakljucano" (bias 1) ne drzi - fizika (PhysX) diferencijal s ogranicenim proklizavanjem
-- samo preraspodjeljuje moment. Pravi uzrok: sredina dijeli MOMENT 50/50, a prednji kotac je manji (0,753 vs 0,994 m),
-- pa isti moment daje 32 % vecu vucnu silu na prednjem kotacu uz manji teret -> prednji prvi gube prianjanje.
-- Pravi MFWD: prednja osovina ima prijenos takav da obodne brzine budu jednake (+1-4 % vodenja), a sila se dijeli
-- prema teretu osovine. Zato: udio momenta naprijed = Tf*rf / (Tf*rf + Tr*rr), bias = rr/rf * (1 + vodenje).
local MFWD_LOAD_FRONT, MFWD_LEAD = 0.45, 0.0             -- staticki teret naprijed (TEST: 42-48 %); vodenje 0 (bias 1,02 je u testu dao 8 % - fizika popusta)
local function mfwdOnVals(D, motor)
    if D.onVals ~= nil then return D.onVals end
    local v = motor.vehicle
    local function avgR(di)
        local d, sum, n = D.list[di], 0, 0
        for _, wi in ipairs({ d.diffIndex1, d.diffIndex2 }) do
            local ok, w = pcall(v.getWheelFromWheelIndex, v, wi)
            if ok and w ~= nil and w.physics ~= nil and (w.physics.radius or 0) > 0 then sum = sum + w.physics.radius; n = n + 1 end
        end
        return n > 0 and sum / n or nil
    end
    local rf, rr = avgR(D.front), avgR(D.rear)
    if rf == nil or rr == nil then D.onVals = { D.list[D.center].torqueRatio or 0.5, D.list[D.center].maxSpeedRatio or 1.25 }; return D.onVals end
    local lf, lr = MFWD_LOAD_FRONT * rf, (1 - MFWD_LOAD_FRONT) * rr
    D.onVals = { lf / (lf + lr), math.max(1, rr / rf) * (1 + MFWD_LEAD) }
    D.rf, D.rr = rf, rr
    JD.U.log(string.format("MFWD: prednji r %.3f, straznji r %.3f -> udio momenta naprijed %.3f, bias %.3f", rf, rr, D.onVals[1], D.onVals[2]))
    return D.onVals
end
-- v165 (test 08.10.): pod plugom teret naprijed pada na 28-32 % (prijenos tezine), a udio momenta je ostao 0,38
-- (staticki 45 %) -> prednji kotaci 15-40 % proklizavanja, straga 3-25 %, obod naprijed ~10 % brzi.
-- Pravi MFWD je krut spoj pa se sila sama dijeli po prianjanju; PhysX diferencijal nije krut (v118b) -> udio
-- momenta prati STVARNI teret osovina (izgladeno ~3 s, korak 0,02, granice 0,20-0,50).
local MFWD_DYN_MIN, MFWD_DYN_MAX, MFWD_DYN_STEP = 0.20, 0.50, 0.02
local function mfwdDynVals(D, motor)
    local base = mfwdOnVals(D, motor)
    local f = motor.jd7810AxleFrac
    if not JD.cfg.mfwdDynamic or f == nil or D.rf == nil or D.rr == nil then return base end
    f = math.max(MFWD_DYN_MIN, math.min(MFWD_DYN_MAX, f))
    local tf, tr = f * D.rf, (1 - f) * D.rr
    local raw = tf / (tf + tr)
    -- histereza: novi korak tek kad se stvarni udio pomakne > 0,03 od postavljenog (bez treperenja 0,20 <-> 0,22)
    local cur = motor.jd7810DynRatio
    if cur == nil or math.abs(raw - cur) > 0.03 then
        cur = math.floor(raw / MFWD_DYN_STEP + 0.5) * MFWD_DYN_STEP
        motor.jd7810DynRatio = cur
    end
    return { cur, base[2] }
end
local MFWD_OFF_TORQUE, MFWD_OFF_SPEED = -0.00001, 1.0      -- iskljucen: kao EnhancedVehicle 2WD
local function setDiffs(motor, D, vals)
    local v = motor.vehicle
    if updateDifferential == nil then return false end
    local node = v.rootNode or D.node
    for i, val in ipairs(vals) do
        local ok = pcall(updateDifferential, node, i - 1, val[1], val[2])
        if not ok then return false end
    end
    if v.updateMotorProperties ~= nil then pcall(v.updateMotorProperties, v) end
    return true
end

local function applyDrive(motor, mfwdOn, lock, force)
    local D = diffSetup(motor)
    if D == nil then return end
    local onVals = mfwdOn and mfwdDynVals(D, motor) or nil
    local key = (mfwdOn and "M" or "m") .. (lock and "L" or "l") .. (onVals ~= nil and string.format("%.2f", onVals[1]) or "")
    if not force and motor.jd7810DriveKey == key then return end
    motor.jd7810DriveKey = key
    local vals = {}
    for i, d in ipairs(D.list) do vals[i] = { d.torqueRatio or 0.5, d.maxSpeedRatio or 1.5 } end
    vals[D.center] = onVals or { MFWD_OFF_TORQUE, MFWD_OFF_SPEED }
    if lock then vals[D.rear] = { vals[D.rear][1], 1.0 } end
    local ok, err = pcall(setDiffs, motor, D, vals)
    for _, ph in ipairs(D.frontWheels) do
        ph.brakeFactor = mfwdOn and (ph.jd7810BrakeOrig or 1) or 0
    end
    if (not ok or err == false) and not motor.jd7810DiffErr then motor.jd7810DiffErr = true; JD.U.log("MFWD: postavljanje diferencijala greska " .. tostring(err)) end
    -- v165: promjenu samo udjela (dinamicki MFWD) pisi najvise svakih 10 s; promjenu MFWD/blokade uvijek
    local mode = key:sub(1, 2)
    local now = g_time or 0
    if JD.cfg.debug or mode ~= motor.jd7810DriveLogMode or now - (motor.jd7810DriveLogT or -100000) > 10000 then
        motor.jd7810DriveLogMode, motor.jd7810DriveLogT = mode, now
        JD.U.log(string.format("MFWD: %s - updateDifferential sredina %.5f / %.2f, straga %.2f %s", key, vals[D.center][1], vals[D.center][2], vals[D.rear][2], (ok and err ~= false) and "OK" or "GRESKA"))
    end
end

local function restoreDrive(motor)
    local D = diffSetup(motor)
    if D == nil or motor.jd7810DriveKey == "orig" then return end
    motor.jd7810DriveKey = "orig"
    local vals = {}
    for i, d in ipairs(D.list) do vals[i] = { d.torqueRatio or 0.5, d.maxSpeedRatio or 1.5 } end
    pcall(setDiffs, motor, D, vals)
    for _, ph in ipairs(D.frontWheels) do ph.brakeFactor = ph.jd7810BrakeOrig or 1 end
end

local function updateDrive(motor, dt)
    local v = motor.vehicle
    if v == nil or not v.isServer then return end
    if not v.isAddedToPhysics then motor.jd7810DriveKey = nil; return end    -- ponovno dodavanje u fiziku vraca XML diferencijale
    if motor.jd7810DriveTest ~= nil then return end                          -- jd7810Pogon: rucni test pogona
    -- TEST usporedbe (postavka driveTest = 1): 6 faza po 6 s dok traktor vozi, svaka zapisana u log
    if (JD.cfg.driveTest or 0) >= 1 then
        local kmhT = math.abs(v.lastSpeedReal or 0) * 3600
        if kmhT > 0.3 or motor.jd7810TestPhase ~= nil then
            motor.jd7810TestT = (motor.jd7810TestT or 0) + dt
            local ph = math.floor(motor.jd7810TestT / 6000) % 6 + 1
            if ph ~= motor.jd7810TestPhase then
                motor.jd7810TestPhase = ph
                JD.testPhase = ph
                local names = { "1 nas MFWD (nasa vuca + kotrljanje)", "2 2WD (omjer naprijed -0.00001)", "3 SAMO PREDNJI (omjer 1, bias 1) - dijagnoza",
                                "4 nas MFWD, vuca IGRE, kotrljanje", "5 nas MFWD, nasa vuca, BEZ kotrljanja", "6 XML diferencijali (nasa vuca + kotrljanje)" }
                JD.U.log("TEST faza " .. names[ph])
                motor.jd7810DriveKey = nil
            end
            local p = motor.jd7810TestPhase
            if p == 6 then restoreDrive(motor)
            elseif p == 2 then applyDrive(motor, false, false, false)
            elseif p == 3 then
                local D = diffSetup(motor)
                if D ~= nil and motor.jd7810DriveKey ~= "fwd" then
                    motor.jd7810DriveKey = "fwd"
                    local vals = {}
                    for i, d in ipairs(D.list) do vals[i] = { d.torqueRatio or 0.5, d.maxSpeedRatio or 1.5 } end
                    vals[D.center] = { 1, 1 }
                    local ok = setDiffs(motor, D, vals)
                    JD.U.log("MFWD: fwd - updateDifferential sredina 1 / 1 " .. tostring(ok))
                end
            else applyDrive(motor, true, false, false) end
            return
        end
    end
    if isAIActive(v) then restoreDrive(motor); return end
    -- v168: FS25_EnhancedVehicle (EV) mijenja iste diferencijale (updateDifferential 0/1/2). Za 7810 pogon vodi
    -- ovaj mod; EV prekidaci rade U TANDEMU: EV pogon 4WD -> nas MFWD ON, 2WD -> BRAKE ASSIST; EV straznja blokada
    -- -> nasa blokada diferencijala. EV prednja blokada se ignorira (7810 je nema). Ako EV ipak primijeni svoje
    -- (vData.is promijenjen), nas pogon se postavi ponovo.
    local ev = v.vData
    if ev ~= nil and type(ev.want) == "table" and type(ev.is) == "table" then
        -- zeljeno stanje EV-a: want (jos neprimijenjeno) ili is (EV je vec primijenio u ovom frameu - redoslijed nije poznat)
        local w2 = (ev.want[2] ~= ev.is[2]) and ev.want[2] or ev.is[2]
        local w3 = (ev.want[3] ~= ev.is[3]) and ev.want[3] or ev.is[3]
        local prev = motor.jd7810EvPrev
        if prev ~= nil then                             -- prvi frame (ucitavanje) samo zapamti
            if w3 ~= prev[3] and (w3 == 0 or w3 == 1) then
                motor.jd7810MfwdMode = (w3 == 1) and 1 or 2
                motor.jd7810MfwdAuto = nil
                setEvent("MFWD switch: " .. JD7810Transmission.MFWD_NAMES[motor.jd7810MfwdMode] .. " (EnhancedVehicle)")
            end
            if w2 ~= prev[2] and w2 ~= nil then
                motor.jd7810DiffLock = w2 == true
                setEvent("Differential lock (rear): " .. (motor.jd7810DiffLock and "ENGAGED" or "released") .. " (EnhancedVehicle)")
            end
        end
        for i = 1, 3 do if ev.want[i] ~= ev.is[i] then ev.want[i] = ev.is[i] end end   -- EV vise ne mijenja nase diferencijale
        motor.jd7810EvPrev = { nil, ev.is[2], ev.is[3] }   -- stanje EV-a NAKON poravnanja (inace bi se idući frame vratilo)
        local sig = tostring(ev.is[1]) .. tostring(ev.is[2]) .. tostring(ev.is[3])
        if motor.jd7810EvSig ~= nil and motor.jd7810EvSig ~= sig then motor.jd7810DriveKey = nil end   -- EV je primijenio -> nase ponovo
        motor.jd7810EvSig = sig
        if not motor.jd7810EvLogged then
            motor.jd7810EvLogged = true
            JD.U.log("EnhancedVehicle: pogon i blokade 7810 vodi JD7810 (EV prekidaci preusmjereni)")
        end
    end
    local kmh = math.abs(v.lastSpeedReal or 0) * 3600
    local brake = motor.jd7810Braking == true
    local mode = motor.jd7810MfwdMode or 0
    local on
    if mode == 1 then
        on = true
    elseif mode == 2 then
        on = brake and kmh > 19
    else
        if brake then
            on = kmh > 19
        else
            local prev = motor.jd7810MfwdAuto
            if prev == nil then prev = kmh < 18 end
            if kmh > 19 then prev = false elseif kmh < 18 then prev = true end
            motor.jd7810MfwdAuto = prev
            on = prev
        end
    end
    if brake and motor.jd7810DiffLock then
        motor.jd7810DiffLock = false
        setEvent("Differential lock released (brake)")
    end
    -- bez treperenja oko 18/19 km/h: nova odluka mora trajati 0,4 s (osim prvog postavljanja)
    if motor.jd7810MfwdOn ~= nil and on ~= motor.jd7810MfwdOn then
        motor.jd7810MfwdHold = (motor.jd7810MfwdHold or 0) + dt
        if motor.jd7810MfwdHold < 400 then on = motor.jd7810MfwdOn end
    else
        motor.jd7810MfwdHold = 0
    end
    if on ~= motor.jd7810MfwdOn and motor.jd7810MfwdOn ~= nil and JD.cfg.debug then
        setEvent("MFWD " .. (on and "engaged" or "disengaged"))
    end
    motor.jd7810MfwdOn = on
    -- v165: udio tereta prednje osovine (JD.updateRolling: jd7810AxleF/R), izgladeno ~3 s; samo kad svi kotaci nose
    local lf, lr = motor.jd7810AxleF or 0, motor.jd7810AxleR or 0
    if lf > 0.3 and lr > 0.3 then
        local fr = lf / (lf + lr)
        motor.jd7810AxleFrac = (motor.jd7810AxleFrac or fr) + (fr - (motor.jd7810AxleFrac or fr)) * math.min(1, dt / 3000)
    end
    applyDrive(motor, on, motor.jd7810DiffLock == true, false)
end

VehicleMotor.update = Utils.appendedFunction(VehicleMotor.update, function(self, dt)
    if isOurs(self) then
        local ok, err = pcall(updateDrive, self, dt)
        if not ok and not self.jd7810DriveErr then self.jd7810DriveErr = true; JD.U.log("MFWD: greska " .. tostring(err)) end
    end
end)

-- TEST (jd7810Pogon): isti diferencijal sredine postavlja se na dva nacina da se u logu (TEST kotaci) vidi koji djeluje
--   ev4/ev2  = updateDifferential(rootNode, indeks od 0, ...) kao FS25_EnhancedVehicle (4WD = omjer, 1; 2WD = -0.00001, 1)
--   add4/add2 = removeAllDifferentials + addDifferential (kao Motorized:addToPhysics)
--   xml = vrati XML vrijednosti; auto = kraj testa (MFWD opet prema prekidacu)
function JD7810Transmission:consolePogon(mode)
    local v = g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil and g_localPlayer:getCurrentVehicle() or nil
    local motor = v ~= nil and v.spec_motorized ~= nil and v.spec_motorized.motor or nil
    if motor == nil or not isOurs(motor) then return "Udji u 7810" end
    local D = diffSetup(motor)
    if D == nil then return "Diferencijali nisu pronadeni" end
    mode = tostring(mode or "")
    local c = D.list[D.center]
    local vals = {}
    for i, d in ipairs(D.list) do vals[i] = { d.torqueRatio or 0.5, d.maxSpeedRatio or 1.5 } end
    local res
    if mode == "auto" then
        motor.jd7810DriveTest, motor.jd7810DriveKey = nil, nil
        return "Pogon: test zavrsen, MFWD opet prema prekidacu"
    elseif mode == "ev4" or mode == "ev2" then
        local tr, ms = (mode == "ev4") and (c.torqueRatio or 0.5) or -0.00001, 1
        local ok, err = pcall(updateDifferential, v.rootNode, D.center - 1, tr, ms)
        res = string.format("updateDifferential(rootNode, %d, %.5f, %.2f) %s", D.center - 1, tr, ms, ok and "OK" or ("GRESKA " .. tostring(err)))
    elseif mode == "add4" or mode == "add2" then
        vals[D.center] = (mode == "add4") and { c.torqueRatio or 0.5, 1 } or { -0.00001, 1 }
        local ok, err = pcall(setDiffs, motor, D, vals)
        res = string.format("removeAll + addDifferential, sredina %.5f / %.2f %s", vals[D.center][1], vals[D.center][2], (ok and err ~= false) and "OK" or ("GRESKA " .. tostring(err)))
    elseif mode == "xml" then
        local ok, err = pcall(setDiffs, motor, D, vals)
        res = "XML vrijednosti " .. ((ok and err ~= false) and "OK" or ("GRESKA " .. tostring(err)))
    else
        return "jd7810Pogon ev4 | ev2 | add4 | add2 | xml | auto"
    end
    motor.jd7810DriveTest = mode
    motor.jd7810DriveKey = "test " .. mode
    for _, ph in ipairs(D.frontWheels) do ph.brakeFactor = ph.jd7810BrakeOrig or 1 end
    JD.U.log("TEST pogon " .. mode .. ": " .. res)
    return "Pogon " .. mode .. ": " .. res
end
table.insert(JD7810Transmission.COMMANDS, { "jd7810Pogon", "JD7810: TEST pogona (ev4/ev2/add4/add2/xml/auto)", "consolePogon", "nacin" })

function JD7810Transmission.actionMfwd(vehicle, actionName, inputValue, callbackState, isAnalog)
    local motor = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil
    if motor == nil or not isOurs(motor) then return end
    motor.jd7810MfwdMode = ((motor.jd7810MfwdMode or 0) + 1) % 3
    motor.jd7810MfwdAuto = nil
    if JD7810Transmission.switchClick ~= nil then JD7810Transmission.switchClick(vehicle) end   -- v171
    setEvent("MFWD switch: " .. JD7810Transmission.MFWD_NAMES[motor.jd7810MfwdMode])
end

function JD7810Transmission.actionDiffLock(vehicle, actionName, inputValue, callbackState, isAnalog)
    local motor = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil
    if motor == nil or not isOurs(motor) then return end
    motor.jd7810DiffLock = not motor.jd7810DiffLock
    if JD7810Transmission.switchClick ~= nil then JD7810Transmission.switchClick(vehicle) end   -- v171
    setEvent("Differential lock (rear): " .. (motor.jd7810DiffLock and "ENGAGED" or "released"))
end

-- v131: GIANTS dodaje umjetno sinusno titranje okretajima (zvuk, kazaljka) i opterecenju (getLastModulatedMotorRpm /
-- getSmoothLoadPercentage, lastModulationPercentage). Pravi motor s regulatorom je miran -> za nas traktor iskljuceno
-- (jd7810Settings engine#rpmModulation="true" vraca original). Pad okretaja pri naglom porastu opterecenja ostaje.
local function withoutModulation(self, superFunc)
    local m = self.lastModulationPercentage
    self.lastModulationPercentage = 0
    local ok, r = pcall(superFunc, self)
    self.lastModulationPercentage = m
    if ok then return r end
    return superFunc(self)
end
if VehicleMotor.getLastModulatedMotorRpm ~= nil then
    VehicleMotor.getLastModulatedMotorRpm = Utils.overwrittenFunction(VehicleMotor.getLastModulatedMotorRpm, function(self, superFunc)
        if isOurs(self) and not JD7810Transmission.cfg.rpmModulation then return withoutModulation(self, superFunc) end
        return superFunc(self)
    end)
end
if VehicleMotor.getSmoothLoadPercentage ~= nil then
    VehicleMotor.getSmoothLoadPercentage = Utils.overwrittenFunction(VehicleMotor.getSmoothLoadPercentage, function(self, superFunc)
        if isOurs(self) and not JD7810Transmission.cfg.rpmModulation then return withoutModulation(self, superFunc) end
        return superFunc(self)
    end)
end


-- =====================================================================
--  v177: PARK (zapor mjenjaca u P - pravi 7810: polozaj P na rucici mjenjaca AQ/PS, IVT na lijevoj rucici)
--  Desni Alt (ili LAlt+6): ukljuci samo kad traktor stoji (< 1,5 km/h); drzi traktor (kocnica 1, gas 0), motor smije raditi.
--  Rucica mjenjaca odlazi u P. Iskljucuje tempomat. Zamjenjuje rucnu kocnicu EnhancedVehicle za 7810.
-- =====================================================================
function JD7810Transmission.actionPark(vehicle, actionName, inputValue, callbackState, isAnalog)
    local motor = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil
    if motor == nil or not isOurs(motor) then return end
    if not motor.jd7810Park then
        if getSpeedKmh(motor) > 1.5 then
            setEvent("Park lock: stop the tractor first")
            return
        end
        motor.jd7810Park = true
        if vehicle.setCruiseControlState ~= nil and Drivable ~= nil and Drivable.CRUISECONTROL_STATE_OFF ~= nil then
            pcall(vehicle.setCruiseControlState, vehicle, Drivable.CRUISECONTROL_STATE_OFF)
        end
        setEvent("Park lock ENGAGED (P)")
    else
        motor.jd7810Park = false
        setEvent("Park lock released")
    end
    if JD7810Transmission.switchClick ~= nil then JD7810Transmission.switchClick(vehicle) end
end
if Drivable ~= nil and Drivable.updateVehiclePhysics ~= nil then
    Drivable.updateVehiclePhysics = Utils.overwrittenFunction(Drivable.updateVehiclePhysics, function(self, superFunc, axisForward, axisSide, doHandbrake, dt)
        local m = self.spec_motorized
        local motor = m ~= nil and m.motor or nil
        if motor ~= nil and motor.jd7810Park and isOurs(motor) then
            if isAIActive(self) then
                motor.jd7810Park = false                       -- AI preuzima: park se otpusta
            else
                if math.abs(axisForward or 0) > 0.2 then
                    local now = g_time or 0
                    if now - (motor.jd7810ParkMsgT or 0) > 3000 then
                        motor.jd7810ParkMsgT = now
                        setEvent("Park lock engaged - Right Alt to release")
                    end
                end
                return superFunc(self, 0, axisSide, true, dt)
            end
        end
        return superFunc(self, axisForward, axisSide, doHandbrake, dt)
    end)
end

-- =====================================================================
--  v180: SVJETLA (Darijan 9.10.)
--   F       : pozicijska (0: male ispred retrovizora, straznja, tablica, ploca) -> kratka (0 4) -> duga (0 4 3) -> off
--   Ctrl+F  : natrag: duga -> kratka -> pozicijska -> off (na off ostaje)
--   Shift+F : radna: prednja -> straznja -> oba -> off
--  Radna svjetla potpuno odvojena: F ih ne pali i ne gasi. Na 7810 igrine akcije "svjetla unatrag"
--  (TOGGLE_LIGHTS_BACK) i "duga" (TOGGLE_HIGH_BEAM_LIGHT) ne rade nista - ako su na istim tipkama, ne smetaju.
--  ODSTUPANJE: pravi 7810 ima okretni prekidac svjetala, zasebne prekidace radnih svjetala i duga na rucici.
--  Nadjacavaju se callbackovi akcija (citaju se pri registraciji akcija u voznji), ne funkcije vozila.
-- =====================================================================
local LT_WORK_BACK, LT_WORK_FRONT = 1, 2
local function jdLights(vehicle)
    local m = vehicle ~= nil and vehicle.spec_motorized or nil
    return m ~= nil and m.motor ~= nil and isOurs(m.motor) and vehicle.spec_lights ~= nil
           and vehicle.spec_lights.lightStates ~= nil and #vehicle.spec_lights.lightStates > 0
end
local function roadMask(spec)
    if spec.jd7810RoadMask == nil then
        local m = 0
        for _, st in ipairs(spec.lightStates) do
            for _, lt in pairs(st) do m = bit32.bor(m, 2 ^ lt) end
        end
        m = bit32.band(m, bit32.bnot(2 ^ LT_WORK_BACK + 2 ^ LT_WORK_FRONT))   -- radna nikad nisu u F krugu
        spec.jd7810RoadMask = m
    end
    return spec.jd7810RoadMask
end
-- postavi cestovno stanje (0 = off, 1..n) i zadrzi radna svjetla
local function setRoadState(vehicle, idx)
    local spec = vehicle.spec_lights
    local n = #spec.lightStates
    idx = math.max(0, math.min(idx, n))
    local road = roadMask(spec)
    local mask = bit32.band(spec.lightsTypesMask, bit32.bnot(road))
    if idx > 0 then
        for _, lt in pairs(spec.lightStates[idx]) do
            if lt ~= LT_WORK_BACK and lt ~= LT_WORK_FRONT then mask = bit32.bor(mask, 2 ^ lt) end
        end
    end
    spec.currentLightState = idx
    vehicle:setLightsTypesMask(mask)
end
-- trenutno cestovno stanje iz maske (ako ga je promijenio netko drugi, npr. automatika)
local function roadState(vehicle)
    local spec = vehicle.spec_lights
    local road = bit32.band(spec.lightsTypesMask, roadMask(spec))
    if road == 0 then return 0 end
    for i = #spec.lightStates, 1, -1 do
        local m = 0
        for _, lt in pairs(spec.lightStates[i]) do
            if lt ~= LT_WORK_BACK and lt ~= LT_WORK_FRONT then m = bit32.bor(m, 2 ^ lt) end
        end
        if m == road then return i end
    end
    return spec.currentLightState or 0
end
if Lights ~= nil and Lights.actionEventToggleLights ~= nil then
    Lights.actionEventToggleLights = Utils.overwrittenFunction(Lights.actionEventToggleLights, function(self, superFunc, actionName, inputValue, callbackState, isAnalog)
        if not jdLights(self) then return superFunc(self, actionName, inputValue, callbackState, isAnalog) end
        if not self:getCanToggleLight() then return end
        local cur = roadState(self)
        local nxt = cur + 1
        if nxt > #self.spec_lights.lightStates then nxt = 0 end
        setRoadState(self, nxt)
    end)
end
if Lights ~= nil and Lights.actionEventToggleLightsBack ~= nil then
    Lights.actionEventToggleLightsBack = Utils.overwrittenFunction(Lights.actionEventToggleLightsBack, function(self, superFunc, ...)
        if jdLights(self) then return end                -- 7810: iskljuceno (Shift+F = radna svjetla)
        return superFunc(self, ...)
    end)
end
if Lights ~= nil and Lights.actionEventToggleHighBeamLight ~= nil then
    Lights.actionEventToggleHighBeamLight = Utils.overwrittenFunction(Lights.actionEventToggleHighBeamLight, function(self, superFunc, ...)
        if jdLights(self) then return end                -- 7810: duga su treci F; Ctrl+F = natrag
        return superFunc(self, ...)
    end)
end
function JD7810Transmission.actionLightsDown(vehicle, actionName, inputValue, callbackState, isAnalog)
    if not jdLights(vehicle) or not vehicle:getCanToggleLight() then return end
    setRoadState(vehicle, roadState(vehicle) - 1)
end
function JD7810Transmission.actionWorkLights(vehicle, actionName, inputValue, callbackState, isAnalog)
    if not jdLights(vehicle) or not vehicle:getCanToggleLight() then return end
    local spec = vehicle.spec_lights
    local mask = spec.lightsTypesMask
    if spec.jd7810RevOn then                              -- v181: straznja upaljena samo zbog rikverca -> nije korisnikov izbor
        mask = bit32.band(mask, bit32.bnot(2 ^ LT_WORK_BACK))
        spec.jd7810RevOn = false
    end
    local f = bit32.band(mask, 2 ^ LT_WORK_FRONT) ~= 0
    local b = bit32.band(mask, 2 ^ LT_WORK_BACK) ~= 0
    -- off -> prednja -> straznja -> oba -> off
    local nf, nb
    if not f and not b then nf, nb = true, false
    elseif f and not b then nf, nb = false, true
    elseif b and not f then nf, nb = true, true
    else nf, nb = false, false end
    mask = bit32.band(mask, bit32.bnot(2 ^ LT_WORK_BACK + 2 ^ LT_WORK_FRONT))
    if nf then mask = bit32.bor(mask, 2 ^ LT_WORK_FRONT) end
    if nb then mask = bit32.bor(mask, 2 ^ LT_WORK_BACK) end
    vehicle:setLightsTypesMask(mask)
    if JD7810Transmission.switchClick ~= nil then JD7810Transmission.switchClick(vehicle) end
end
function JD7810Transmission.lightsText(vehicle)
    if not jdLights(vehicle) then return nil, nil end
    local spec = vehicle.spec_lights
    local names = { [0] = "off", "position", "low beam", "high beam" }
    local r = roadState(vehicle)
    local f = bit32.band(spec.lightsTypesMask, 2 ^ LT_WORK_FRONT) ~= 0
    local b = bit32.band(spec.lightsTypesMask, 2 ^ LT_WORK_BACK) ~= 0
    if spec.jd7810RevOn then b = false end              -- v181
    local w = (f and b) and "front + rear" or (f and "front" or (b and "rear" or "off"))
    if spec.jd7810RevOn then w = w .. " + reverse" end
    return names[r] or tostring(r), w
end

-- =====================================================================
--  v181: RIKVERC SVJETLA (Darijan 9.10.): dok je ukljucen rikverc (smjer natrag, stupanj ukljucen) ili
--  traktor vozi unatrag > 1 km/h, a motor radi, sama se pale STRAZNJA RADNA svjetla - i bez ostalih svjetala.
--  Izlaskom iz rikverca se gase, osim ako ih je vozac upalio sam (Shift+F). Provjera 10x u sekundi.
--  ODSTUPANJE: pravi 7810 nema zasebna svjetla za voznju unatrag (nismo nasli podatak) - koriste se radna straga.
-- =====================================================================
local function updateReverseLights(motor)
    local v = motor.vehicle
    -- v185: bez zvucnog signala za voznju unatrag (Darijan) - uzorak reverseDrive iz zvukova motora se gasi
    local ms = v ~= nil and v.spec_motorized or nil
    if ms ~= nil and ms.samples ~= nil and ms.samples.reverseDrive ~= nil and g_soundManager ~= nil then
        pcall(g_soundManager.stopSample, g_soundManager, ms.samples.reverseDrive)
        ms.samples.reverseDrive = nil
    end
    if not jdLights(v) or not v.isServer then return end
    local spec = v.spec_lights
    local started = v.getIsMotorStarted == nil or v:getIsMotorStarted()
    local rev = false
    if started then
        -- v185: odabran rikverc = smjer natrag (i u N / sa stisnutom spojkom), ili voznja unatrag > 1 km/h
        local dirRev = (motor.currentDirection or 1) < 0
        local movingBack = (v.movingDirection or 0) < 0 and getSpeedKmh(motor) > 1
        rev = dirRev or movingBack
        if v.spec_drivable ~= nil and (v.spec_drivable.reverserDirection or 1) ~= 1 then rev = false end   -- okrenuto sjedalo
    end
    motor.jd7810RevSel = rev
    if v.setReverseLightsVisibility ~= nil then v:setReverseLightsVisibility(rev) end
    local bit = 2 ^ LT_WORK_BACK
    local has = bit32.band(spec.lightsTypesMask, bit) ~= 0
    if rev and not has then
        spec.jd7810RevOn = true
        v:setLightsTypesMask(bit32.bor(spec.lightsTypesMask, bit))
    elseif not rev and spec.jd7810RevOn then
        spec.jd7810RevOn = false
        if has then v:setLightsTypesMask(bit32.band(spec.lightsTypesMask, bit32.bnot(bit))) end
    end
end
VehicleMotor.update = Utils.appendedFunction(VehicleMotor.update, function(self, dt)
    if not isOurs(self) then return end
    self.jd7810RevLT = (self.jd7810RevLT or 0) - dt
    if self.jd7810RevLT > 0 then return end
    self.jd7810RevLT = 100
    local ok, err = pcall(updateReverseLights, self)
    if not ok and not self.jd7810RevErr then self.jd7810RevErr = true; JD.U.log("rikverc svjetla: greska " .. tostring(err)) end
end)

-- =====================================================================
--  v183: POWERSHIFT 19/7 - tipke "brzina gore/dolje" (G920 lopatice, Num +/-) mijenjaju STUPNJEVE 1-19
--  (u igri su to grupe POWERSHIFT, bez spojke). PS ima samo jednu "brzinu" F/R, pa su te tipke prije
--  trazile spojku i nisu radile nista. Ostali mjenjaci nepromijenjeni.
-- =====================================================================
if Motorized ~= nil and Motorized.actionEventShiftGear ~= nil and MotorGearShiftEvent ~= nil then
    Motorized.actionEventShiftGear = Utils.overwrittenFunction(Motorized.actionEventShiftGear, function(self, superFunc, actionName, inputValue, callbackState, isAnalog)
        local m = self.spec_motorized
        local motor = m ~= nil and m.motor or nil
        if motor ~= nil and isOurs(motor) and JD7810Transmission.motorKind ~= nil and JD7810Transmission.motorKind(motor) == "PS" and motor.gearGroups ~= nil then
            if actionName == InputAction.SHIFT_GEAR_UP then
                MotorGearShiftEvent.sendToServer(self, MotorGearShiftEvent.TYPE_SHIFT_GROUP_UP)
            else
                MotorGearShiftEvent.sendToServer(self, MotorGearShiftEvent.TYPE_SHIFT_GROUP_DOWN)
            end
            return
        end
        return superFunc(self, actionName, inputValue, callbackState, isAnalog)
    end)
end

-- =====================================================================
--  v184: PARK stvarno drzi. U nacinu igre "rucno sa spojkom" WheelsUtil za rucni mjenjac iskljucuje
--  automatsku kocnicu, pa doHandbrake iz Drivable nije kocio. Ovdje: dok je park ukljucen, gas 0 i
--  puna kocnica na kotacima traktora svaki frame (poslije izracuna igre). AI otpusta park (Drivable dio).
-- =====================================================================
if WheelsUtil ~= nil and WheelsUtil.updateWheelsPhysics ~= nil then
    WheelsUtil.updateWheelsPhysics = Utils.overwrittenFunction(WheelsUtil.updateWheelsPhysics,
        function(self, superFunc, dt, currentSpeed, acceleration, doHandbrake, stopAndGoBraking)
            local m = self.spec_motorized
            local motor = m ~= nil and m.motor or nil
            if motor ~= nil and motor.jd7810Park and isOurs(motor) and not isAIActive(self) then
                local r = superFunc(self, dt, currentSpeed, 0, true, stopAndGoBraking)
                if self.brake ~= nil then self:brake(1) end
                if math.abs(acceleration or 0) > 0.2 then
                    local now = g_time or 0
                    if now - (motor.jd7810ParkMsgT or 0) > 3000 then
                        motor.jd7810ParkMsgT = now
                        setEvent("Park lock engaged - Right Alt to release")
                    end
                end
                return r
            end
            return superFunc(self, dt, currentSpeed, acceleration, doHandbrake, stopAndGoBraking)
        end)
end

-- v185: igra pali reverse svjetla samo dok je gas natrag (Lights:onVehiclePhysicsUpdate) -> za 7810 prema odabiru rikverca
if Lights ~= nil and Lights.onVehiclePhysicsUpdate ~= nil then
    Lights.onVehiclePhysicsUpdate = Utils.overwrittenFunction(Lights.onVehiclePhysicsUpdate, function(self, superFunc, acceleratorPedal, brakePedal, automaticBrake, currentSpeed)
        superFunc(self, acceleratorPedal, brakePedal, automaticBrake, currentSpeed)
        local m = self.spec_motorized
        local motor = m ~= nil and m.motor or nil
        if motor ~= nil and motor.jd7810RevSel ~= nil and isOurs(motor) and self.setReverseLightsVisibility ~= nil then
            self:setReverseLightsVisibility(motor.jd7810RevSel)
        end
    end)
end
