-- =====================================================================
--  JD7810HdTextures.lua   v1.0  (FS25 - osobna upotreba, Darijan)
--  12. modul: HD PAKET TEKSTURA (v163, Darijan 8.10.2026)
--
--  Osnovni mod nosi 2K teksture. Ako je u igri ukljucen i zaseban mod FS25_JohnDeere_7810_HD
--  (samo modDesc + mapa textures/ s 4K DDS istih imena), nakon ucitavanja traktora zamijene se
--  mape materijala (diffuse / normal / vmask) onima iz HD paketa:
--    getMaterialDiffuseMapFilename / NormalMap / GlossMap  -> ime datoteke
--    setMaterialDiffuseMapFromFile / NormalMap / GlossMap(materialId, file, wrap, isSRGB, sharedEdit)
--  (GDN Engine > Rendering, FS25 v1.20). sharedEdit = true: mijenja se zajednicki materijal,
--  pa svaki materijal obradimo samo jednom po igri (vrijedi za sve 7810 na mapi).
--
--  Samo vizualno (klijent), bez mreznog prometa. Dedicated server preskace.
--  Postavka: jd7810Settings.xml <hd enabled="true"/> (false = uvijek 2K i kad je paket ukljucen).
--  Log: "JD7810: HD textures ON (N maps)" ili "JD7810: HD pack not found - standard textures".
-- =====================================================================

local JD = JD7810Transmission
local log = JD.U.log

JD.HD_VERSION = "1.0"
JD.HD_MOD_NAME = "FS25_JohnDeere_7810_HD"

table.insert(JD.SETTINGS, { key = "hdTextures", type = "bool", default = true, xml = ".hd#enabled",
    desc = "HD paket: koristi 4K teksture iz moda FS25_JohnDeere_7810_HD kad je ukljucen" })
if JD.cfg.hdTextures == nil then JD.cfg.hdTextures = true end
pcall(JD.loadSettings)   -- Display.lua je postavke ucitao prije ovog modula -> ucitaj ponovo da vrijedi i <hd enabled>

JD.hdDone = {}          -- materialId -> true (vec obradeno u ovoj igri)
JD.hdDir = nil          -- mapa textures/ HD paketa (nil = jos nije trazeno, false = nema paketa)
JD.hdCount = 0

-- mapa HD paketa ili false
local function hdDirectory()
    if JD.hdDir ~= nil then return JD.hdDir end
    JD.hdDir = false
    local name = JD.HD_MOD_NAME
    if g_modIsLoaded ~= nil and g_modIsLoaded[name] and g_modNameToDirectory ~= nil and g_modNameToDirectory[name] ~= nil then
        JD.hdDir = g_modNameToDirectory[name] .. "textures/"
    end
    if JD.hdDir then log("HD pack found: " .. tostring(JD.hdDir)) else log("HD pack not found - standard textures") end
    return JD.hdDir
end

local function baseName(path)
    if path == nil or path == "" then return nil end
    return string.match(path, "([^/\\]+)$")
end

-- vrati HD datoteku za ime osnovne teksture (ili nil)
local function hdFileFor(dir, path)
    local b = baseName(path)
    if b == nil then return nil end
    local f = dir .. b
    if fileExists(f) then return f end
    return nil
end

-- obradi jedan materijal; vraca broj zamijenjenih mapa
local function processMaterial(dir, mat)
    if mat == nil or mat == 0 or JD.hdDone[mat] then return 0 end
    JD.hdDone[mat] = true
    local n = 0
    local f = hdFileFor(dir, getMaterialDiffuseMapFilename(mat))
    if f ~= nil then setMaterialDiffuseMapFromFile(mat, f, true, true, true); n = n + 1 end
    f = hdFileFor(dir, getMaterialNormalMapFilename(mat))
    if f ~= nil then setMaterialNormalMapFromFile(mat, f, true, false, true); n = n + 1 end
    f = hdFileFor(dir, getMaterialGlossMapFilename(mat))
    if f ~= nil then setMaterialGlossMapFromFile(mat, f, true, false, true); n = n + 1 end
    return n
end

-- rekurzivno kroz cvorove vozila (shape -> materijali)
local function processNode(dir, node)
    local n = 0
    if getHasClassId(node, ClassIds.SHAPE) then
        for i = 0, getNumOfMaterials(node) - 1 do
            n = n + processMaterial(dir, getMaterial(node, i))
        end
    end
    for i = 0, getNumOfChildren(node) - 1 do
        n = n + processNode(dir, getChildAt(node, i))
    end
    return n
end

function JD.hdApply(vehicle)
    if not JD.cfg.hdTextures or g_client == nil then return end
    local dir = hdDirectory()
    if not dir then return end
    local n = 0
    for _, c in ipairs(vehicle.components or {}) do
        if c.node ~= nil and c.node ~= 0 then n = n + processNode(dir, c.node) end
    end
    JD.hdCount = JD.hdCount + n
    log(string.format("HD textures ON (%d maps, total %d)", n, JD.hdCount))
end

if Motorized ~= nil and Motorized.onPostLoad ~= nil then
    Motorized.onPostLoad = Utils.appendedFunction(Motorized.onPostLoad, function(self)
        local motor = self.spec_motorized ~= nil and self.spec_motorized.motor or nil
        if motor ~= nil and JD.U.isOurs(motor) then
            local ok, err = pcall(JD.hdApply, self)
            if not ok then log("HD textures error: " .. tostring(err)) end
        end
    end)
end

log("HD modul v" .. JD.HD_VERSION .. " ucitan")
