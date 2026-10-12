-- =====================================================================
--  JD7810PTO.lua   v8.1  (FS25 - osobna upotreba, Darijan)
--  PTO: brzina i zacepljenje alata, zvuk i vrtnja alata, PTO automatik, ogranicenje brzine
--  v8.1: podjela JD7810Transmission.lua v8.0 na module - kod premjesten
--        bez promjene ponasanja. Redoslijed ucitavanja u modDesc.xml:
--        Core, Transmission, Engine, PTO, Display, PerformanceMonitor, AgroGsm, Cockpit
-- =====================================================================

local JD = JD7810Transmission
local isAIActive = JD.U.isAIActive
local isOurs = JD.U.isOurs
local log = JD.U.log
local setEvent = JD.U.setEvent

-- =====================================================================
--  H) PTO SUSTAV: brzina alata, radna brzina, zacepljenje, zvuk, vrtnja
--     Radi s bilo kojim alatom koji ima PTO (ptoRpm u XML-u alata).
-- =====================================================================
JD7810Transmission.tools = {}          -- alat -> stanje
JD7810Transmission.modifiedTools = {}  -- alati kojima smo mijenjali zvuk/vrtnju

-- nazivni okretaji motora za PTO izlaz koji alat koristi (540 ili 1000)
local function getRatedEngineRpm(ptoRpm)
    local cfg = JD7810Transmission.cfg
    if ptoRpm <= 700 then
        return cfg.pto540Rpm
    end
    return cfg.pto1000Rpm
end

local function isSampleTable(t)
    return type(t) == "table" and t.pitchScale ~= nil and (t.soundSample ~= nil or t.indoorAttributes ~= nil)
end

local function collectSamples(t, out, depth, seen)
    if type(t) ~= "table" or depth > 3 or seen[t] then
        return
    end
    seen[t] = true
    if isSampleTable(t) then
        table.insert(out, t)
        return
    end
    for _, v in pairs(t) do
        if type(v) == "table" then
            collectSamples(v, out, depth + 1, seen)
        end
    end
end

local function collectAnimNodes(t, out, depth, seen)
    if type(t) ~= "table" or depth > 2 or seen[t] then
        return
    end
    seen[t] = true
    for k, v in pairs(t) do
        if type(v) == "table" then
            if k == "animationNodes" then
                for _, node in pairs(v) do
                    if type(node) == "table" and type(node.rotSpeed) == "number" then
                        table.insert(out, node)
                    end
                end
            elseif depth < 2 then
                collectAnimNodes(v, out, depth + 1, seen)
            end
        end
    end
end

local function getToolParts(tool)
    if tool.jd7810Parts == nil then
        local parts = { samples = {}, nodes = {} }
        local seenS, seenN = {}, {}
        for k, spec in pairs(tool) do
            if type(k) == "string" and string.sub(k, 1, 5) == "spec_" and type(spec) == "table" then
                if spec.samples ~= nil then
                    collectSamples(spec.samples, parts.samples, 0, seenS)
                end
                collectAnimNodes(spec, parts.nodes, 0, seenN)
            end
        end
        tool.jd7810Parts = parts
        if JD7810Transmission.cfg.debug then
            local name = tool.getName ~= nil and tool:getName() or "?"
            log(string.format("alat '%s': %d zvukova, %d rotirajucih dijelova, %d animacija", name, #parts.samples, #parts.nodes,
                (tool.spec_turnOnVehicle ~= nil and tool.spec_turnOnVehicle.turnedOnAnimations ~= nil) and #tool.spec_turnOnVehicle.turnedOnAnimations or 0))
        end
    end
    return tool.jd7810Parts
end

-- factor: 1 = nazivna PTO brzina. nil = vrati original
local function applyToolFeel(tool, factor, soundOn, spinOn)
    local parts = getToolParts(tool)

    -- zvuk: koraci od 10%
    local q = factor ~= nil and soundOn and math.max(0.3, math.min(1.2, math.floor(factor * 10 + 0.5) / 10)) or nil
    if tool.jd7810SoundQ ~= q then
        tool.jd7810SoundQ = q
        for _, sample in ipairs(parts.samples) do
            if sample.jd7810BasePitch == nil then
                sample.jd7810BasePitch = sample.pitchScale or 1
                sample.jd7810BaseToolVolume = sample.volumeScale or 1
            end
            if q ~= nil then
                sample.pitchScale = sample.jd7810BasePitch * q
                sample.volumeScale = sample.jd7810BaseToolVolume * (0.6 + 0.4 * math.min(q, 1))
            else
                sample.pitchScale = sample.jd7810BasePitch
                sample.volumeScale = sample.jd7810BaseToolVolume
            end
        end
    end

    -- vrtnja dijelova
    local spin = factor ~= nil and spinOn and math.max(0.05, math.min(1.2, factor)) or nil
    local last = tool.jd7810Spin
    if spin == last or (spin ~= nil and last ~= nil and math.abs(spin - last) < 0.02) then
        return
    end
    tool.jd7810Spin = spin
    local f = spin or 1

    for _, node in ipairs(parts.nodes) do
        if node.jd7810BaseRotSpeed == nil then
            node.jd7810BaseRotSpeed = node.rotSpeed
        end
        node.rotSpeed = node.jd7810BaseRotSpeed * f
    end

    local ts = tool.spec_turnOnVehicle
    if ts ~= nil and ts.turnedOnAnimations ~= nil then
        for _, anim in ipairs(ts.turnedOnAnimations) do
            if anim.jd7810BaseSpeedScale == nil then
                anim.jd7810BaseSpeedScale = anim.speedScale or 1
            end
            anim.speedScale = anim.jd7810BaseSpeedScale * f
            if anim.speedDirection == 0 and (anim.currentSpeed or 0) > 0 and tool.setAnimationSpeed ~= nil then
                pcall(tool.setAnimationSpeed, tool, anim.name, anim.currentSpeed * anim.speedScale)
            end
        end
    end
end

local function restoreTool(tool)
    applyToolFeel(tool, nil, false, false)
    JD7810Transmission.tools[tool] = nil
    JD7810Transmission.modifiedTools[tool] = nil
end
JD7810Transmission.U.restoreTool = restoreTool


-- poziva se iz VehicleMotor.update za nas traktor
function JD7810Transmission.updateTools(motor, dt)
    local cfg = JD7810Transmission.cfg
    local vehicle = motor.vehicle
    local ai = isAIActive(vehicle)
    local rpm = JD.U.engineRpm(motor)
    local attached = {}
    local activeCount = 0

    local ok, children = pcall(vehicle.getChildVehicles, vehicle)
    if ok and type(children) == "table" then
        for _, tool in ipairs(children) do
            local pc = tool ~= vehicle and tool.spec_powerConsumer or nil
            if pc ~= nil and (pc.ptoRpm or 0) > 0 then
                attached[tool] = true
                local st = JD7810Transmission.tools[tool]
                if st == nil then
                    st = { clogTimer = 0 }
                    JD7810Transmission.tools[tool] = st
                end
                local okA, ptoNow = pcall(tool.getPtoRpm, tool)
                st.active = okA and (ptoNow or 0) > 0
                st.nominal = pc.ptoRpm
                st.ratedEngine = getRatedEngineRpm(pc.ptoRpm)
                st.factor = ai and 1 or (rpm / math.max(st.ratedEngine, 1))
                st.name = tool.getName ~= nil and tool:getName() or "alat"

                if st.active then
                    activeCount = activeCount + 1

                    -- zacepljenje: prespor PTO dok alat stvarno radi
                    local okL, load, count = pcall(tool.getConsumingLoad, tool)
                    local working = okL and (count or 0) > 0 and (load or 0) / math.max(count, 1) > 0.15
                    if cfg.clog and not ai and working and st.factor < cfg.clogPct then
                        st.clogTimer = st.clogTimer + dt
                        if st.clogTimer > cfg.clogTime and tool.setIsTurnedOn ~= nil then
                            st.clogTimer = 0
                            pcall(tool.setIsTurnedOn, tool, false)
                            st.clogged = g_time or 0
                            setEvent(string.format("%s: PTO too slow (%.0f%%) - implement clogged!", st.name, st.factor * 100))
                        end
                    else
                        st.clogTimer = math.max(st.clogTimer - dt * 2, 0)
                    end

                    -- zvuk i vrtnja
                    if not ai and (cfg.toolSound or cfg.toolSpin) then
                        applyToolFeel(tool, st.factor, cfg.toolSound, cfg.toolSpin)
                        JD7810Transmission.modifiedTools[tool] = true
                    elseif JD7810Transmission.modifiedTools[tool] then
                        applyToolFeel(tool, nil, false, false)
                        JD7810Transmission.modifiedTools[tool] = nil
                    end
                else
                    st.clogTimer = 0
                end
            end
        end
    end

    -- otkaceni alati: vrati im originalni zvuk i vrtnju
    for tool, _ in pairs(JD7810Transmission.tools) do
        if not attached[tool] then
            restoreTool(tool)
        end
    end

    motor.jd7810PtoActive = activeCount
end

-- sporiji PTO = manja dopustena radna brzina (za alate koji rade)
VehicleMotor.getSpeedLimit = Utils.overwrittenFunction(VehicleMotor.getSpeedLimit, function(self, superFunc)
    local limit = superFunc(self)
    local cfg = JD7810Transmission.cfg
    if cfg.ptoSpeedLimit and isOurs(self) and (self.jd7810PtoActive or 0) > 0 and not isAIActive(self.vehicle) then
        for tool, st in pairs(JD7810Transmission.tools) do
            if st.active and st.factor < 0.98 and type(tool.speedLimit) == "number" and tool.speedLimit < 100 then
                limit = math.min(limit, tool.speedLimit * math.max(st.factor, 0.2))
            end
        end
    end
    return limit
end)

-- ciljani okretaji motora dok radi PTO (rucni gas ili nazivni okretaji alata); 0 = PTO ne radi
function JD7810Transmission.ptoTargetRpm(motor)
    if (motor.jd7810PtoActive or 0) <= 0 then return 0 end
    local target = motor.jd7810HandRpm or 0
    if target > 0 then return target end
    for _, st in pairs(JD7810Transmission.tools) do
        if st.active then target = math.max(target, st.ratedEngine or 0) end
    end
    return target
end

-- PTO automatik: drzi okretaje oko ciljanih (rucni gas ili nazivni PTO) mijenjanjem 1-4
function JD7810Transmission.ptoPredict(self, curGear, gears, acceleratorPedal)
    if gears == nil or gears[curGear] == nil then
        return nil
    end
    local diffRpm = math.abs(self.differentialRotSpeed or 0) * 30 / math.pi
    if diffRpm < 0.01 then
        return nil
    end
    local group = self.activeGearGroupIndex
    local groupRatio = (self.gearGroups ~= nil and self.gearGroups[group] ~= nil) and self.gearGroups[group].ratio or 1
    local function rpmIn(g) return diffRpm * math.abs(gears[g].ratio * groupRatio) end

    local target = self.jd7810HandRpm or 0
    if target <= 0 then
        target = 0
        for _, st in pairs(JD7810Transmission.tools) do
            if st.active then
                target = math.max(target, st.ratedEngine or 0)
            end
        end
        if target <= 0 then
            return nil
        end
    end

    local rpm = rpmIn(curGear)
    local load = self:getSmoothLoadPercentage() or 0
    local now = g_time or 0
    local since = now - (self.jd7810LastShift or -100000)
    local sinceUp = now - (self.jd7810LastPtoUp or -100000)

    -- nize: motor pada pod teretom (odmah ako padne jako)
    if curGear > 1 and since > 400 then
        local lugging = rpm < target * 0.90 and load > 0.85
        local heavyDrop = rpm < target * 0.80
        if (lugging and sinceUp > 2500) or heavyDrop then
            if rpmIn(curGear - 1) <= self.maxRpm - 100 then
                self.allowGearChangeTimer = 0
                setEvent(string.format("PTO automatic: down %d -> %d (%.0f rpm, load %.0f%%)", curGear, curGear - 1, rpm, load * 100))
                return curGear - 1
            end
        end
    end

    -- vise: motor na ciljanim okretajima, ima rezerve snage i vozac trazi brzinu
    if curGear < #gears and since > 2500 and math.abs(acceleratorPedal or 0) > 0.9
    and rpm >= target * 0.97 and load * 1.25 < 0.9 then
        self.jd7810LastPtoUp = now
        setEvent(string.format("PTO automatic: up %d -> %d (load %.0f%%)", curGear, curGear + 1, load * 100))
        return curGear + 1
    end

    return curGear
end

