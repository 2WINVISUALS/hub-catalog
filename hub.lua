--[[
    2WIN VFX Hub [2WINVISUALS]
    ---------------------------------------------------------------
    One effect browser for every 2WINVISUALS pack. The Hub itself knows no
    effects: it discovers installed packs and optional add-on modules at
    startup, merges them, and offers the rest in the Add-ons tab.

    Install layout (next to this script):
        2WIN VFX Hub/
          Packs/<pack-id>/pack.txt      one folder per owned product
          Packs/<pack-id>/presets.drb   that pack's adjustment-clip presets
          Packs/<pack-id>/...           thumbnails, previews, clip FX, media
          Modules/<id>.hubmodule        optional add-ons (e.g. Auto VFX)
          Store.txt                     products shown in the Add-ons tab
          UI/logo.png, UI/window_icon.ico

    pack.txt (plain data, never executed):
        name    = MV Essentials 1
        version = 1.0
        order   = 10
        drb     = presets.drb
        bin     = 2WIN VFX Hub - MV Essentials 1
        [effects]
        Defocus Pre | BLURS
        Speed Ramp Pre | CLIP FX | clip
        Smoke Overlay | OVERLAYS | media | Media/smoke.mov
        [store]
        auto-vfx | Auto VFX | Scatter effects over every cut | https://... | module

    Effect kinds: preset (default; a clip of that name in the pack's bin:
    adjustment clips, Fusion titles, generators), clip (duplicates the shot
    and applies Packs/<id>/ClipFX/<name>.setting), media (imports the file
    and lays it on the track above).

    Run from:  Workspace > Scripts > Utility > 2WIN VFX Hub
    (that script is a small launcher; this file is 2WIN VFX Hub/Core/hub.lua)
]]

-- The Hub's own version. release_hub.py sets it; remote updates compare it.
local HUB_VERSION = "1.7.3"

-- Where the Hub checks for updates and the product list. A remote.txt next to
-- the Packs folder overrides it (used for testing).
local REMOTE_BASE = "https://raw.githubusercontent.com/2WINVISUALS/hub-catalog/main"

local ui   = fu and fu.UIManager
-- Resolve closing or crashing can leave no window system: stop quietly. Returning (not
-- erroring) keeps the launcher from mistaking it for a broken update and rolling back.
if not ui then
    print("2WIN VFX Hub: Resolve's window system isn't ready - open the Hub again once Resolve has fully started")
    do return end
end
local disp = bmd.UIDispatcher(ui)

--------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------

local LAUNCH_ARGS = { ... }
local HUB_DIR = LAUNCH_ARGS[1]
if type(HUB_DIR) ~= "string" then
    -- run directly (not via the launcher): Core/hub.core -> its parent folder
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    HUB_DIR = src:match("^(.*)[/\\][^/\\]-[/\\][^/\\]-$")
end
local CORE_DIR   = HUB_DIR .. "/Core"
local PACKS_DIR  = HUB_DIR .. "/Packs"
local MODULE_DIR = HUB_DIR .. "/Modules"
local STORE_FILE = HUB_DIR .. "/Store.txt"
local FAV_FILE   = HUB_DIR .. "/Favourites.txt"
local LOGO       = HUB_DIR .. "/UI/logo.png"
local LOGO_ANIM  = HUB_DIR .. "/UI/logo_anim"   -- animated header (played once on open), if installed
local ICON       = HUB_DIR .. "/UI/window_icon.ico"
local STORE_HOME = "https://store.2winvisuals.com"

local function urlPath(p)
    return "file:///" .. p:gsub("\\", "/"):gsub(" ", "%%20")
end

local function fileExists(p)
    local f = io.open(p, "r")
    if f then f:close() return true end
    return false
end

local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

local function displayName(name)
    return (name:gsub("^[Mm][Vv]2%s+", ""):gsub("[Ff][Ll][Kk][Rr]", "Flicker"))
end

-- readdir returns string-keyed "Pattern"/"Parent" entries too: ipairs only.
local function listDir(pattern)
    local out = {}
    local ok, entries = pcall(function() return bmd.readdir(pattern) end)
    if ok and type(entries) == "table" then
        for _, entry in ipairs(entries) do
            local name = type(entry) == "table" and entry.Name or entry
            local isDir = type(entry) == "table" and entry.IsDir
            if type(name) == "string" then out[#out + 1] = { name = name, dir = isDir } end
        end
    end
    return out
end

-- A name that is safe as a single path component: no separators, no "..".
local function safeName(s)
    return type(s) == "string" and s ~= "" and not s:find("[/\\:%*%?\"<>|]") and not s:find("%.%.")
end

-- Store links come from our own data files, but they still only ever reach
-- the shell as a quoted https URL with a conservative character set.
local function safeUrl(u)
    return type(u) == "string" and u:match("^https://[%w%-%._~:/%?#@!%$&%(%)%*%+,;=%%]+$") ~= nil
end

--------------------------------------------------------------------
-- Remote: product list + Hub updates
--------------------------------------------------------------------

local function readAll(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
end
local function writeAll(p, d)
    local f = io.open(p, "wb"); if not f then return false end
    f:write(d); f:close(); return true
end

do
    local o = readAll(HUB_DIR .. "/remote.txt")
    o = o and o:match("^%s*(%S+)")
    if o and (o:match("^https://") or o:match("^http://127%.0%.0%.1[:/]")) then REMOTE_BASE = o:gsub("/+$", "") end
end

-- The launcher this core expects: a copy of core/launcher.lua (the build checks they match).
local LAUNCHER_SOURCE = [==[
--[[
    2WIN VFX Hub [2WINVISUALS]
    Run from:  Workspace > Scripts > Utility > 2WIN VFX Hub

    This small launcher starts the Hub from "2WIN VFX Hub/Core/hub.core" (not .lua,
    so Resolve's Scripts menu doesn't list it). The Hub updates itself by replacing
    that file (keeping the previous one as hub_prev.core). If a new version ever
    fails to start, the launcher puts the previous version back and runs it, so an
    update can never leave the Hub broken.
]]

local function scriptDir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return src:match("^(.*)[/\\][^/\\]-$")
end

local ROOT = scriptDir() .. "/2WIN VFX Hub"
local CORE = ROOT .. "/Core"

-- While Resolve is starting up or shutting down there may be no window system. Nothing
-- can run then, and it's not the Hub's fault: stop here instead of rolling back.
if not (fu and fu.UIManager) then
    print("2WIN VFX Hub: Resolve isn't ready - open the Hub again once Resolve has fully started")
    return
end

local function readAll(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
end
local function writeAll(p, d)
    local f = io.open(p, "wb"); if not f then return false end
    f:write(d); f:close(); return true
end
local function note(msg)
    writeAll(ROOT .. "/last_launch.txt", os.date("%Y-%m-%d %H:%M:%S") .. "  " .. msg .. "\n")
end

local function run(path)
    local chunk, err = loadfile(path)
    if not chunk then return false, err end
    return xpcall(function() return chunk(ROOT) end, function(e) return debug.traceback(tostring(e), 2) end)
end

-- A hub.lua is newer than hub.core: an older Hub version saved its update under that
-- name. The Hub renames it to hub.core when it starts.
local MAIN = readAll(CORE .. "/hub.lua") and (CORE .. "/hub.lua") or (CORE .. "/hub.core")
local ok, err = run(MAIN)
if ok then os.remove(CORE .. "/failed_once.txt") return end

-- One failure can just be Resolve closing or crashing under the Hub. Roll back only when
-- the same version fails on two starts in a row (a broken update fails every time).
local failedVer = readAll(CORE .. "/version.txt") or "?"
if readAll(CORE .. "/failed_once.txt") ~= failedVer then
    writeAll(CORE .. "/failed_once.txt", failedVer)
    note("Hub failed once, will try again next time: " .. tostring(err))
    print("2WIN VFX Hub could not start (" .. tostring(err) .. ") - please open it again")
    return
end
os.remove(CORE .. "/failed_once.txt")

-- The current version failed. Fall back to the previous one, if there is one.
local prev = readAll(CORE .. "/hub_prev.core")
if prev then
    local bad = readAll(MAIN)
    if bad then writeAll(CORE .. "/hub_failed.core", bad) end
    -- remember the failed version so the Hub doesn't offer it again
    local badVer = readAll(CORE .. "/version.txt")
    if badVer then writeAll(CORE .. "/skip_version.txt", badVer) end
    writeAll(CORE .. "/hub.core", prev)
    if MAIN ~= CORE .. "/hub.core" then os.remove(MAIN) end
    local prevVer = readAll(CORE .. "/version_prev.txt")
    if prevVer then writeAll(CORE .. "/version.txt", prevVer) end
    writeAll(CORE .. "/rolled_back.txt", tostring(err))
    note("Hub failed, rolled back to previous version: " .. tostring(err))
    local ok2, err2 = run(CORE .. "/hub.core")
    if not ok2 then note("previous version also failed: " .. tostring(err2)); print("2WIN VFX Hub could not start: " .. tostring(err2)) end
else
    note("Hub failed: " .. tostring(err))
    print("2WIN VFX Hub could not start: " .. tostring(err))
end
]==]

-- Installs from before the rename kept the core as Core/hub.lua (and hub_prev.lua after an
-- update), which Resolve lists in its Scripts menu. When an old launcher starts this version
-- from hub.lua, move the files to .core and bring the launcher up to date, so from the next
-- start only "2WIN VFX Hub" is in the menu. Only for a launcher start of the installed Hub.
if type(LAUNCH_ARGS[1]) == "string" then
    pcall(function()
        local norm = function(p) return (p:gsub("\\", "/"):lower()) end
        local running = norm(debug.getinfo(1, "S").source:gsub("^@", ""))
        local fromLua = running == norm(CORE_DIR .. "/hub.lua")
        for _, name in ipairs({ "hub", "hub_prev", "hub_failed" }) do
            local old, new = CORE_DIR .. "/" .. name .. ".lua", CORE_DIR .. "/" .. name .. ".core"
            local d = readAll(old)
            if d then
                -- the running hub.lua is this (newest) version; otherwise never overwrite a .core
                local keep = (name == "hub") and not fromLua or (name ~= "hub" and fileExists(new))
                if keep or writeAll(new, d) then os.remove(old) end
            end
        end
        local path = HUB_DIR .. ".lua"
        local have = readAll(path)
        if have and (have:gsub("\r\n", "\n")) ~= LAUNCHER_SOURCE then writeAll(path, LAUNCHER_SOURCE) end
    end)
end

-- SHA-256 (LuaJIT bit ops), to verify downloaded updates.
local sha256
do
    local bit = require("bit")
    local band, bor, bxor, bnot, rshift, lshift, ror =
        bit.band, bit.bor, bit.bxor, bit.bnot, bit.rshift, bit.lshift, bit.ror
    local K = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 }
    sha256 = function(msg)
        local len = #msg
        msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
        local bits = len * 8
        local hi, lo = math.floor(bits / 4294967296), bits % 4294967296
        msg = msg .. string.char(rshift(hi, 24) % 256, rshift(hi, 16) % 256, rshift(hi, 8) % 256, hi % 256,
                                 math.floor(lo / 16777216) % 256, math.floor(lo / 65536) % 256, math.floor(lo / 256) % 256, lo % 256)
        local H = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 }
        local w = {}
        for chunk = 1, #msg, 64 do
            for i = 0, 15 do
                local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
                w[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
            end
            for i = 16, 63 do
                local s0 = bxor(ror(w[i-15], 7), ror(w[i-15], 18), rshift(w[i-15], 3))
                local s1 = bxor(ror(w[i-2], 17), ror(w[i-2], 19), rshift(w[i-2], 10))
                w[i] = w[i-16] + s0 + w[i-7] + s1
            end
            local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
            for i = 0, 63 do
                local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
                local ch = bxor(band(e, f), band(bnot(e), g))
                local t1 = h + S1 + ch + K[i + 1] + w[i]
                local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
                local maj = bxor(band(a, b), band(a, c), band(b, c))
                local t2 = S0 + maj
                h, g, f, e, d, c, b, a = g, f, e, bit.tobit(d + t1), c, b, a, bit.tobit(t1 + t2)
            end
            H[1], H[2], H[3], H[4] = bit.tobit(H[1] + a), bit.tobit(H[2] + b), bit.tobit(H[3] + c), bit.tobit(H[4] + d)
            H[5], H[6], H[7], H[8] = bit.tobit(H[5] + e), bit.tobit(H[6] + f), bit.tobit(H[7] + g), bit.tobit(H[8] + h)
        end
        local out = {}
        for i = 1, 8 do out[i] = bit.tohex(H[i]) end
        return table.concat(out)
    end
end

-- Downloads url to dest. Windows: urlmon directly (no console window);
-- elsewhere: curl. Returns true on success.
local download
do
    local okFfi, ffi = pcall(require, "ffi")
    local urlmon
    if okFfi and ffi.os == "Windows" then
        pcall(function()
            ffi.cdef[[
                long __stdcall URLDownloadToFileW(void*, const uint16_t*, const uint16_t*, unsigned long, void*);
            ]]
        end)
        pcall(function() ffi.cdef[[ int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char*, int, uint16_t*, int); ]] end)
        local ok, lib = pcall(ffi.load, "urlmon")
        if ok then urlmon = lib end
    end
    local function wide(text)
        local k32 = ffi.C
        local n = k32.MultiByteToWideChar(65001, 0, text, -1, nil, 0)
        local out = ffi.new("uint16_t[?]", n)
        k32.MultiByteToWideChar(65001, 0, text, -1, out, n)
        return out
    end
    download = function(url, dest)
        os.remove(dest)
        -- a unique query defeats the Windows internet cache
        local u = url .. (url:find("?", 1, true) and "&" or "?") .. "t=" .. os.time() .. math.random(100000)
        if urlmon then
            local hr = urlmon.URLDownloadToFileW(nil, wide(u), wide((dest:gsub("/", "\\"))), 0, nil)
            return hr == 0 and readAll(dest) ~= nil
        end
        if not safeUrl(u) and not u:match("^http://127%.0%.0%.1") then return false end
        os.execute('curl -s -f -L --max-time 8 -o "' .. dest .. '" "' .. u .. '"')
        return readAll(dest) ~= nil
    end
end

local function versionParts(v)
    local t = {}
    for n in tostring(v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end
local function newerThan(a, b)   -- is version a newer than b?
    local x, y = versionParts(a), versionParts(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

-- Remote hub.txt: "version = 1.1", "sha256 = ...", "file = hub.lua", then
-- "notes = ..." lines (each one a bullet).
local function parseRelease(text)
    local r = { notes = {} }
    for line in (text or ""):gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k == "notes" then r.notes[#r.notes + 1] = v
        elseif k then r[k:lower()] = v end
    end
    if not (r.version and r.sha256 and r.file and safeName(r.file)) then return nil end
    return r
end

local TMP_DIR = CORE_DIR
local update = { state = "idle" }   -- idle | current | available | offline | installed | failed

local function checkForUpdates()
    local tmp = TMP_DIR .. "/.release.txt"
    if not download(REMOTE_BASE .. "/hub.txt", tmp) then
        update = { state = "offline" }
        return update
    end
    local rel = parseRelease(readAll(tmp)); os.remove(tmp)
    if not rel then update = { state = "offline" } return update end
    -- a version that failed to start here once is not offered again
    local skip = readAll(CORE_DIR .. "/skip_version.txt")
    skip = skip and skip:match("^%s*(%S+)")
    local offer = newerThan(rel.version, HUB_VERSION) and rel.version ~= skip
    update = { state = offer and "available" or "current", release = rel }
    return update
end

-- Downloads, verifies, keeps the current version as hub_prev.core, swaps in.
local function installUpdate()
    local rel = update.release
    if not rel then return false, "no update to install" end
    local tmp = CORE_DIR .. "/.hub_download.tmp"
    if not download(REMOTE_BASE .. "/" .. rel.file, tmp) then return false, "download failed - check your connection" end
    local data = readAll(tmp)
    if not data or sha256(data) ~= rel.sha256:lower() then os.remove(tmp) return false, "download was corrupted - nothing was changed" end
    local chunk = loadfile(tmp)
    if not chunk then os.remove(tmp) return false, "update file is invalid - nothing was changed" end
    local current = readAll(CORE_DIR .. "/hub.core")
    if current then
        writeAll(CORE_DIR .. "/hub_prev.core", current)
        writeAll(CORE_DIR .. "/version_prev.txt", HUB_VERSION)
    end
    if not writeAll(CORE_DIR .. "/hub.core", data) then os.remove(tmp) return false, "could not write the update" end
    writeAll(CORE_DIR .. "/version.txt", rel.version)
    os.remove(tmp)
    update.state = "installed"
    return true
end

-- The product list: the copy shipped with the Hub, then the last one
-- downloaded, then a fresh download when online.
local CATALOG_CACHE = HUB_DIR .. "/catalog_cache.txt"
local function refreshCatalog()
    local tmp = HUB_DIR .. "/.catalog.txt"
    if download(REMOTE_BASE .. "/catalog.txt", tmp) then
        local d = readAll(tmp)
        if d and d:find("|", 1, true) then writeAll(CATALOG_CACHE, d) end
        os.remove(tmp)
        return true
    end
    return false
end

--------------------------------------------------------------------
-- Pack discovery (plain data only)
--------------------------------------------------------------------

local PACKS = {}          -- ordered list of installed packs
local STORE = {}          -- products for the Add-ons tab, by id
local STORE_ORDER = {}

-- Top-level sections group the categories. A pack may place its own categories
-- with a [sections] block ("LYRIC FX = TEXT"); anything unassigned is an EFFECT.
local SECTION_ORDER = { "EFFECTS", "TEXT", "CLIP FX", "OVERLAYS" }
local DEFAULT_SECTION = { TITLES = "TEXT", ["LYRIC EFFECTS"] = "TEXT", LYRICS = "TEXT",
                          ["CLIP FX"] = "CLIP FX", OVERLAYS = "OVERLAYS" }
local PACK_SECTIONS = {}
local function sectionOf(cat)
    return PACK_SECTIONS[cat] or DEFAULT_SECTION[cat] or "EFFECTS"
end

-- Effect-type order for the list and the category buttons: ALL shows the effects
-- grouped by type in this order (alphabetical inside a type); unknown types follow
-- the known ones of their section, in the order packs introduce them.
local CATEGORY_ORDER = { "FLASHES", "SHAKES", "BLURS", "TRANSFORMS", "MOVES", "1 FRAMERS", "FLICKERS",
                         "DISTORTIONS", "DISSOLVES", "CLIP FX", "TITLES", "LYRIC EFFECTS", "LYRICS", "OVERLAYS" }
local CATEGORY_RANK = {}
for i, c in ipairs(CATEGORY_ORDER) do CATEGORY_RANK[c] = i end
local function sectionRank(sec)
    for i, s in ipairs(SECTION_ORDER) do if s == sec then return i end end
    return #SECTION_ORDER + 1
end

local function addStoreLine(line)
    -- id | name | description | store URL | kind [| image URL | ...]. Columns past the ones this
    -- version knows are ignored (not rejected), so the list can grow (product images, 1.7.3+)
    -- without older Hubs dropping products.
    local f = {}
    for field in (line .. "|"):gmatch("(.-)|") do f[#f + 1] = trim(field) end
    local id, name, desc, url, kind, image = f[1], f[2], f[3], f[4], f[5] or "", f[6]
    if not (id and safeName(id) and name and name ~= "" and url and safeUrl(url)) then return end
    kind = (kind ~= nil and kind ~= "") and kind:lower() or "pack"
    -- "pack,soon" / "module,soon": listed as COMING SOON (older Hubs just see a product)
    local soon = kind:find("soon", 1, true) ~= nil
    kind = kind:gsub("[,%s]*soon", ""):gsub("^[,%s]+", "")
    if kind == "" then kind = "pack" end
    if not STORE[id] then STORE_ORDER[#STORE_ORDER + 1] = id end
    STORE[id] = { id = id, name = name, desc = desc or "", url = url, kind = kind, soon = soon,
                  image = (image and image ~= "" and safeUrl(image)) and image or nil }
end

local function readPack(id)
    local dir = PACKS_DIR .. "/" .. id
    local f = io.open(dir .. "/pack.txt", "r")
    if not f then return nil end
    local pack = { id = id, dir = dir, name = id, order = 100, effects = {}, drb = "presets.drb" }
    local section = "head"
    for raw in f:lines() do
        local line = trim((raw:gsub("\r$", "")))
        if line == "" or line:sub(1, 1) == "#" then
            -- skip
        elseif line:lower() == "[effects]" then section = "effects"
        elseif line:lower() == "[store]" then section = "store"
        elseif line:lower() == "[sections]" then section = "sections"
        elseif section == "sections" then
            local cat, sec = line:match("^(.-)%s*=%s*(.-)$")
            if cat and cat ~= "" and sec ~= "" and #sec <= 20 then PACK_SECTIONS[cat:upper()] = sec:upper() end
        elseif section == "head" then
            local k, v = line:match("^([%w_]+)%s*=%s*(.-)$")
            if k then pack[k:lower()] = v end
        elseif section == "store" then
            addStoreLine(line)
        else
            local fields = {}
            for field in (line .. "|"):gmatch("(.-)|") do fields[#fields + 1] = trim(field) end
            local name, cat, kind, extra = fields[1], fields[2], (fields[3] or ""):lower(), fields[4]
            if safeName(name) then
                if kind == "" then kind = "preset" end
                pack.effects[#pack.effects + 1] = {
                    name = name, category = (cat and cat ~= "") and cat:upper() or "OTHER",
                    kind = kind, extra = extra,
                }
            end
        end
    end
    f:close()
    pack.order = tonumber(pack.order) or 100
    if not safeName(pack.drb) then pack.drb = "presets.drb" end
    pack.drbPath = dir .. "/" .. pack.drb
    pack.bin = (pack.bin and pack.bin ~= "") and pack.bin or ("2WIN VFX Hub - " .. pack.name)
    return pack
end

local function loadStoreFile(path)
    local f = io.open(path, "r")
    if not f then return end
    for raw in f:lines() do
        local line = trim((raw:gsub("\r$", "")))
        if line ~= "" and line:sub(1, 1) ~= "#" then addStoreLine(line) end
    end
    f:close()
end

local function discoverPacks()
    PACKS, STORE, STORE_ORDER, PACK_SECTIONS = {}, {}, {}, {}
    -- the online product list (last good download) replaces the shipped copy
    loadStoreFile(fileExists(CATALOG_CACHE) and CATALOG_CACHE or STORE_FILE)
    for _, entry in ipairs(listDir(PACKS_DIR .. "/*")) do
        if safeName(entry.name) and fileExists(PACKS_DIR .. "/" .. entry.name .. "/pack.txt") then
            local pack = readPack(entry.name)
            if pack and #pack.effects > 0 then PACKS[#PACKS + 1] = pack end
        end
    end
    table.sort(PACKS, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.name:lower() < b.name:lower()
    end)
end

local function ownsProduct(product)
    if product.kind == "module" then return fileExists(MODULE_DIR .. "/" .. product.id .. ".hubmodule") end
    return fileExists(PACKS_DIR .. "/" .. product.id .. "/pack.txt")
end

--------------------------------------------------------------------
-- Catalogue
--------------------------------------------------------------------

-- "Zoom Pre" and "Zoom Post" are two variants of one effect; the base name is
-- what the list shows and the buttons choose between.
local function splitVariant(name)
    local base = name:match("^(.-)%s+Pre$")
    if base then return base, "PRE" end
    base = name:match("^(.-)%s+Post$")
    if base then return base, "POST" end
    return name, "ONLY"
end

local animationCache = {}
local function loadAnimation(folder)
    local f = io.open(folder .. "/animation.txt", "r")
    if not f then return nil end
    local count, fps = tonumber(f:read("*l")), tonumber(f:read("*l")); f:close()
    if not count or count < 1 or count > 6000 or not fps or fps <= 0 or fps > 120 then return nil end
    if animationCache[folder] then return animationCache[folder] end
    local frames = {}
    for i = 1, count do
        local path = folder .. "/" .. string.format("frame%03d.png", i)
        if not fileExists(path) then return nil end
        frames[i] = ui:Icon{ File = path }
    end
    local animation = { frames = frames, fps = fps, count = count }
    animationCache[folder] = animation
    return animation
end

local CATALOGUE, CATEGORIES = {}, {}

local function buildCatalogue()
    CATALOGUE, CATEGORIES = {}, {}
    local seenName, seenCat = {}, {}
    for _, pack in ipairs(PACKS) do
        for _, e in ipairs(pack.effects) do
            if not seenName[e.name:lower()] then
                seenName[e.name:lower()] = true
                local base, variant = splitVariant(e.name)
                local png = pack.dir .. "/" .. e.name .. ".png"
                local gif = pack.dir .. "/" .. e.name .. ".gif"
                local fallback = pack.dir .. "/Previews/" .. base .. ".png"
                if not fileExists(png) and fileExists(fallback) then png = fallback end
                local effect = {
                    name = e.name, base = base, cat = variant, category = e.category,
                    kind = e.kind, pack = pack,
                    animation = loadAnimation(pack.dir .. "/Animations/" .. e.name),
                    preview = fileExists(gif) and gif or (fileExists(png) and png or nil),
                    thumb = fileExists(png) and png or nil,
                }
                if e.kind == "clip" then
                    effect.clip = true
                    effect.setting = pack.dir .. "/ClipFX/" .. e.name .. ".setting"
                elseif e.kind == "media" then
                    local rel = e.extra or ""
                    local okPath = rel ~= "" and not rel:find("%.%.") and not rel:find("^[/\\]") and not rel:find(":")
                    effect.media = okPath and (pack.dir .. "/" .. rel) or nil
                end
                CATALOGUE[#CATALOGUE + 1] = effect
                if not seenCat[e.category] then
                    seenCat[e.category] = true
                    CATEGORIES[#CATEGORIES + 1] = e.category
                end
            end
        end
    end
    local seen = {}
    for i, c in ipairs(CATEGORIES) do seen[c] = i end
    table.sort(CATEGORIES, function(a, b)
        local sa, sb = sectionRank(sectionOf(a)), sectionRank(sectionOf(b))
        if sa ~= sb then return sa < sb end
        local ra, rb = CATEGORY_RANK[a] or (100 + seen[a]), CATEGORY_RANK[b] or (100 + seen[b])
        return ra < rb
    end)
end

-- Ordered, de-duplicated effect names (one per Pre/Post pair).
local BASES = {}
local function rebuildBases()
    BASES = {}
    local seen = {}
    for _, effect in ipairs(CATALOGUE) do
        if not seen[effect.base] then
            seen[effect.base] = true
            BASES[#BASES + 1] = effect.base
        end
    end
end

--------------------------------------------------------------------
-- Favourites
--------------------------------------------------------------------

local favourites = {}
local function loadFavourites()
    favourites = {}
    local f = io.open(FAV_FILE, "r")
    if not f then return end
    for line in f:lines() do
        line = trim((line:gsub("\r$", "")))
        if line ~= "" then favourites[line] = true end
    end
    f:close()
end
local function saveFavourites()
    local f = io.open(FAV_FILE, "w")
    if not f then return end
    local names = {}
    for name in pairs(favourites) do names[#names + 1] = name end
    table.sort(names)
    f:write(table.concat(names, "\n"))
    f:close()
end

--------------------------------------------------------------------
-- Resolve helpers
--------------------------------------------------------------------

local function currentTimeline()
    local pm = resolve:GetProjectManager()
    local proj = pm and pm:GetCurrentProject()
    return proj and proj:GetCurrentTimeline(), proj
end

local function findFolder(folder, name)
    if folder:GetName() == name then return folder end
    for _, sub in ipairs(folder:GetSubFolderList()) do
        local hit = findFolder(sub, name)
        if hit then return hit end
    end
end

local function childFolder(folder, name)
    for _, sub in ipairs(folder:GetSubFolderList()) do
        if sub:GetName() == name then return sub end
    end
end

-- Everything the Hub adds to a project lives in ONE top-level bin, "2WIN VFX Hub",
-- with a sub-bin per pack (named after the pack). Hubs before 1.7 made a top-level
-- "2WIN VFX Hub - <pack>" bin per pack; tidyBins moves those inside (folders can't
-- be renamed by script, so they keep their old names there).
local Bins = { HUB = "2WIN VFX Hub", LEGACY = "2WIN VFX Hub - " }

function Bins.hub(mp, create)
    local root = mp:GetRootFolder()
    local f = childFolder(root, Bins.HUB)
    if not f and create then f = mp:AddSubFolder(root, Bins.HUB) end
    return f
end

-- Every folder that may hold this pack's presets: its sub-bin in the Hub bin, a tidied
-- legacy bin, or a legacy bin still loose in the media pool.
function Bins.folders(mp, pack)
    local out, hub = {}, Bins.hub(mp, false)
    if hub then
        out[#out + 1] = childFolder(hub, pack.name)
        out[#out + 1] = pack.bin ~= pack.name and childFolder(hub, pack.bin) or nil
    end
    if #out == 0 then out[#out + 1] = findFolder(mp:GetRootFolder(), pack.bin) end
    return out
end

function Bins.pack(mp, pack, create)
    local f = Bins.folders(mp, pack)[1]
    if not f and create then
        local hub = Bins.hub(mp, true)
        f = hub and mp:AddSubFolder(hub, pack.name)
    end
    return f
end

function Bins.tidy(proj)
    local mp = proj:GetMediaPool()
    local loose = {}
    for _, sub in ipairs(mp:GetRootFolder():GetSubFolderList()) do
        if sub:GetName():sub(1, #Bins.LEGACY) == Bins.LEGACY then loose[#loose + 1] = sub end
    end
    if #loose == 0 then return 0 end
    local hub = Bins.hub(mp, true)
    return (hub and mp:MoveFolders(loose, hub)) and #loose or 0
end

-- A pack whose pack.txt carries "presets = <stamp>" is imported into its own
-- sub-bin per stamp, so an updated presets.drb comes in fresh; older sub-bins stay
-- put for clips already on timelines.
local function stampFolderName(pack)
    return (pack.presets and pack.presets ~= "") and ("Presets " .. pack.presets) or nil
end

-- Every clip under each pack's bin, by lower-cased name. Pack bins are indexed
-- first, in pack order (the current stamp's sub-bin ahead of older ones), so they
-- win over loose duplicates elsewhere.
local presetIndex = {}
local stalePacks = {}      -- pack ids whose bin is in the project but not their current presets
                          -- (by id: RESCAN / startup re-read PACKS, effects keep older tables)

local function refreshPresets()
    presetIndex, stalePacks = {}, {}
    local _, proj = currentTimeline()
    if not proj then return presetIndex end
    local root = proj:GetMediaPool():GetRootFolder()
    local function collect(folder, generatorsOnly)
        for _, clip in ipairs(folder:GetClipList()) do
            if not generatorsOnly or clip:GetClipProperty("Type") == "Generator" then
                -- Names in the wild carry stray trailing spaces ("Flash Post ").
                local key = trim(clip:GetName()):lower()
                if not presetIndex[key] then presetIndex[key] = clip end
            end
        end
        for _, sub in ipairs(folder:GetSubFolderList()) do collect(sub, generatorsOnly) end
    end
    local mp = proj:GetMediaPool()
    for _, pack in ipairs(PACKS) do
        local folders = Bins.folders(mp, pack)
        local stamp = stampFolderName(pack)
        local current
        for _, f in ipairs(folders) do current = current or (stamp and childFolder(f, stamp)) end
        if current then collect(current, false) end
        for _, f in ipairs(folders) do collect(f, false) end
        if #folders > 0 and stamp and not current then stalePacks[pack.id] = true end
    end
    collect(root, true)
    return presetIndex
end

-- Imports a pack's presets into its sub-bin of the Hub bin, only when they're missing or
-- out of date. Called with the pack of the effect being placed (1.7+: nothing is imported
-- just by opening the Hub). Idempotent.
local function importPacks(proj, only)
    local mp = proj:GetMediaPool()
    local root, previous = mp:GetRootFolder(), mp:GetCurrentFolder()
    local messages, imported = {}, false
    for _, pack in ipairs(PACKS) do
      if not only or pack.id == only.id then
        local needed = {}
        for _, e in ipairs(pack.effects) do
            if e.kind == "preset" then needed[#needed + 1] = e.name:lower() end
        end
        if #needed > 0 then
            local existing = Bins.pack(mp, pack, false)
            local stamp = stampFolderName(pack)
            local target = existing
            if existing and stamp then target = childFolder(existing, stamp) end
            local have = {}
            if target then
                local function walk(f)
                    for _, clip in ipairs(f:GetClipList()) do have[trim(clip:GetName()):lower()] = true end
                    for _, sub in ipairs(f:GetSubFolderList()) do walk(sub) end
                end
                walk(target)
            end
            local complete = true
            for _, n in ipairs(needed) do if not have[n] then complete = false end end
            if not complete then
                if not fileExists(pack.drbPath) then
                    messages[#messages + 1] = pack.name .. ": presets file missing, reinstall the pack"
                else
                    local dest = existing or Bins.pack(mp, pack, true)
                    if dest and stamp then dest = target or mp:AddSubFolder(dest, stamp) end
                    if dest and mp:SetCurrentFolder(dest) and mp:ImportFolderFromFile(pack.drbPath) then
                        imported = true
                        messages[#messages + 1] = pack.name .. " ready"
                    else
                        messages[#messages + 1] = pack.name .. ": import failed"
                    end
                end
            end
        end
      end
    end
    if previous then mp:SetCurrentFolder(previous) end
    return imported, #messages > 0 and table.concat(messages, " | ") or "All packs ready"
end

--------------------------------------------------------------------
-- Grouping
--------------------------------------------------------------------

-- Dense list on purpose: ipairs over { only, pre, post } stops at the first nil.
local function variantsOf(group)
    local out = {}
    if group.pre  then out[#out + 1] = group.pre  end
    if group.post then out[#out + 1] = group.post end
    if group.only then out[#out + 1] = group.only end
    return out
end

local GROUPS = {}

local function buildGroups()
    local byBase, order = {}, {}
    for _, effect in ipairs(CATALOGUE) do
        local g = byBase[effect.base]
        if not g then
            g = { base = effect.base, type = effect.category }
            byBase[effect.base] = g
            order[#order + 1] = g
        end
        if     effect.cat == "PRE"  then g.pre  = effect
        elseif effect.cat == "POST" then g.post = effect
        else                             g.only = effect end
    end
    for _, g in ipairs(order) do
        local any = g.only or g.post or g.pre
        g.animation = loadAnimation(any.pack.dir .. "/Animations/_Groups/" .. g.base) or any.animation
        g.thumb   = any.thumb
        g.preview = any.preview
        g.pack    = any.pack
    end
    local rank = {}
    for i, c in ipairs(CATEGORIES) do rank[c] = i end
    table.sort(order, function(a, b)
        local ra, rb = rank[a.type] or 999, rank[b.type] or 999
        if ra ~= rb then return ra < rb end
        return displayName(a.base):lower() < displayName(b.base):lower()
    end)
    GROUPS = order
end

--------------------------------------------------------------------
-- Placing an effect
--------------------------------------------------------------------

-- endFrame is counted in the preset's OWN frame rate, and Resolve conforms
-- the result to the timeline's. Nothing reports that ratio, so the real
-- timeline length is measured on first use and remembered here.
local trueLength = {}

-- A Post on a short clip is trimmed to the clip, but never below this many
-- frames: shakes, distortions etc. squeezed any shorter look rushed.
local POST_MIN = 6
-- FIT TO CLIP (lyrics) never makes a text animation shorter than this.
local FIT_MIN = 12

local function place(mp, item, trackIndex, at, length, startFrame)
    local added = mp:AppendToTimeline({ {
        mediaPoolItem = item,
        startFrame    = startFrame or 0,
        endFrame      = (startFrame or 0) + length,
        trackIndex    = trackIndex,
        recordFrame   = at,
        mediaType     = 1,
    } })
    return added and added[1]
end

-- A generator placed by script is named "Adjustment Clip" on the timeline; give
-- it the preset's name (pcall: TimelineItem:SetName is missing in older Resolve).
local function nameClip(item, name)
    if item then pcall(function() item:SetName(name) end) end
end

-- The selected clip, plus the track it sits on.
local function findTarget(tl)
    -- Footage resolves to a media pool item; an effect clip on the timeline
    -- never does, which makes this the dependable "is it our clip" test.
    local function isGenerator(item)
        return item ~= nil and item:GetMediaPoolItem() == nil
    end

    -- Highlighted FOOTAGE is the target. Highlighted effect clips are ignored (they are
    -- usually just left selected from before): with no footage highlighted, the clip
    -- under the playhead is used. (1.7.2: they used to be mapped to the footage under
    -- each one, so a highlighted Pre + Post pair placed the effect on two shots.)
    local picks = {}
    -- ipairs, not pairs: Resolve's Lua lists carry an extra "__flags" key.
    local sel = tl:GetSelectedClips()
    if sel then for _, c in ipairs(sel) do if not isGenerator(c) then picks[#picks + 1] = c end end end
    if #picks == 0 then
        local cur = tl:GetCurrentVideoItem()
        if cur then picks = { cur } end
    end
    if #picks == 0 then return nil, "Select a clip on the timeline first." end

    -- A second apply would otherwise target the effect clip just placed.
    local base = {}
    for _, clip in ipairs(picks) do
        if isGenerator(clip) then
            local s, e = math.floor(clip:GetStart()), math.floor(clip:GetEnd())
            local under
            for tr = 1, tl:GetTrackCount("video") do
                for _, item in ipairs(tl:GetItemListInTrack("video", tr)) do
                    if not under and not isGenerator(item)
                       and item:GetStart() <= s and item:GetEnd() >= e then
                        under = item
                    end
                end
            end
            clip = under or clip
        end
        base[#base + 1] = clip
    end

    local out, seen = {}, {}
    for _, clip in ipairs(base) do
        local id, nm = clip:GetUniqueId(), clip:GetName()
        if seen[id] then goto nextclip end   -- each shot once, however it was picked
        seen[id] = true
        local s, e = math.floor(clip:GetStart()), math.floor(clip:GetEnd())
        local track
        for tr = 1, tl:GetTrackCount("video") do
            for _, item in ipairs(tl:GetItemListInTrack("video", tr)) do
                if item:GetUniqueId() == id
                   or (item:GetName() == nm and math.floor(item:GetStart()) == s) then
                    track = track or tr
                end
            end
        end
        if track then out[#out + 1] = { item = clip, track = track, s = s, e = e } end
        ::nextclip::
    end
    if #out == 0 then return nil, "Could not locate the selected clip's track." end
    return out
end

-- Lowest track above the clip that is clear across the span.
local function destinationTrack(tl, fromTrack, s, e)
    for tr = fromTrack + 1, tl:GetTrackCount("video") do
        local clear = true
        for _, item in ipairs(tl:GetItemListInTrack("video", tr)) do
            if item:GetStart() < e and item:GetEnd() > s then clear = false break end
        end
        if clear then return tr end
    end
    if not tl:AddTrack("video") then return nil end
    return tl:GetTrackCount("video")
end

-- Clip-level effects: duplicate the shot, effect on the copy. A multicam
-- re-appended from the pool lands on Angle 1, so the timeline is duplicated
-- in the background, the twin of the shot flattened there, and its media +
-- left offset used; the temp timeline is then deleted.
local function angleSource(tl, proj, shot, track)
    local mp = proj:GetMediaPool()
    local twin = tl:DuplicateTimeline("2WIN VFX Hub Flatten (temp)")
    if not twin then return nil, nil, "could not duplicate the timeline to flatten" end
    local s = math.floor(shot:GetStart())
    local media, left, err
    for _, item in ipairs(twin:GetItemListInTrack("video", track)) do
        if math.floor(item:GetStart()) == s then
            if item:FlattenMulticam(resolve.FLATTEN_MULTICAM_RETAIN_GRADE_FROM_ANGLE) then
                for _, flat in ipairs(twin:GetItemListInTrack("video", track)) do
                    if math.floor(flat:GetStart()) == s then
                        media, left = flat:GetMediaPoolItem(), flat:GetLeftOffset()
                    end
                end
            end
        end
    end
    if not media then err = "could not flatten the multicam angle" end
    proj:SetCurrentTimeline(tl)
    mp:DeleteTimelines({ twin })
    return media, left, err
end

local function applyClipEffect(effect, targetsOverride)
    local tl, proj = currentTimeline()
    if not tl then return "No timeline is open." end
    if not fileExists(effect.setting) then return "Failed: " .. effect.name .. " is missing from its pack" end
    local targets, err = targetsOverride, nil
    if not targets then
        targets, err = findTarget(tl)
        if not targets then return err end
    end
    local mp = proj:GetMediaPool()
    local playhead = tl:GetCurrentTimecode()
    local isPre = (effect.cat == "PRE")
    local placed, failed = 0, nil
    -- effect.direct: the comp goes straight onto the selected clip, no duplicate.
    -- A comp that fails to load is removed again; the clip itself is never deleted.
    if effect.direct then
        for _, t in ipairs(targets) do
            local shot = t.item
            if not (shot and shot:GetMediaPoolItem()) then
                failed = "select a video clip (not an effect clip)"
            else
                local before = {}
                for _, n in ipairs(shot:GetFusionCompNameList() or {}) do before[n] = true end
                local comp = shot:ImportFusionComp(effect.setting)
                local macro
                if comp then
                    for _, tool in pairs(comp:GetToolList(false)) do
                        if type(tool) ~= "number" and tool.ID == "MacroOperator" then macro = tool end
                    end
                end
                if not macro then
                    for _, n in ipairs(shot:GetFusionCompNameList() or {}) do
                        if not before[n] then shot:DeleteFusionCompByName(n) end
                    end
                    failed = "could not load " .. effect.name
                else
                    local mediaIn  = comp:AddTool("MediaIn",  false, -100, 0)
                    local mediaOut = comp:AddTool("MediaOut", false,  400, 0)
                    mediaIn:SetInput("DeepOutputMode", 0)
                    macro:ConnectInput(macro:FindMainInput(1).ID, mediaIn)
                    mediaOut:ConnectInput("Input", macro)
                    placed = placed + 1
                end
            end
        end
        if playhead then tl:SetCurrentTimecode(playhead) end
        if placed == 0 then return "Failed: " .. (failed or "unknown error") end
        local msg = displayName(effect.name) .. " -> applied to " .. placed .. " clip" .. (placed == 1 and "" or "s")
        if failed then msg = msg .. "  (" .. (#targets - placed) .. " failed: " .. failed .. ")" end
        return msg
    end
    for _, t in ipairs(targets) do
        local shot = t.item
        if isPre then
            shot = nil
            for _, item in ipairs(tl:GetItemListInTrack("video", t.track)) do
                if math.floor(item:GetEnd()) == t.s and item:GetMediaPoolItem() then shot = item end
            end
        end
        local mpi = shot and shot:GetMediaPoolItem()
        if not shot then
            failed = "no shot ends at this cut"
        elseif not mpi then
            failed = "that clip has no source media to duplicate"
        else
            local s, e  = math.floor(shot:GetStart()), math.floor(shot:GetEnd())
            local left  = shot:GetLeftOffset()
            local track = t.track
            for tr = 1, tl:GetTrackCount("video") do
                for _, item in ipairs(tl:GetItemListInTrack("video", tr)) do
                    if item:GetUniqueId() == shot:GetUniqueId() then track = tr end
                end
            end
            if mpi:GetClipProperty("Type") == "Multicam" then
                local why
                mpi, left, why = angleSource(tl, proj, shot, track)
                if not mpi then failed = why end
            end
            local dest = mpi and destinationTrack(tl, track, s, e)
            local copy
            if dest then
                -- Source frames count at the file's own rate, so a file at another rate
                -- than the timeline (24 on 23.976, 30 on 29.97...) lands a frame off.
                -- Place, measure against the original, nudge, retry (2 tries typical).
                local k = (tonumber(mpi:GetClipProperty("FPS")) or 0) / (tonumber(tl:GetSetting("timelineFrameRate")) or 0)
                if not (k > 0 and k < 1000) then k = 1 end
                local sf, ef = left * k, (left + e - s) * k
                for _ = 1, 4 do
                    copy = place(mp, mpi, dest, s, ef - sf, sf)
                    if not copy or copy:GetStart() == nil then copy = nil break end
                    local gs, ge, gl = math.floor(copy:GetStart()), math.floor(copy:GetEnd()), copy:GetLeftOffset()
                    if gs == s and ge == e and gl == left then break end
                    tl:DeleteClips({ copy }, false); copy = nil
                    local dl = left - gl
                    sf = sf + dl * k
                    ef = ef + (dl + (e - ge) - (s - gs)) * k
                end
            end
            if not mpi then
                -- already reported
            elseif not dest then
                failed = "could not free up a track above"
            elseif not copy then
                failed = "could not line the duplicate up with the original"
            elseif copy:GetLeftOffset() ~= left or math.floor(copy:GetStart()) ~= s
                   or math.floor(copy:GetEnd()) ~= e then
                tl:DeleteClips({ copy }, false)
                failed = "duplicate did not line up with the original"
            else
                local comp = copy:ImportFusionComp(effect.setting)
                local macro
                if comp then
                    for _, tool in pairs(comp:GetToolList(false)) do
                        if type(tool) ~= "number" and tool.ID == "MacroOperator" then macro = tool end
                    end
                end
                if not macro then
                    tl:DeleteClips({ copy }, false)
                    failed = "could not load " .. effect.name
                else
                    local mediaIn  = comp:AddTool("MediaIn",  false, -100, 0)
                    local mediaOut = comp:AddTool("MediaOut", false,  400, 0)
                    mediaIn:SetInput("DeepOutputMode", 0)
                    macro:ConnectInput(macro:FindMainInput(1).ID, mediaIn)
                    mediaOut:ConnectInput("Input", macro)
                    placed = placed + 1
                end
            end
        end
    end
    if playhead then tl:SetCurrentTimecode(playhead) end
    if placed == 0 then return "Failed: " .. (failed or "unknown error") end
    local msg = displayName(effect.name) .. " -> duplicated " .. placed .. " clip"
                .. (placed == 1 and "" or "s") .. ", original untouched"
    if failed then msg = msg .. "  (" .. (#targets - placed) .. " failed: " .. failed .. ")" end
    return msg
end

-- The media item for a "media" effect, imported into its pack's bin once.
local function mediaItem(effect, proj)
    local key = effect.name:lower()
    if presetIndex[key] then return presetIndex[key] end
    if not effect.media or not fileExists(effect.media) then return nil end
    local mp = proj:GetMediaPool()
    local root, previous = mp:GetRootFolder(), mp:GetCurrentFolder()
    local bin = Bins.pack(mp, effect.pack, true)
    local item
    if bin and mp:SetCurrentFolder(bin) then
        local added = mp:ImportMedia({ effect.media })
        item = added and added[1]
        if item then item:SetClipProperty("Clip Name", effect.name) end
    end
    if previous then mp:SetCurrentFolder(previous) end
    if item then presetIndex[key] = item end
    return item
end

-- targetsOverride lets Auto VFX drive this per cut.
local function applyEffect(effect, targetsOverride)
    if effect.clip then return applyClipEffect(effect, targetsOverride) end

    local tl, proj = currentTimeline()
    if not tl then return "No timeline is open." end

    local preset
    if effect.kind == "media" then
        refreshPresets()
        preset = mediaItem(effect, proj)
        if not preset then return "Failed: " .. effect.name .. " media is missing from its pack" end
    else
        preset = refreshPresets()[effect.name:lower()]
        -- First use in a project, or an updated pack: pull the packs in automatically.
        if not preset or (effect.pack and stalePacks[effect.pack.id]) then
            if importPacks(proj, effect.pack) then preset = refreshPresets()[effect.name:lower()] end
        end
        if not preset then
            return "Failed: no preset named '" .. effect.name .. "' - reinstall " .. (effect.pack and effect.pack.name or "the pack")
        end
    end

    local targets, err = targetsOverride, nil
    if not targets then
        targets, err = findTarget(tl)
        if not targets then return err end
    end

    local mp = proj:GetMediaPool()
    local placed, failed, dropped = 0, nil, nil
    -- Each preset keeps its designed duration.
    local natural = tonumber(preset:GetClipProperty("Frames"))
    local playhead = tl:GetCurrentTimecode()
    -- A Pre runs out exactly where the clip starts; a Post starts at its head.
    local isPre = (effect.cat == "PRE")
    local key  = effect.name:lower()
    local full = (natural and natural > 0) and natural or nil
    local function lengthOf(item) return math.floor(item:GetEnd()) - math.floor(item:GetStart()) end

    -- effect.place (titles, lyrics, overlays) instead of Pre/Post:
    --   START    at the clip's head, own length       PLAYHEAD at the playhead, own length
    --   ONCUT    centred on the cut at the clip's head FULL     at the head, trimmed to the clip
    local mode = effect.place
    local function anchor(t, len)
        if mode == "PLAYHEAD" then return t.playhead end
        if mode == "ONCUT" then return t.s - math.floor(len / 2) end
        if mode then return t.s end
        return isPre and (t.s - len) or t.s
    end

    for _, t in ipairs(targets) do
        local span = t.e - t.s
        local expect = trueLength[key] or full or span
        local request = full or span
        if mode == "FULL" then
            if expect > span then
                request = math.max(1, math.floor(span * request / expect + 0.5)); expect = span
            end
        elseif mode == "FIT" then
            -- exactly the clip (the 2WIN text animations re-time to any length),
            -- but never squeezed under FIT_MIN frames
            local want = math.max(span, FIT_MIN)
            request = math.max(1, math.floor(want * request / expect + 0.5)); expect = want
        elseif not mode then
            -- a Post fits its clip, but squeezed under POST_MIN frames it looks rushed
            if not isPre and expect > span then expect = math.max(span, math.min(expect, POST_MIN)) end
            if trueLength[key] and expect < trueLength[key] then
                request = math.max(1, math.floor(expect * request / trueLength[key] + 0.5))
            end
        end
        local at = anchor(t, expect)
        if not at then
            failed = "could not read the playhead"
        elseif at < tl:GetStartFrame() then
            failed = isPre and "not enough footage before this cut" or "not enough room before this cut"
        else
            local dest = destinationTrack(tl, t.track, at, at + expect)
            if not dest then
                failed = "could not free up a track above"
            else
                local item = place(mp, preset, dest, at, request)
                if not item then
                    failed = "Resolve refused to place the clip"
                else
                    local got = lengthOf(item)
                    if request == full then trueLength[key] = got end
                    -- On first use the real length was unknown, so a Pre (or a
                    -- centred overlay) may have landed off: put it where it belongs.
                    local fixed = anchor(t, got)
                    if (isPre or mode == "ONCUT") and fixed ~= at then
                        tl:DeleteClips({ item }, false)
                        if fixed < tl:GetStartFrame() then
                            item = nil
                            failed = "not enough footage before this cut"
                        else
                            item = place(mp, preset, dest, fixed, request)
                            if item then got = lengthOf(item)
                            else failed = "Resolve refused the corrected placement" end
                        end
                    end
                    -- A Post (or FULL CLIP overlay) longer than the clip: on first use its
                    -- real length wasn't known, so trim it to the clip like later uses are
                    -- (a Post not below POST_MIN frames).
                    -- FIT TO CLIP likewise lands exactly on the clip (FIT_MIN at least).
                    local want = (mode == "FULL") and span or (mode == "FIT") and math.max(span, FIT_MIN)
                                 or math.max(span, math.min(got, POST_MIN))
                    if item and (((not mode and not isPre) or mode == "FULL") and got > want
                                 or mode == "FIT" and got ~= want) then
                        tl:DeleteClips({ item }, false)
                        item = place(mp, preset, dest, at, math.max(1, math.floor(want * request / got + 0.5)))
                        if item then got = lengthOf(item)
                        else failed = "Resolve refused the trimmed placement" end
                    end
                    if item then placed = placed + 1; dropped = got; nameClip(item, effect.name) end
                end
            end
        end
    end

    if playhead then tl:SetCurrentTimecode(playhead) end
    if placed == 0 then return "Failed: " .. (failed or "unknown error") end
    local msg = displayName(effect.name) .. " -> " .. (dropped or natural or "?") .. "f on "
                .. placed .. " clip" .. (placed == 1 and "" or "s")
    if failed then msg = msg .. "  (" .. (#targets - placed) .. " failed)" end
    return msg
end

-- The playhead as a timeline frame number (the same numbering as GetStart).
local function playheadFrame(tl)
    local tc = tl:GetCurrentTimecode() or ""
    local h, m, s, f = tc:match("^(%d+)[:;](%d+)[:;](%d+)[:;.](%d+)$")
    if not h then return nil end
    local base = math.floor((tonumber(tl:GetSetting("timelineFrameRate")) or 24) + 0.5)
    local minutes = tonumber(h) * 60 + tonumber(m)
    local frames = (minutes * 60 + tonumber(s)) * base + tonumber(f)
    if tc:find(";") then   -- drop-frame timecode skips frame numbers every minute but each tenth
        frames = frames - math.floor(base / 15) * (minutes - math.floor(minutes / 10))
    end
    return frames
end

-- Placement actions besides PRE / BOTH / POST (see placementMode):
--   START PLAYHEAD ONCUT FULL  - titles, lyrics, overlays at their own length
--   DUPLICATE DIRECT           - clip FX on a duplicate of the shot, or on the shot itself
--   FIT                        - lyrics: the head of the clip to its end, stretched or squeezed
local PLACE_ACTIONS = { START = true, PLAYHEAD = true, ONCUT = true, FULL = true, FIT = true }

-- "Both" is the two variants in sequence; each anchors itself.
local function applyGroup(group, which, targetsOverride)
    local wanted = {}
    if PLACE_ACTIONS[which] or which == "DUPLICATE" or which == "DIRECT" then
        local src = group.only or group.post or group.pre
        local effect = {}
        for k, v in pairs(src) do effect[k] = v end
        if which == "DUPLICATE" or which == "DIRECT" then
            if not effect.clip then return displayName(group.base) .. " is not a clip effect" end
            effect.direct, effect.cat = (which == "DIRECT"), "ONLY"
        else
            effect.place, effect.cat = which, "POST"
        end
        local tl = currentTimeline()
        if not tl then return "No timeline is open." end
        local targets, err = targetsOverride, nil
        if not targets then
            targets, err = findTarget(tl)
            if not targets then return err end
        end
        if which == "PLAYHEAD" then
            -- one placement, at the playhead, above the first target's track
            targets = { { item = targets[1].item, track = targets[1].track, s = targets[1].s, e = targets[1].e,
                          playhead = playheadFrame(tl) } }
        end
        return applyEffect(effect, targets)
    end
    if group.only and group.only.clip then
        -- a clip effect without Pre/Post variants works on the selected clip
        -- itself, whichever apply button was used
        wanted[1] = group.only
    elseif group.only then
        for _, side in ipairs(which == "BOTH" and { "PRE", "POST" } or { which }) do
            local effect = {}
            for k, v in pairs(group.only) do effect[k] = v end
            effect.cat = side
            wanted[#wanted + 1] = effect
        end
    else
        if (which == "PRE"  or which == "BOTH") and group.pre  then wanted[#wanted + 1] = group.pre  end
        if (which == "POST" or which == "BOTH") and group.post then wanted[#wanted + 1] = group.post end
    end
    if #wanted == 0 then return displayName(group.base) .. " has no " .. which:lower() .. " variant" end
    local tl = currentTimeline()
    if not tl then return "No timeline is open." end
    -- Capture the targets once: PRE can change Resolve's selection.
    local targets, err = targetsOverride, nil
    if not targets then
        targets, err = findTarget(tl)
        if not targets then return err end
    end
    local parts = {}
    for _, effect in ipairs(wanted) do parts[#parts + 1] = applyEffect(effect, targets) end
    return table.concat(parts, "   |   ")
end

--------------------------------------------------------------------
-- Add-on modules (our own code, installed by the add-on's installer)
--------------------------------------------------------------------

local MODULES = {}
local function loadModules()
    MODULES = {}
    for _, entry in ipairs(listDir(MODULE_DIR .. "/*.hubmodule")) do
        local id = entry.name:match("^(.-)%.hubmodule$")
        if id and safeName(id) then
            local chunk = loadfile(MODULE_DIR .. "/" .. entry.name)
            local ok, mod = false, nil
            if chunk then ok, mod = pcall(chunk) end
            if ok and type(mod) == "table" and type(mod.build) == "function" then
                mod.id = id
                MODULES[#MODULES + 1] = mod
            end
        end
    end
    table.sort(MODULES, function(a, b) return (a.order or 100) < (b.order or 100) end)
end

--------------------------------------------------------------------
-- Startup data
--------------------------------------------------------------------

discoverPacks()
buildCatalogue()
rebuildBases()
loadFavourites()
loadModules()

--------------------------------------------------------------------
-- Interface
--------------------------------------------------------------------

local RED     = "#E0242B"
local RED_DIM = "rgba(224,36,43,0.34)"
local BG      = "#0B0B0D"
local PANEL   = "#141418"

-- Row visuals use padding, not margins: margins on QTreeWidget::item are not
-- added to the row height, so icons get clipped once the list scrolls.
local STYLE = [[
    QWidget { background-color: ]] .. BG .. [[; color: #EDEDED;
              font-family: "Inter","Segoe UI",sans-serif; font-size: 13px; }
    QLineEdit { background-color: ]] .. PANEL .. [[; border: 1px solid ]] .. RED_DIM .. [[;
                border-radius: 16px; padding: 10px 16px; color: #EDEDED; font-size: 14px; }
    QLineEdit:focus { border: 1px solid ]] .. RED .. [[; }
    QPushButton { background-color: ]] .. PANEL .. [[; border: 1px solid ]] .. RED_DIM .. [[;
                  border-radius: 12px; padding: 9px 12px;
                  color: #C9C9CF; font-weight: 600; letter-spacing: 1px; }
    QPushButton:hover   { border: 1px solid ]] .. RED .. [[; color: ]] .. RED .. [[; }
    QPushButton:pressed { background-color: #1D1D22; }
    QPushButton:checked { border: 1px solid ]] .. RED .. [[; color: ]] .. RED .. [[;
                          background-color: #1A1013; }
    QTreeWidget { background-color: ]] .. BG .. [[; border: none; outline: none;
                  show-decoration-selected: 0; }
    QTreeWidget::item { background-color: ]] .. PANEL .. [[;
                        border: 1px solid ]] .. RED_DIM .. [[; border-radius: 12px;
                        padding: 2px; color: ]] .. RED .. [[;
                        font-size: 15px; font-weight: 700; letter-spacing: 2px; }
    QTreeWidget::item:hover    { border: 1px solid ]] .. RED .. [[; background-color: #1A1013; }
    QTreeWidget::item:selected { border: 1px solid ]] .. RED .. [[; background-color: #251519;
                                 color: #FFFFFF; }
    QTreeWidget::branch { background-color: ]] .. BG .. [[; }
    QScrollBar:vertical { background: ]] .. BG .. [[; width: 10px; margin: 0; }
    QScrollBar::handle:vertical { background: #2C2C33; border-radius: 5px; min-height: 30px; }
    QScrollBar::handle:vertical:hover { background: ]] .. RED .. [[; }
    QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
    QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical { background: none; }
]]
local APPLY_STYLE = "font-size:15px; font-weight:800; letter-spacing:2px;"
local TAB_STYLE   = "font-size:13px; font-weight:800; letter-spacing:3px;"

-- Filters, two levels, all from the installed packs:
--   sections   ALL | EFFECTS | TEXT | CLIP FX | OVERLAYS | FAVS  (only those in use)
--   categories the chosen section's categories, four per row (hidden when a
--              section has just one); none picked = the whole section.
local SECTION_STYLE = "font-size:13px; font-weight:800; letter-spacing:2px;"
local FILTERS, SECTION_BUTTONS, SECTION_GROUP, SECTION_CATS = {}, {}, {}, {}

local function presentSections()
    local seen, list = {}, {}
    for _, cat in ipairs(CATEGORIES) do seen[sectionOf(cat)] = true end
    for _, s in ipairs(SECTION_ORDER) do if seen[s] then list[#list + 1] = s; seen[s] = nil end end
    for _, cat in ipairs(CATEGORIES) do
        local s = sectionOf(cat)
        if seen[s] then list[#list + 1] = s; seen[s] = nil end
    end
    return list
end

local function categoryRows(cats)
    local rows = {}
    for first = 1, #cats, 4 do
        local row = { Spacing = 6, Weight = 0, MinimumSize = { 0, 36 } }
        for i = first, math.min(first + 3, #cats) do
            row[#row + 1] = ui:Button{ ID = cats[i].id, Text = cats[i].label, Checkable = true }
        end
        rows[#rows + 1] = ui:HGroup(row)
    end
    return rows
end

local function filterRows()
    FILTERS, SECTION_BUTTONS, SECTION_GROUP, SECTION_CATS = {}, {}, {}, {}
    local sections = presentSections()
    local buttons = { { id = "SecAll", sec = "ALL", label = "ALL" } }
    for i, s in ipairs(sections) do buttons[#buttons + 1] = { id = "Sec" .. i, sec = s, label = s } end
    buttons[#buttons + 1] = { id = "SecFav", sec = "FAV", label = "FAVS" }
    local top = { ID = "SectionRow", Spacing = 6, Weight = 0, MinimumSize = { 0, 42 } }
    for _, b in ipairs(buttons) do
        SECTION_BUTTONS[#SECTION_BUTTONS + 1] = b
        top[#top + 1] = ui:Button{ ID = b.id, Text = b.label, Checkable = true, Checked = (b.sec == "ALL"),
                                   StyleSheet = SECTION_STYLE }
    end
    local groups = { ID = "FilterRows", Weight = 0, Spacing = 6 }
    for si, s in ipairs(sections) do
        local cats = {}
        for i, cat in ipairs(CATEGORIES) do
            if sectionOf(cat) == s then
                local f = { id = "FiltCat" .. i, cat = cat, label = cat, sec = s }
                cats[#cats + 1] = f; FILTERS[#FILTERS + 1] = f
            end
        end
        SECTION_GROUP[s], SECTION_CATS[s] = "SecCats" .. si, #cats
        local g = categoryRows(cats)
        g.ID, g.Weight, g.Spacing, g.Hidden = "SecCats" .. si, 0, 6, true
        groups[#groups + 1] = ui:VGroup(g)
    end
    return ui:VGroup{ Weight = 0, Spacing = 6, ui:HGroup(top), ui:VGroup(groups) }
end

-- Context handed to add-on modules: everything they may use, nothing more.
local win, itm
local ctx = {
    ui = ui, disp = disp,
    groups = function() return GROUPS end,
    bases = function() return BASES end,
    displayName = displayName,
    sectionOf = sectionOf,
    applyEffect = applyEffect,
    currentTimeline = currentTimeline,
    items = function() return itm end,
    window = function() return win end,
    setStatus = function(text) if itm then itm.Status.Text = text end end,
    colors = { red = RED, dim = RED_DIM, bg = BG, panel = PANEL },
}

local moduleSections = {}
for _, mod in ipairs(MODULES) do
    local ok, element = pcall(mod.build, ui, ctx)
    if ok and element then
        mod.sectionId = "ModSection_" .. mod.id:gsub("[^%w]", "_")
        mod.tabId = "ModTab_" .. mod.id:gsub("[^%w]", "_")
        moduleSections[#moduleSections + 1] = ui:VGroup{ ID = mod.sectionId, Weight = 1, Hidden = true, element }
    else
        mod.failed = true
    end
end

local tabRow = { Spacing = 6, Weight = 0, MinimumSize = { 0, 38 },
    ui:Button{ ID = "TabFx", Text = "LIBRARY", Checkable = true, Checked = true, StyleSheet = TAB_STYLE } }
for _, mod in ipairs(MODULES) do
    if not mod.failed then
        tabRow[#tabRow + 1] = ui:Button{ ID = mod.tabId, Text = (mod.title or mod.id):upper(), Checkable = true, StyleSheet = TAB_STYLE }
    end
end
tabRow[#tabRow + 1] = ui:Button{ ID = "TabStore", Text = "ADD-ONS && UPDATES", Checkable = true, StyleSheet = TAB_STYLE }

local effectsSection = ui:VGroup{
    ID = "FxSection", Weight = 1, Spacing = 6,
    ui:HGroup{ Weight = 0, Spacing = 6,
        ui:LineEdit{ ID = "Search", PlaceholderText = "Search effects...", Weight = 1,
                     MinimumSize = { 0, 40 }, Events = { TextChanged = true } },
        ui:Button{ ID = "PreviewToggle", Text = "PREVIEW ON", Checkable = true, Checked = true,
                   Weight = 0, MinimumSize = { 130, 40 }, ToolTip = "Show or hide the selected effect preview." },
    },
    filterRows(),
    -- IconSize is what drives row height, so it is set above the thumbnail size.
    ui:Tree{
        ID = "List", Weight = 1, MinimumSize = { 0, 220 },
        SortingEnabled = false, RootIsDecorated = false, ItemsExpandable = false,
        Alternating = false, HeaderHidden = true, Indentation = 0,
        IconSize = { 176, 99 }, UniformRowHeights = true, ColumnCount = 1,
        SelectionBehavior = "SelectRows",
        Events = { ItemClicked = true, ItemDoubleClicked = true, CurrentItemChanged = true },
    },
    ui:HGroup{ ID = "ApplyRow", Spacing = 8, Weight = 0, MinimumSize = { 0, 52 },
        ui:Button{ ID = "ApplyPre",  Text = "PRE",  MinimumSize = { 150, 48 }, StyleSheet = APPLY_STYLE },
        ui:Button{ ID = "ApplyBoth", Text = "BOTH", MinimumSize = { 180, 48 }, StyleSheet = APPLY_STYLE },
        ui:Button{ ID = "ApplyPost", Text = "POST", MinimumSize = { 150, 48 }, StyleSheet = APPLY_STYLE },
    },
    ui:HGroup{ Spacing = 6, Weight = 0, MinimumSize = { 0, 38 },
        ui:Button{ ID = "Fav",     Text = "FAVOURITE" },
        ui:Button{ ID = "Refresh", Text = "RESCAN", ToolTip = "Pick up newly installed packs and restore missing presets." },
    },
}

local storeSection = ui:VGroup{
    ID = "StoreSection", Weight = 1, Spacing = 8, Hidden = true,
    ui:Label{ Weight = 0, Alignment = { AlignHCenter = true }, WordWrap = true,
              Text = "<span style='color:#C9C9CF;font-size:13px;'>Expand the Hub with more packs and add-ons.<br>"
                  .. "Anything you install shows up here as INSTALLED and in your LIBRARY.</span>" },
    ui:Tree{
        ID = "StoreList", Weight = 1, MinimumSize = { 0, 200 },
        RootIsDecorated = false, HeaderHidden = true, Indentation = 0, ColumnCount = 2,
        SelectionBehavior = "SelectRows",
        Events = { ItemClicked = true, CurrentItemChanged = true, ItemDoubleClicked = true },
    },
    ui:Label{ ID = "StoreInfo", Weight = 0, MinimumSize = { 0, 60 }, WordWrap = true,
              Alignment = { AlignHCenter = true, AlignVCenter = true },
              StyleSheet = "color:#C9C9CF;font-size:13px;", Text = "Select a product to see what it adds." },
    ui:HGroup{ Spacing = 8, Weight = 0, MinimumSize = { 0, 52 },
        ui:Button{ ID = "StoreGet",   Text = "GET IT", MinimumSize = { 200, 48 }, StyleSheet = APPLY_STYLE },
        ui:Button{ ID = "StoreVisit", Text = "VISIT STORE", MinimumSize = { 200, 48 }, StyleSheet = APPLY_STYLE },
    },
    -- Hub updates
    ui:Label{ ID = "UpdateInfo", Weight = 0, MinimumSize = { 0, 44 }, WordWrap = true,
              Alignment = { AlignHCenter = true, AlignVCenter = true },
              StyleSheet = "color:#C9C9CF;font-size:13px;border-top:1px solid " .. RED_DIM .. ";padding-top:8px;",
              Text = "2WIN VFX Hub v" .. HUB_VERSION },
    ui:HGroup{ Spacing = 8, Weight = 0, MinimumSize = { 0, 44 },
        ui:Button{ ID = "UpdateCheck",   Text = "CHECK FOR UPDATES", MinimumSize = { 200, 40 } },
        ui:Button{ ID = "UpdateInstall", Text = "UPDATE", MinimumSize = { 200, 40 }, StyleSheet = APPLY_STYLE, Hidden = true },
    },
    -- Support: an email with the customer's setup filled in
    ui:HGroup{ Spacing = 8, Weight = 0, MinimumSize = { 0, 44 },
        ui:Button{ ID = "SupportMail", Text = "CONTACT SUPPORT", MinimumSize = { 200, 40 } },
    },
    ui:Label{ ID = "SupportHelp", Weight = 0, WordWrap = true, Hidden = true,
              Alignment = { AlignHCenter = true, AlignVCenter = true },
              StyleSheet = "color:#C9C9CF;font-size:13px;", Text = "" },
    ui:HGroup{ ID = "SupportRow", Spacing = 8, Weight = 0, MinimumSize = { 0, 44 }, Hidden = true,
        ui:Button{ ID = "SupportApp",   Text = "OPEN EMAIL APP", MinimumSize = { 160, 40 } },
        ui:Button{ ID = "SupportGmail", Text = "OPEN GMAIL", MinimumSize = { 160, 40 } },
        ui:Button{ ID = "SupportCopy",  Text = "COPY AGAIN", MinimumSize = { 160, 40 } },
    },
}

local logoAnimation = loadAnimation(LOGO_ANIM)
local rootGroup = { ID = "root", Spacing = 6, Weight = 1,
    logoAnimation and ui:Button{
        ID = "Logo", Flat = true, Weight = 0, MinimumSize = { 0, 76 }, MaximumSize = { 16777215, 76 },
        IconSize = { 179, 70 }, Icon = logoAnimation.frames[1], Text = "",
        StyleSheet = "border:none;background:transparent;",
    } or ui:Label{
        ID = "Logo", MinimumSize = { 0, 80 }, MaximumSize = { 16777215, 84 }, Weight = 0,
        Alignment = { AlignHCenter = true, AlignVCenter = true },
        Text = fileExists(LOGO)
            and ("<center><img src='" .. urlPath(LOGO) .. "' width='179' height='70'></center>")
            or  ("<center><span style='color:" .. RED ..
                 ";font-size:24px;font-weight:800;letter-spacing:6px;'>2WIN VFX HUB</span></center>"),
    },
    -- shown only when a newer Hub is available
    ui:HGroup{ ID = "UpdateBar", Weight = 0, Spacing = 8, Hidden = true, MinimumSize = { 0, 36 },
        ui:Label{ ID = "UpdateBarText", Weight = 1, Alignment = { AlignVCenter = true },
                  StyleSheet = "color:#FFFFFF;font-weight:700;letter-spacing:1px;", Text = "" },
        ui:Button{ ID = "UpdateBarGo", Text = "UPDATE", Weight = 0, MinimumSize = { 120, 32 } },
    },
    ui:HGroup(tabRow),
    effectsSection,
}
for _, s in ipairs(moduleSections) do rootGroup[#rootGroup + 1] = s end
rootGroup[#rootGroup + 1] = storeSection
rootGroup[#rootGroup + 1] = ui:Label{
    ID = "Status", Weight = 0, MinimumSize = { 0, 20 }, Alignment = { AlignHCenter = true },
    StyleSheet = "color:#7A7A82; font-size:12px;", Text = #CATALOGUE .. " effects loaded",
}
rootGroup[#rootGroup + 1] = ui:Label{
    ID = "Footer", Weight = 0, MinimumSize = { 0, 18 }, MaximumSize = { 16777215, 22 },
    Alignment = { AlignHCenter = true },
    Text = "<center><span style='color:" .. RED ..
           ";font-weight:700;letter-spacing:3px;font-size:11px;'>2WIN VFX HUB v" .. HUB_VERSION .. "</span>" ..
           "<span style='color:#4A4A52;font-size:11px;'>&nbsp;&nbsp;|&nbsp;&nbsp;BY 2WINVISUALS</span></center>",
}

win = disp:AddWindow({
    ID = "Hub",
    WindowTitle = "2WIN VFX Hub [2WINVISUALS]",
    Geometry = { 200, 60, 700, 960 },
    MinimumSize = { 700, 760 },
    StyleSheet = STYLE,
    ui:VGroup(rootGroup),
})

itm = win:GetItems()
local tree = itm.List
tree.ColumnWidth[0] = 640
itm.StoreList.ColumnWidth[0] = 430
itm.StoreList.ColumnWidth[1] = 180

--------------------------------------------------------------------
-- Effects list
--------------------------------------------------------------------

local rowGroup, animatedRows = {}, {}
local previewAnimation, previewAnimationFrame = nil, nil
-- Tracked from the tree's own events: tree.CurrentItem hands back a function
-- rather than the item, and UIManager swallows errors inside handlers.
local selectedGroup = nil
local activeSection, activeCategory = "ALL", nil

-- The three apply buttons follow the selected effect (or, with nothing selected,
-- the active section): Pre/Post effects and 1-framers keep PRE / BOTH / POST;
-- titles and lyrics, overlays and clip FX get placements that suit them.
local LYRIC_CATS = { ["LYRIC EFFECTS"] = true, LYRICS = true }
local APPLY_SETS = {
    prepost = { { "PRE", "PRE" }, { "BOTH", "BOTH" }, { "POST", "POST" } },
    text    = { { "AT CLIP START", "START" }, { "AT PLAYHEAD", "PLAYHEAD" } },
    lyric   = { { "AT CLIP START", "START" }, { "AT PLAYHEAD", "PLAYHEAD" }, { "FIT TO CLIP", "FIT" } },
    overlay = { { "AT CLIP START", "START" }, { "ON CUT", "ONCUT" }, { "FULL CLIP", "FULL" } },
    clip    = { { "DUPLICATE + APPLY", "DUPLICATE" }, { "APPLY TO CLIP", "DIRECT" } },
}
local APPLY_SLOTS = { "ApplyPre", "ApplyBoth", "ApplyPost" }
local applyActions = { "PRE", "BOTH", "POST" }

local function placementMode(group)
    if group then
        if group.pre or group.post then return "prepost" end
        if group.only and group.only.clip then return "clip" end
        local sec = sectionOf(group.type)
        if sec == "TEXT" then return LYRIC_CATS[group.type] and "lyric" or "text" end
        if sec == "OVERLAYS" then return "overlay" end
        return "prepost"
    end
    if activeSection == "TEXT" then return LYRIC_CATS[activeCategory] and "lyric" or "text" end
    if activeSection == "OVERLAYS" then return "overlay" end
    if activeSection == "CLIP FX" then return "clip" end
    -- ALL / FAVS: if everything installed places the same way (a titles-only
    -- install, say), use that; a mixed library keeps PRE / BOTH / POST
    local only
    for _, g in ipairs(GROUPS) do
        local m = placementMode(g)
        if only and m ~= only then return "prepost" end
        only = m
    end
    return only or "prepost"
end

local function updateApplyButtons(group)
    local set = APPLY_SETS[placementMode(group)]
    for i, id in ipairs(APPLY_SLOTS) do
        local a = set[i]
        applyActions[i] = a and a[2] or nil
        if itm[id] then
            itm[id].Hidden = (a == nil)
            if a then itm[id].Text = a[1] end
        end
    end
end
local previewHeight = 0
local layoutPending = 0

local function processLayout()
    if layoutPending > 0 then win:RecalcLayout(); layoutPending = layoutPending - 1 end
end

local function fitPanels()
    local minimum = 760 + previewHeight
    win.MinimumSize = { 700, minimum }
    local geometry = win.Geometry
    if geometry and geometry[4] < minimum then
        win.Geometry = { geometry[1], geometry[2], math.max(700, geometry[3]), minimum }
    end
    win:RecalcLayout()
    layoutPending = 20
end

local function matches(group, query)
    if query ~= "" and not displayName(group.base):lower():find(query, 1, true) then return false end
    if activeSection == "FAV" then return favourites[group.base] == true end
    if activeSection ~= "ALL" and sectionOf(group.type) ~= activeSection then return false end
    return activeCategory == nil or group.type == activeCategory
end

local function variantTag(group)
    if group.only then return "" end
    local bits = {}
    if group.pre  then bits[#bits + 1] = "PRE"  end
    if group.post then bits[#bits + 1] = "POST" end
    return "   " .. table.concat(bits, " / ")
end

local function populate()
    tree:Clear()
    rowGroup, animatedRows = {}, {}
    local query = itm.Search.Text:lower()
    local shown, ready = 0, 0
    for _, group in ipairs(GROUPS) do
        if matches(group, query) then
            local row = tree:NewItem()
            local star = favourites[group.base] and "*  " or ""
            local have = false
            for _, v in ipairs(variantsOf(group)) do
                if v.clip or v.kind == "media" or presetIndex[v.name:lower()]
                   or (v.pack and fileExists(v.pack.drbPath)) then have = true end
            end
            -- Rows are looked up by their text, so two packs showing the same name
            -- would pick each other: the later one carries its pack's name.
            local text = star .. displayName(group.base):upper() .. variantTag(group)
            if rowGroup[text] then text = text .. "   |   " .. group.pack.name:upper() end
            row.Text[0] = text
            row.ToolTip[0] = (have and "Ready to place" or "Preset file missing - reinstall this pack")
                             .. "  |  " .. group.pack.name
            if group.thumb then row.Icon[0] = ui:Icon({ File = group.thumb }) end
            row.SizeHint[0] = { 640, 116 }
            tree:AddTopLevelItem(row)
            rowGroup[row.Text[0]] = group
            if group.animation then animatedRows[#animatedRows + 1] = { row = row, animation = group.animation } end
            shown = shown + 1
            if have then ready = ready + 1 end
        end
    end
    if #PACKS == 0 then
        itm.Status.Text = "no packs installed yet - see the ADD-ONS tab"
    else
        itm.Status.Text = (shown == 0) and "no effects match"
            or (shown .. " of " .. #GROUPS .. " effects   |   " .. ready .. " ready to place")
    end
end

local function showPreview(group)
    local path = group and group.thumb
    if group then
        for _, v in ipairs(variantsOf(group)) do if not path and v.preview then path = v.preview end end
    end
    local visible = itm.PreviewToggle.Checked and path and fileExists(path) and not itm.FxSection.Hidden
    previewAnimation = visible and group.animation or nil
    previewAnimationFrame = nil
    if visible then
        if not itm.Preview then
            itm.FxSection:AddChild(ui:Button{ ID = "Preview", Weight = 0, Flat = true,
                MinimumSize = { 0, 112 }, MaximumSize = { 16777215, 112 }, IconSize = { 180, 101 },
                Text = "", ToolTip = "Reference preview of the selected effect",
                StyleSheet = "border:1px solid " .. RED_DIM .. ";border-radius:12px;background-color:" .. PANEL .. ";",
            }, "ApplyRow")
            itm = win:GetItems()
        end
        itm.Preview.Icon = previewAnimation and previewAnimation.frames[1] or ui:Icon{ File = path }
        itm.Preview:Show()
    elseif itm.Preview then
        itm.Preview:Hide()
        itm.FxSection:RemoveChild("Preview")
        itm = win:GetItems()
    end
    previewHeight = visible and 112 or 0
    itm.PreviewToggle.Text = itm.PreviewToggle.Checked and "PREVIEW ON" or "PREVIEW OFF"
    fitPanels()
    itm.Fav.Text = group and favourites[group.base] and "* FAVOURITED" or "FAVOURITE"
end

local animationClock = os.clock
pcall(function()
    local ffi = require("ffi")
    if ffi.os == "Windows" then
        ffi.cdef[[unsigned long long __stdcall GetTickCount64(void);]]
        local kernel = ffi.load("kernel32")
        animationClock = function() return tonumber(kernel.GetTickCount64()) / 1000 end
    else
        -- macOS / Linux: os.clock is CPU time and barely moves while the Hub idles,
        -- so previews would crawl; use the wall clock instead.
        ffi.cdef[[ typedef struct { long sec; int usec; } hub_timeval;
                   int gettimeofday(hub_timeval *tv, void *tz); ]]
        local tv = ffi.new("hub_timeval")
        if ffi.C.gettimeofday(tv, nil) == 0 then
            animationClock = function()
                ffi.C.gettimeofday(tv, nil)
                return tonumber(tv.sec) + tonumber(tv.usec) / 1e6
            end
        end
    end
end)
local logoStart, logoFrame = nil, 1
local function advanceAnimations()
    local now = animationClock()
    -- the header logo builds in once, then holds its last frame
    if logoAnimation and logoFrame < logoAnimation.count and itm.Logo then
        logoStart = logoStart or now
        local frame = math.min(logoAnimation.count, math.floor((now - logoStart) * logoAnimation.fps) + 1)
        if frame ~= logoFrame then itm.Logo.Icon = logoAnimation.frames[frame]; logoFrame = frame end
    end
    for _, entry in ipairs(animatedRows) do
        local a = entry.animation
        local frame = math.floor(now * a.fps) % a.count + 1
        if frame ~= entry.frame then entry.row.Icon[0] = a.frames[frame]; entry.frame = frame end
    end
    if previewAnimation and itm.Preview then
        local a = previewAnimation
        local frame = math.floor(now * a.fps) % a.count + 1
        if frame ~= previewAnimationFrame then itm.Preview.Icon = a.frames[frame]; previewAnimationFrame = frame end
    end
end

--------------------------------------------------------------------
-- Add-ons tab
--------------------------------------------------------------------

local storeRows, selectedProduct = {}, nil

local function populateStore()
    local list = itm.StoreList
    list:Clear()
    storeRows = {}
    local owned, available, soon = 0, 0, 0
    -- available first, then coming soon, then what's installed
    for pass = 1, 3 do
        for _, id in ipairs(STORE_ORDER) do
            local product = STORE[id]
            local have = ownsProduct(product)
            local group = have and 3 or (product.soon and 2 or 1)
            if group == pass then
                local row = list:NewItem()
                row.Text[0] = product.name:upper()
                row.Text[1] = have and "INSTALLED" or (product.soon and "COMING SOON" or "GET IT  >")
                row.ToolTip[0] = product.desc or ""
                row.SizeHint[0] = { 430, 48 }
                list:AddTopLevelItem(row)
                storeRows[row.Text[0]] = product
                if have then owned = owned + 1 elseif product.soon then soon = soon + 1 else available = available + 1 end
            end
        end
    end
    itm.StoreInfo.Text = (available > 0
        and (available .. " add-on" .. (available == 1 and "" or "s") .. " available. Select one to learn more.")
        or  "You have everything currently available - check the store for new releases.")
        .. (soon > 0 and (" " .. soon .. " more coming soon.") or "")
end

local function openUrl(url)
    if not safeUrl(url) then return false end
    if package.config:sub(1, 1) == "\\" then
        os.execute('start "" "' .. url .. '"')
    else
        os.execute('open "' .. url .. '" || xdg-open "' .. url .. '"')
    end
    return true
end

--------------------------------------------------------------------
-- Events
--------------------------------------------------------------------

--------------------------------------------------------------------
-- Support email: the customer's setup and recent problems, ready to send
--------------------------------------------------------------------

local SUPPORT_EMAIL = "support@2winvisuals.com"
local recentProblems = {}          -- last few errors / failed applies, newest last
local function noteProblem(msg)
    msg = tostring(msg or ""):gsub("%s+", " ")
    if msg == "" then return end
    recentProblems[#recentProblems + 1] = os.date("%H:%M ") .. msg:sub(1, 200)
    if #recentProblems > 4 then table.remove(recentProblems, 1) end
end

local function supportInfo()
    local lines = { "--- setup (added by the Hub) ---", "Hub: v" .. HUB_VERSION }
    local okR, product = pcall(function() return resolve:GetProductName() .. " " .. resolve:GetVersionString() end)
    lines[#lines + 1] = "Resolve: " .. (okR and product or "unknown")
    local okF, ffi = pcall(require, "ffi")
    local os_ = okF and (ffi.os .. " " .. ffi.arch) or (package.config:sub(1, 1) == "\\" and "Windows" or "Mac/Linux")
    if okF and ffi.os == "OSX" then
        local p = io.popen("sw_vers -productVersion 2>/dev/null")
        if p then os_ = "macOS " .. (p:read("*l") or "") .. " " .. ffi.arch; p:close() end
    end
    lines[#lines + 1] = "System: " .. os_
    local packs = {}
    for _, p in ipairs(PACKS) do packs[#packs + 1] = p.name .. (p.version and (" " .. p.version) or "") end
    lines[#lines + 1] = "Packs: " .. (#packs > 0 and table.concat(packs, ", ") or "none")
    local mods = {}
    for _, m in ipairs(MODULES) do mods[#mods + 1] = m.title or m.id end
    lines[#lines + 1] = "Add-ons: " .. (#mods > 0 and table.concat(mods, ", ") or "none")
    local okT, tl = pcall(function()
        local p = resolve:GetProjectManager():GetCurrentProject(); local t = p and p:GetCurrentTimeline()
        return t and (t:GetSetting("timelineFrameRate") .. " fps, " .. t:GetSetting("timelineResolutionWidth") .. "x"
                      .. t:GetSetting("timelineResolutionHeight")) or "no timeline open"
    end)
    lines[#lines + 1] = "Timeline: " .. (okT and tl or "unknown")
    lines[#lines + 1] = "Recent problems: " .. (#recentProblems > 0 and "" or "none")
    for _, p in ipairs(recentProblems) do lines[#lines + 1] = "  " .. p end
    return table.concat(lines, "\n")
end

local function copyToClipboard(text)
    local okF, ffi = pcall(require, "ffi")
    if okF and ffi.os == "Windows" then
        return pcall(function()
            pcall(ffi.cdef, [[
                int __stdcall OpenClipboard(void*); int __stdcall EmptyClipboard(void); int __stdcall CloseClipboard(void);
                void* __stdcall SetClipboardData(unsigned int, void*);
                void* __stdcall GlobalAlloc(unsigned int, size_t); void* __stdcall GlobalLock(void*); int __stdcall GlobalUnlock(void*);
            ]])
            pcall(ffi.cdef, [[ int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char*, int, uint16_t*, int); ]])
            local user, kernel = ffi.load("user32"), ffi.load("kernel32")
            local text2 = text:gsub("\r?\n", "\r\n")
            local n = kernel.MultiByteToWideChar(65001, 0, text2, -1, nil, 0)
            local h = kernel.GlobalAlloc(2, n * 2)                -- GMEM_MOVEABLE
            local p = ffi.cast("uint16_t*", kernel.GlobalLock(h))
            kernel.MultiByteToWideChar(65001, 0, text2, -1, p, n)
            kernel.GlobalUnlock(h)
            assert(user.OpenClipboard(nil) ~= 0)
            user.EmptyClipboard(); user.SetClipboardData(13, h); user.CloseClipboard()   -- CF_UNICODETEXT
        end)
    end
    local p = io.popen("pbcopy", "w")
    if p then p:write(text); p:close(); return true end
    return false
end

-- Opens a mailto: or https: address with the system handler (no console window on Windows).
local function launch(url)
    local okF, ffi = pcall(require, "ffi")
    if okF and ffi.os == "Windows" then
        local ok = pcall(function()
            pcall(ffi.cdef, [[ void* __stdcall ShellExecuteW(void*, const uint16_t*, const uint16_t*, const uint16_t*, const uint16_t*, int); ]])
            pcall(ffi.cdef, [[ int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char*, int, uint16_t*, int); ]])
            local kernel = ffi.load("kernel32")
            local function wide(t)
                local n = kernel.MultiByteToWideChar(65001, 0, t, -1, nil, 0)
                local o = ffi.new("uint16_t[?]", n); kernel.MultiByteToWideChar(65001, 0, t, -1, o, n); return o
            end
            local r = ffi.load("shell32").ShellExecuteW(nil, wide("open"), wide(url), nil, nil, 1)
            assert(tonumber(ffi.cast("intptr_t", r)) > 32, "nothing opened it")
        end)
        return ok
    end
    local r = os.execute("open '" .. url:gsub("'", "%%27") .. "'")
    return r == 0 or r == true
end
local function mailEnc(s) return (s:gsub("\r?\n", "\r\n"):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)) end
local SUPPORT_SUBJECT = "2WIN VFX Hub support"
local SUPPORT_PROMPT = "Hi 2WINVISUALS, here's what happened (what you clicked, what you expected, what you saw):\n\n\n\n"
local function openMail(body)
    return launch("mailto:" .. SUPPORT_EMAIL .. "?subject=" .. mailEnc(SUPPORT_SUBJECT) .. "&body=" .. mailEnc(body))
end
local function openGmail(body)
    return launch("https://mail.google.com/mail/?view=cm&fs=1&to=" .. mailEnc(SUPPORT_EMAIL)
                  .. "&su=" .. mailEnc(SUPPORT_SUBJECT) .. "&body=" .. mailEnc(body))
end
ctx.noteProblem = noteProblem

-- UIManager discards errors raised inside a handler; report them instead.
local function guard(fn)
    return function(ev)
        local ok, err = pcall(fn, ev)
        if not ok then itm.Status.Text = "error: " .. tostring(err); noteProblem(err) end
    end
end
ctx.guard = guard

local function setTab(which)
    itm.FxSection.Hidden = (which ~= "FX")
    itm.StoreSection.Hidden = (which ~= "STORE")
    itm.TabFx.Checked = (which == "FX")
    itm.TabStore.Checked = (which == "STORE")
    for _, mod in ipairs(MODULES) do
        if not mod.failed then
            itm[mod.sectionId].Hidden = (which ~= mod.id)
            itm[mod.tabId].Checked = (which == mod.id)
            if which == mod.id and mod.shown then pcall(mod.shown, ctx) end
        end
    end
    if which == "STORE" then populateStore() end
    showPreview(which == "FX" and selectedGroup or nil)
end

win.On.TabFx.Clicked = guard(function() setTab("FX") end)
win.On.TabStore.Clicked = guard(function() setTab("STORE") end)
for _, mod in ipairs(MODULES) do
    if not mod.failed then
        win.On[mod.tabId].Clicked = guard(function() setTab(mod.id) end)
    end
end

-- A category button toggles: clicking the active one goes back to the whole section.
local function setFilter(which)
    selectedGroup = nil
    showPreview(nil)
    activeCategory = (activeCategory ~= which) and which or nil
    for _, f in ipairs(FILTERS) do
        if itm[f.id] then itm[f.id].Checked = (f.cat == activeCategory) end
    end
    populate()
    updateApplyButtons(nil)
end

local function setSection(which)
    selectedGroup = nil
    showPreview(nil)
    activeSection, activeCategory = which, nil
    for _, b in ipairs(SECTION_BUTTONS) do
        if itm[b.id] then itm[b.id].Checked = (b.sec == which) end
    end
    for _, f in ipairs(FILTERS) do
        if itm[f.id] then itm[f.id].Checked = false end
    end
    for sec, id in pairs(SECTION_GROUP) do
        if itm[id] then itm[id].Hidden = not (sec == which and (SECTION_CATS[sec] or 0) > 1) end
    end
    populate()
    updateApplyButtons(nil)
    fitPanels()
end

local function wireFilters()
    for _, b in ipairs(SECTION_BUTTONS) do
        local sec = b.sec
        win.On[b.id].Clicked = guard(function() setSection(sec) end)
    end
    for _, f in ipairs(FILTERS) do
        local cat = f.cat
        win.On[f.id].Clicked = guard(function() setFilter(cat) end)
    end
end
wireFilters()

win.On.Search.TextChanged = guard(function()
    selectedGroup = nil
    showPreview(nil)
    populate()
end)

win.On.PreviewToggle.Clicked = guard(function() showPreview(selectedGroup) end)

-- The event carries the row that was acted on: the dependable way to know.
local function groupFromEvent(ev)
    local row = ev and ev.item
    if not row then
        local ok, cur = pcall(function() return tree:CurrentItem() end)
        if ok then row = cur end
    end
    if not row then return nil end
    local ok, key = pcall(function() return row.Text[0] end)
    if not ok then return nil end
    return rowGroup[key]
end

local function selectRow(ev)
    selectedGroup = groupFromEvent(ev)
    showPreview(selectedGroup)
    updateApplyButtons(selectedGroup)
end
win.On.List.CurrentItemChanged = guard(selectRow)
win.On.List.ItemClicked        = guard(selectRow)

local function apply(which)
    if not selectedGroup then itm.Status.Text = "pick an effect first" return end
    itm.Status.Text = applyGroup(selectedGroup, which)
    if tostring(itm.Status.Text):lower():find("fail") then noteProblem(displayName(selectedGroup.base) .. ": " .. itm.Status.Text) end
end

-- Double-click lays down the full pair (other kinds: their first placement).
win.On.List.ItemDoubleClicked = guard(function(ev)
    local group = groupFromEvent(ev)
    if group then
        selectedGroup = group
        showPreview(group)
        updateApplyButtons(group)
        itm.Status.Text = applyGroup(group, placementMode(group) == "prepost" and "BOTH" or applyActions[1])
        if tostring(itm.Status.Text):lower():find("fail") then noteProblem(displayName(group.base) .. ": " .. itm.Status.Text) end
    end
end)
win.On.ApplyPre.Clicked  = guard(function() if applyActions[1] then apply(applyActions[1]) end end)
win.On.ApplyBoth.Clicked = guard(function() if applyActions[2] then apply(applyActions[2]) end end)
win.On.ApplyPost.Clicked = guard(function() if applyActions[3] then apply(applyActions[3]) end end)

win.On.Fav.Clicked = guard(function()
    if not selectedGroup then itm.Status.Text = "pick an effect first" return end
    local group = selectedGroup
    favourites[group.base] = not favourites[group.base] or nil
    saveFavourites()
    populate()
    showPreview(group)
end)

local function storeProductFromEvent(ev)
    local row = ev and ev.item
    if not row then return nil end
    local ok, key = pcall(function() return row.Text[0] end)
    return ok and storeRows[key] or nil
end
local function selectProduct(ev)
    local product = storeProductFromEvent(ev)
    if not product then return end
    selectedProduct = product
    local have = ownsProduct(product)
    itm.StoreInfo.Text = "<b>" .. product.name .. "</b><br>" .. (product.desc or "")
        .. (have and "<br><span style='color:#7A7A82;'>Installed</span>"
            or (product.soon and "<br><span style='color:#7A7A82;'>Coming soon</span>" or ""))
    itm.StoreGet.Text = have and "INSTALLED" or (product.soon and "COMING SOON" or "GET IT")
end
win.On.StoreList.ItemClicked = guard(selectProduct)
win.On.StoreList.CurrentItemChanged = guard(selectProduct)
win.On.StoreList.ItemDoubleClicked = guard(function(ev)
    local product = storeProductFromEvent(ev)
    if product and not ownsProduct(product) and not product.soon and openUrl(product.url) then
        itm.Status.Text = "opening the store in your browser..."
    end
end)
win.On.StoreGet.Clicked = guard(function()
    if not selectedProduct then itm.Status.Text = "select a product first" return end
    if ownsProduct(selectedProduct) then itm.Status.Text = selectedProduct.name .. " is already installed" return end
    if selectedProduct.soon then itm.Status.Text = selectedProduct.name .. " is coming soon - stay tuned" return end
    if openUrl(selectedProduct.url) then itm.Status.Text = "opening the store in your browser..." end
end)
win.On.StoreVisit.Clicked = guard(function()
    if openUrl(STORE_HOME) then itm.Status.Text = "opening the store in your browser..." end
end)

--------------------------------------------------------------------
-- Updates UI
--------------------------------------------------------------------

local function esc(t) return (tostring(t or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end

local function showUpdateState()
    local u = update
    local notes = ""
    if u.release and #u.release.notes > 0 then
        local lines = {}
        for _, n in ipairs(u.release.notes) do lines[#lines + 1] = "&bull; " .. esc(n) end
        notes = "<br><span style='color:#9A9AA2;'>" .. table.concat(lines, "<br>") .. "</span>"
    end
    local text
    if u.state == "available" then
        text = "<b>Update available: v" .. esc(u.release.version) .. "</b>  (you have v" .. HUB_VERSION .. ")" .. notes
    elseif u.state == "current" then
        text = "You're up to date  (v" .. HUB_VERSION .. ")"
    elseif u.state == "offline" then
        text = "Couldn't check for updates - are you online?  (v" .. HUB_VERSION .. ")"
    elseif u.state == "installed" then
        text = "<b>Updated to v" .. esc(u.release.version) .. ".</b> Close the Hub and open it again to use the new version."
    elseif u.state == "failed" then
        text = "Update failed: " .. esc(u.error) .. "  (still on v" .. HUB_VERSION .. ")"
    else
        text = "2WIN VFX Hub v" .. HUB_VERSION
    end
    itm.UpdateInfo.Text = text
    itm.UpdateInstall.Hidden = (u.state ~= "available")
    itm.UpdateBar.Hidden = not (u.state == "available" or u.state == "installed")
    if u.state == "available" then
        itm.UpdateBarText.Text = "  Update available: v" .. u.release.version
        itm.UpdateBarGo.Hidden = false
    elseif u.state == "installed" then
        itm.UpdateBarText.Text = "  Updated to v" .. u.release.version .. " - reopen the Hub to use it"
        itm.UpdateBarGo.Hidden = true
    end
    win:RecalcLayout()
end

local function runUpdate()
    if update.state ~= "available" then return end
    itm.UpdateInfo.Text = "Downloading v" .. esc(update.release.version) .. "..."
    disp:StepLoop(0.01)
    local ok, err = installUpdate()
    if not ok then update.state = "failed"; update.error = err; noteProblem("update failed: " .. tostring(err)) end
    showUpdateState()
    itm.Status.Text = ok and ("updated to v" .. update.release.version .. " - reopen the Hub") or ("update failed: " .. err)
end

win.On.UpdateCheck.Clicked = guard(function()
    itm.UpdateInfo.Text = "Checking for updates..."
    disp:StepLoop(0.01)
    checkForUpdates()
    refreshCatalog()
    discoverPacks()
    showUpdateState()
    populateStore()
end)
win.On.UpdateInstall.Clicked = guard(runUpdate)
local supportText = ""
win.On.SupportMail.Clicked = guard(function()
    supportText = SUPPORT_PROMPT .. supportInfo()
    local copied = copyToClipboard(supportText)
    itm.SupportHelp.Text = "<b>Email " .. SUPPORT_EMAIL .. "</b> from any email - Gmail, Proton, Outlook, iCloud...<br>"
        .. (copied and "Your setup is <b>copied</b>: paste it into the message (Ctrl+V / Cmd+V) and describe what happened."
                   or  "Describe what happened and include your Hub and Resolve versions.")
    itm.SupportHelp.Hidden = false; itm.SupportRow.Hidden = false
    itm.Status.Text = copied and "support info copied - paste it into an email to " .. SUPPORT_EMAIL or "email " .. SUPPORT_EMAIL
    win:RecalcLayout()
end)
win.On.SupportApp.Clicked = guard(function()
    itm.Status.Text = openMail(supportText) and "opening your email app..."
        or "no email app is set up - paste the copied info into an email to " .. SUPPORT_EMAIL
end)
win.On.SupportGmail.Clicked = guard(function()
    itm.Status.Text = openGmail(supportText) and "opening Gmail in your browser..." or "couldn't open the browser"
end)
win.On.SupportCopy.Clicked = guard(function()
    itm.Status.Text = copyToClipboard(supportText) and "support info copied again" or "couldn't copy"
end)
win.On.UpdateBarGo.Clicked = guard(runUpdate)

-- New categories from a newly installed pack get their buttons: into their
-- section's category group, with a new section button when the section is new.
local newFilterSerial = 0
local function addNewFilterButtons()
    local have = {}
    for _, f in ipairs(FILTERS) do have[f.cat] = true end
    local bySection, order = {}, {}
    for _, cat in ipairs(CATEGORIES) do
        if not have[cat] then
            local s = sectionOf(cat)
            if not bySection[s] then bySection[s] = {}; order[#order + 1] = s end
            newFilterSerial = newFilterSerial + 1
            local f = { id = "FiltNew" .. newFilterSerial, cat = cat, label = cat, sec = s }
            table.insert(bySection[s], f)
        end
    end
    if #order == 0 then return end
    local newButtons = {}
    for _, s in ipairs(order) do
        if not SECTION_GROUP[s] then
            newFilterSerial = newFilterSerial + 1
            local b = { id = "SecNew" .. newFilterSerial, sec = s, label = s }
            itm.SectionRow:AddChild(ui:Button{ ID = b.id, Text = b.label, Checkable = true, StyleSheet = SECTION_STYLE })
            table.insert(SECTION_BUTTONS, #SECTION_BUTTONS, b)   -- keep FAVS last
            newButtons[#newButtons + 1] = b
            SECTION_GROUP[s], SECTION_CATS[s] = "SecCatsNew" .. newFilterSerial, 0
            itm.FilterRows:AddChild(ui:VGroup{ ID = SECTION_GROUP[s], Weight = 0, Spacing = 6, Hidden = true })
            itm = win:GetItems()
        end
        for _, row in ipairs(categoryRows(bySection[s])) do itm[SECTION_GROUP[s]]:AddChild(row) end
        SECTION_CATS[s] = SECTION_CATS[s] + #bySection[s]
        for _, f in ipairs(bySection[s]) do FILTERS[#FILTERS + 1] = f end
    end
    itm = win:GetItems()
    for _, b in ipairs(newButtons) do
        local sec = b.sec
        win.On[b.id].Clicked = guard(function() setSection(sec) end)
    end
    for _, s in ipairs(order) do
        for _, f in ipairs(bySection[s]) do
            local cat = f.cat
            win.On[f.id].Clicked = guard(function() setFilter(cat) end)
        end
    end
end

local function rescan()
    discoverPacks()
    buildCatalogue()
    rebuildBases()
    addNewFilterButtons()
    local _, proj = currentTimeline()
    local message = "No project open"
    if proj then
        local moved = Bins.tidy(proj)
        message = moved > 0 and ("tidied " .. moved .. " old bin" .. (moved == 1 and "" or "s") .. " into '" .. Bins.HUB .. "'") or "ready"
    end
    refreshPresets()
    buildGroups()
    for _, mod in ipairs(MODULES) do
        if not mod.failed and mod.refresh then pcall(mod.refresh, ctx) end
    end
    selectedGroup = nil
    showPreview(nil)
    populate()
    updateApplyButtons(nil)
    if not itm.StoreSection.Hidden then populateStore() end
    itm.Status.Text = itm.Status.Text .. " | " .. message
end
win.On.Refresh.Clicked = guard(rescan)

local closed = false
win.On.Hub.Close = guard(function() closed = true; disp:ExitLoop() end)

for _, mod in ipairs(MODULES) do
    if not mod.failed and mod.wire then
        local ok, err = pcall(mod.wire, win, ctx)
        if not ok then mod.failed = true; itm.Status.Text = "add-on error: " .. tostring(err) end
    end
end

math.randomseed(os.time())
local _, startupProject = currentTimeline()
local startupMessage
if startupProject then
    local moved = Bins.tidy(startupProject)
    if moved > 0 then startupMessage = "tidied " .. moved .. " old bin" .. (moved == 1 and "" or "s") .. " into '" .. Bins.HUB .. "'" end
end
refreshPresets()
buildGroups()
for _, mod in ipairs(MODULES) do
    if not mod.failed and mod.refresh then pcall(mod.refresh, ctx) end
end
populate()
updateApplyButtons(nil)   -- now that the installed effects are known
if startupMessage then itm.Status.Text = itm.Status.Text .. " | " .. startupMessage end

-- Windows title-bar icon, scoped to this window only.
local function setTitleIcon(window, path)
    local ok, ffi = pcall(require, "ffi")
    if not ok or ffi.os ~= "Windows" or not fileExists(path) then return nil end
    ffi.cdef[[
        void* __stdcall FindWindowW(const uint16_t*, const uint16_t*);
        void* __stdcall LoadImageW(void*, const uint16_t*, unsigned int, int, int, unsigned int);
        intptr_t __stdcall SendMessageW(void*, unsigned int, uintptr_t, intptr_t);
        unsigned long __stdcall GetWindowThreadProcessId(void*, unsigned long*);
        void* __stdcall OpenProcess(unsigned long, int, unsigned long);
        int __stdcall QueryFullProcessImageNameW(void*, unsigned long, uint16_t*, unsigned long*);
        int __stdcall CloseHandle(void*);
        int __stdcall DestroyIcon(void*);
        int __stdcall IsWindow(void*);
        long __stdcall DwmSetWindowAttribute(void*, unsigned long, const void*, unsigned long);
    ]]
    pcall(function() ffi.cdef[[ int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char*, int, uint16_t*, int); ]] end)
    local user, kernel = ffi.load("user32"), ffi.load("kernel32")
    local function wide(text)
        local count = kernel.MultiByteToWideChar(65001, 0, text, -1, nil, 0)
        assert(count > 0, "Invalid icon path")
        local out = ffi.new("uint16_t[?]", count)
        assert(kernel.MultiByteToWideChar(65001, 0, text, -1, out, count) > 0)
        return out
    end
    local title = window.WindowTitle
    local uniqueTitle = title .. " " .. tostring({})
    window.WindowTitle = uniqueTitle
    local hwnd = user.FindWindowW(nil, wide(uniqueTitle))
    window.WindowTitle = title
    if hwnd == nil then return nil end
    local pid = ffi.new("unsigned long[1]")
    user.GetWindowThreadProcessId(hwnd, pid)
    local process = kernel.OpenProcess(4096, 0, pid[0])
    if process == nil then return nil end
    local executable, length = ffi.new("uint16_t[32768]"), ffi.new("unsigned long[1]", 32768)
    local queried = kernel.QueryFullProcessImageNameW(process, 0, executable, length)
    kernel.CloseHandle(process)
    if queried == 0 then return nil end
    local name = {}
    for i = 0, tonumber(length[0]) - 1 do name[#name + 1] = executable[i] < 128 and string.char(executable[i]) or "?" end
    local host = table.concat(name):lower():match("[^\\/]+$")
    if host ~= "resolve.exe" and host ~= "fuscript.exe" then return nil end
    local dwmOK, dwm = pcall(ffi.load, "dwmapi")
    if dwmOK then
        local dark = ffi.new("int[1]", 1)
        dwm.DwmSetWindowAttribute(hwnd, 20, dark, 4)
        local black = ffi.new("unsigned long[1]", 0x090909)
        local white = ffi.new("unsigned long[1]", 0xEEEEEE)
        dwm.DwmSetWindowAttribute(hwnd, 35, black, 4)
        dwm.DwmSetWindowAttribute(hwnd, 36, white, 4)
    end
    local handles = {}
    for kind = 0, 1 do
        local icon = user.LoadImageW(nil, wide(path), 1, kind == 0 and 24 or 48, kind == 0 and 24 or 48, 16)
        if icon ~= nil then
            local prior = user.SendMessageW(hwnd, 128, kind, ffi.cast("intptr_t", icon))
            handles[#handles + 1] = { icon = icon, kind = kind, prior = prior }
        end
    end
    if #handles == 0 then return nil end
    return function()
        for _, entry in ipairs(handles) do
            if user.IsWindow(hwnd) ~= 0 then user.SendMessageW(hwnd, 128, entry.kind, entry.prior) end
            user.DestroyIcon(entry.icon)
        end
    end
end

local cleanupIcon
win:Show()
fitPanels()
for i = 1, 3 do disp:StepLoop(0.01) end
do
    local ok, cleanup = pcall(setTitleIcon, win, ICON)
    if ok and cleanup then cleanupIcon = cleanup end
end
-- Self-test hook for the build tools: a flag file closes the window after
-- a moment and records what loaded. Customers never have this file.
local selftest = HUB_DIR .. "/.selftest"
local selftestStart = fileExists(selftest) and os.clock() or nil
local selftestApply = ""
local selftestSpec = ""
if selftestStart then
    -- Optional second line: "<effect base>|<timeline name>" applies that effect
    -- (Pre and Post) at the second clip's head on a scratch timeline.
    local f = io.open(selftest, "r")
    if f then f:read("*l"); local spec = f:read("*l"); f:close()
        selftestSpec = spec or ""
        -- optional third field: an apply action (PRE/BOTH/POST/START/PLAYHEAD/ONCUT/FULL/DUPLICATE/DIRECT)
        local base, tlName, action = (spec or ""):match("^(.-)|([^|]+)|?(.*)$")
        local _, proj = currentTimeline()
        if base and proj and tlName:match("^ZZ_") then
            for i = 1, proj:GetTimelineCount() do
                local t = proj:GetTimelineByIndex(i)
                if t:GetName() == tlName then proj:SetCurrentTimeline(t) end
            end
            local tl = currentTimeline()
            local clips = tl and tl:GetItemListInTrack("video", 1) or {}
            -- a real session re-reads the packs once the window is up (the startup loop);
            -- do the same so the self-test exercises effects pointing at older pack tables
            discoverPacks()
            local group
            for _, g in ipairs(GROUPS) do if g.base == base then group = g end end
            if base == "AUTO" then
                for _, m in ipairs(MODULES) do
                    if m.id == "auto-vfx" and m.selftest then selftestApply = m.selftest(ctx, 99) end
                end
            elseif group and clips[2] then
                local c = clips[2]
                local target = { { item = c, track = 1, s = math.floor(c:GetStart()), e = math.floor(c:GetEnd()) } }
                if action and action ~= "" then
                    selftestApply = action .. ": " .. applyGroup(group, action, target)
                else
                    for _, v in ipairs(variantsOf(group)) do
                        selftestApply = selftestApply .. applyEffect(v, target) .. " || "
                    end
                end
            else
                selftestApply = "selftest: group or clips missing"
            end
        end
    end
end
-- After a failed update the launcher restores the previous version.
if fileExists(CORE_DIR .. "/rolled_back.txt") then
    os.remove(CORE_DIR .. "/rolled_back.txt")
    itm.Status.Text = "the last update didn't start, so the previous version was restored"
end
local startupChecked = false
while not closed do
    disp:StepLoop(0)
    if not startupChecked then
        -- once the window is showing: product list + update check (a second or two)
        startupChecked = true
        pcall(function()
            refreshCatalog()
            discoverPacks()
            checkForUpdates()
            showUpdateState()
            if selftestSpec == "UPDATE" then runUpdate() end
            if selftestSpec == "SUPPORT" then
                noteProblem("selftest: sample problem")
                selftestApply = "clipboard=" .. tostring(copyToClipboard(supportInfo())) .. " | "
                                .. supportInfo():gsub("\n", " | ")
            end
        end)
    end
    processLayout()
    advanceAnimations()
    bmd.wait(0.01)
    if selftestStart and os.clock() - selftestStart > 2 then
        local f = io.open(HUB_DIR .. "/.selftest_result", "w")
        if f then
            local mods = {}
            for _, m in ipairs(MODULES) do mods[#mods + 1] = m.id .. (m.failed and "(failed)" or "") end
            local packs = {}
            for _, p in ipairs(PACKS) do packs[#packs + 1] = p.id end
            f:write("packs=" .. table.concat(packs, ",") .. "\neffects=" .. #CATALOGUE .. "\ngroups=" .. #GROUPS
                .. "\ncategories=" .. table.concat(CATEGORIES, ",") .. "\nsections=" .. table.concat(presentSections(), ",")
                .. "\nmodules=" .. table.concat(mods, ",")
                .. "\nversion=" .. HUB_VERSION .. "\nupdate=" .. tostring(update.state)
                .. (update.release and (" " .. update.release.version) or "") .. (update.error and (" " .. update.error) or "")
                .. "\nupdateinfo=" .. tostring(itm.UpdateInfo.Text)
                .. "\nstore=" .. #STORE_ORDER .. "\nstoreids=" .. table.concat(STORE_ORDER, ",") .. "\nstatus=" .. tostring(itm.Status.Text)
                .. "\napply=" .. selftestApply .. "\n")
            f:close()
        end
        os.remove(selftest)
        closed = true
    end
end
if cleanupIcon then pcall(cleanupIcon) end
win:Hide()
