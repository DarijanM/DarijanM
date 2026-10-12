-- =====================================================================
--  JD7810Heading.lua   v8.6  (FS25 - osobna upotreba, Darijan)
--  11. modul (zadnji): ZAKLJUCAVANJE SMJERA PO KOMPASU (kao "keep direction" u VCA)
--
--  LCtrl + 2: zakljuca trenutni smjer (kompas: 0 = sjever, 90 = istok, 180 = jug, 270 = zapad; zaokruzeno na korak
--    iz izbornika "Heading resolution": tocno 0,1 / 1 / 5 / 15 / 45 st., zadano 1).
--    Ako je novi smjer unutar 10 st. od proslog zakljucanog ili suprotnog (+180), uzme se TOCNO taj
--    (npr. prosli 90 -> u povratnoj traci 270,0) = paralelne trake.
--  Traktor sam drzi smjer (upravlja kotacima) dok:
--    - ne okrenes volan / A-D (vise od 12 % hoda), ili
--    - ne stisnes kocnicu, ili ne kreces unatrag, ili ne pokrene AI / izades iz traktora,
--    - ili ponovo ne stisnes LCtrl + 2.
--  Radna voznja (tempomat, LCtrl + 1) pri tome ostaje ukljucena.
--
--  NAPOMENA (odstupanje od stvarnog traktora): JD 7810 (1997.-2003.) nije imao drzanje smjera; AutoTrac je
--  dosao 2002./03. Ovo je pomoc za igru po Darijanovoj zelji.
--  Samo singleplayer (nema mreznog sinkroniziranja upravljanja).
--  Postavke (jd7810Settings.xml nema): headingKp/Kd/sign se mogu mijenjati jd7810Set (nisu spremljene).
-- =====================================================================

local JD = JD7810Transmission
local log = JD.U.log
local setEvent = JD.U.setEvent
local clamp = JD.U.clamp

JD.HEADING_VERSION = "8.6"

local HCFG = {
    kp = 0.06,          -- volan po stupnju greske (17 st. = puni zakret)
    kd = 0.10,          -- prigusenje: volan po st./s brzine okretanja
    sign = 1,           -- smjer volana (axisSide) za skretanje udesno (+1: axisSide > 0 = desno, kao tipka D); ako traktor bjezi od smjera -> jd7810Heading sign
    snapDeg = 25,       -- unutar toliko stupnjeva od proslog smjera (ili +180) -> tocno prosli smjer
    releaseSteer = 0.12,-- hod volana / tipke koji iskljucuje drzanje
    releaseBrake = 0.05,
    rate = 2.5,         -- najveca promjena naredbe volana u sekundi (glatko)
}
JD.headingCfg = HCFG

local function wrap180(a)
    a = (a + 180) % 360
    if a < 0 then a = a + 360 end
    return a - 180
end
local function wrap360(a)
    a = a % 360
    if a < 0 then a = a + 360 end
    return a
end

local function isOursVehicle(v)
    return v ~= nil and v.spec_motorized ~= nil and v.spec_motorized.motor ~= nil and JD.U.isOurs(v.spec_motorized.motor)
end

-- kompas: 0 = sjever (-z), 90 = istok (+x)
function JD.getHeadingDeg(vehicle)
    if vehicle == nil or vehicle.rootNode == nil then return nil end
    local dx, _, dz = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
    if math.abs(dx) + math.abs(dz) < 1e-4 then return nil end
    return wrap360(math.deg(math.atan2(dx, -dz)))
end

local function release(vehicle, why)
    local H = vehicle.jd7810Head
    if H == nil or not H.on then return end
    H.on = false
    H.u = 0
    if JD7810Transmission.playUiSound ~= nil then JD7810Transmission.playUiSound("heading_off") end   -- v171
    setEvent(string.format("Heading lock off (%s)", why or ""))
    log(string.format("smjer: iskljuceno (%s)", why or ""))
end
JD.headingRelease = release

function JD.toggleHeadingLock(vehicle)
    if not isOursVehicle(vehicle) then return end
    vehicle.jd7810Head = vehicle.jd7810Head or { on = false, u = 0 }
    local H = vehicle.jd7810Head
    if H.on then release(vehicle, "key"); return end
    local h = JD.getHeadingDeg(vehicle)
    if h == nil then return end
    -- v155: korak zaokruzivanja (izbornik "Heading resolution"): 0,1 = tocno kako vozis, 1 / 5 / 15 / 45 st. = grubo
    local stepDeg = JD.cfg.headingStep or 1
    local target = wrap360(math.floor(h / stepDeg + 0.5) * stepDeg)
    -- v187: osnovni smjer (H.last) ostaje kroz okrete; unutar headingSnap (25) -> tocno osnovni ili suprotni.
    -- Novi osnovni smjer tek kad je zakljucano > 45 st. od osnovnog i od suprotnog (stvarno novi smjer rada).
    local newRef = target
    if H.last ~= nil then
        local snap = JD.cfg.headingSnap or HCFG.snapDeg
        local d0, d1 = math.abs(wrap180(h - H.last)), math.abs(wrap180(h - (H.last + 180)))
        if d0 <= snap then
            target = H.last
        elseif d1 <= snap then
            target = wrap360(H.last + 180)
        end
        newRef = (math.min(d0, d1) > 45) and target or H.last
    end
    H.on, H.target, H.last, H.u, H.prevH, H.logT = true, target, newRef, 0, h, 0
    if JD7810Transmission.playUiSound ~= nil then JD7810Transmission.playUiSound("heading_on") end   -- v171
    setEvent(string.format("Heading lock %.1f deg", target))
    log(string.format("smjer: zakljucano %.1f st. (trenutno %.1f)", target, h))
end

-- v155: GreenStar stranica HDG - upis cilja / osnovnog smjera brojkama
function JD.headingSetTarget(vehicle, deg)
    if not isOursVehicle(vehicle) or deg == nil then return end
    vehicle.jd7810Head = vehicle.jd7810Head or { on = false, u = 0 }
    local H = vehicle.jd7810Head
    local t = wrap360(deg)
    H.on, H.target, H.last, H.u, H.prevH, H.logT = true, t, t, 0, JD.getHeadingDeg(vehicle), 0
    if JD7810Transmission.playUiSound ~= nil then JD7810Transmission.playUiSound("heading_on") end   -- v171
    setEvent(string.format("Heading lock %.1f deg (terminal)", t))
    log(string.format("smjer: cilj s terminala %.1f st.", t))
end
function JD.headingSetReference(vehicle, deg)
    if not isOursVehicle(vehicle) then return end
    vehicle.jd7810Head = vehicle.jd7810Head or { on = false, u = 0 }
    vehicle.jd7810Head.last = deg ~= nil and wrap360(deg) or nil
    log("smjer: osnovni smjer " .. (deg ~= nil and string.format("%.1f st.", wrap360(deg)) or "obrisan"))
end

function JD.actionHeadingLock(vehicle, actionName, inputValue, callbackState, isAnalog)
    JD.toggleHeadingLock(vehicle)
end

-- vozac okrene volan / tipke -> drzanje se iskljuci (radna voznja ostaje)
if Drivable ~= nil and Drivable.setSteeringInput ~= nil then
    Drivable.setSteeringInput = Utils.prependedFunction(Drivable.setSteeringInput, function(self, inputValue, isAnalog, deviceCategory)
        local H = self.jd7810Head
        if H ~= nil and H.on and math.abs(inputValue or 0) > HCFG.releaseSteer then release(self, "steering") end
    end)
end
if Drivable ~= nil and Drivable.setBrakePedalInput ~= nil then
    Drivable.setBrakePedalInput = Utils.prependedFunction(Drivable.setBrakePedalInput, function(self, inputValue)
        local H = self.jd7810Head
        if H ~= nil and H.on and (inputValue or 0) > HCFG.releaseBrake then release(self, "brake") end
    end)
end

-- regulator: greska smjera -> naredba volana (axisSide), prije fizike vozila
local function steerCommand(self, dt)
    local H = self.jd7810Head
    if JD.U.isAIActive(self) then release(self, "AI"); return nil end
    if self.getIsControlled ~= nil and not self:getIsControlled() then release(self, "left vehicle"); return nil end
    local motor = self.spec_motorized.motor
    local v = JD.U.getSpeedKmh(motor) or 0
    -- v155b: unatrag = smjer mjenjaca unatrag (odmah) ili voznja unatrag > 1 km/h dulje od 0,5 s
    -- (teleport / trzaj zna na trenutak dati movingDirection -1)
    if (motor.currentDirection or 1) < 0 then release(self, "reverse gear"); return nil end
    if (self.movingDirection or 1) < 0 and v > 1 then
        H.revT = (H.revT or 0) + (dt or 0)
        if H.revT > 500 then release(self, "reverse"); return nil end
    else
        H.revT = 0
    end
    local h = JD.getHeadingDeg(self)
    if h == nil then return nil end
    local dts = math.max(dt or 16, 1) / 1000
    local rateDeg = wrap180(h - (H.prevH or h)) / dts          -- st./s, + = udesno
    H.prevH = h
    H.rateF = (H.rateF or 0) + (rateDeg - (H.rateF or 0)) * math.min(1, dts / 0.15)
    local e = wrap180(H.target - h)                             -- + = treba udesno
    local sf = clamp(10 / math.max(v, 1), 0.35, 1)               -- na vecoj brzini manje volana
    local want = clamp((HCFG.kp * e - HCFG.kd * H.rateF) * sf, -1, 1)
    if v < 0.5 then want = 0 end
    local step = HCFG.rate * dts
    H.u = clamp(want, (H.u or 0) - step, (H.u or 0) + step)
    H.err = e
    H.logT = (H.logT or 0) + (dt or 0)
    if H.logT > 2000 then
        H.logT = 0
        log(string.format("smjer: cilj %.1f, smjer %.1f, greska %+.1f, okretanje %+.1f st/s, volan %+.2f, %.1f km/h", H.target, h, e, H.rateF, H.u, v))
    end
    return H.u * HCFG.sign
end

if Drivable ~= nil and Drivable.updateVehiclePhysics ~= nil then
    Drivable.updateVehiclePhysics = Utils.overwrittenFunction(Drivable.updateVehiclePhysics, function(self, superFunc, axisForward, axisSide, doHandbrake, dt)
        local H = self.jd7810Head
        if H ~= nil and H.on then
            local ok, cmd = pcall(steerCommand, self, dt)
            if ok and cmd ~= nil then
                axisSide = cmd
                if self.spec_drivable ~= nil then self.spec_drivable.axisSide = cmd end
            elseif not ok and not H.errLogged then
                H.errLogged = true
                log("smjer: greska " .. tostring(cmd))
                H.on = false
            end
        end
        return superFunc(self, axisForward, axisSide, doHandbrake, dt)
    end)
else
    log("smjer: Drivable.updateVehiclePhysics nije pronadjen - zakljucavanje smjera ne radi")
end

-- konzola: jd7810Heading [sign 1|-1 | kp N | kd N]
function JD7810Transmission:consoleHeading(a, b)
    local n = tonumber(b)
    if a == "sign" and n ~= nil then HCFG.sign = n >= 0 and 1 or -1
    elseif a == "kp" and n ~= nil then HCFG.kp = n
    elseif a == "kd" and n ~= nil then HCFG.kd = n end
    return string.format("heading lock: sign %d, kp %.3f, kd %.3f, snap %d deg", HCFG.sign, HCFG.kp, HCFG.kd, HCFG.snapDeg)
end
if JD.COMMANDS ~= nil then
    table.insert(JD.COMMANDS, { "jd7810Heading", "drzanje smjera: sign 1|-1, kp N, kd N", "consoleHeading", "[sign|kp|kd N]" })
end

log("Heading modul v" .. JD.HEADING_VERSION .. " ucitan")
