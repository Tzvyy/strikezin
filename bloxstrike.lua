--[[
    Test build #3: mouse-delta aim assist.
    NO BindToRenderStep. NO Camera.CFrame writes. NO game-module imports.
    Camera moves via mousemoverel() / VirtualInputManager â€” looks like real input.

    Differences vs build #2 (the one that banned):
      * Removed RunService:BindToRenderStep entirely. Aim runs inside the same
        RenderStepped:Connect() the ESP loop uses (which was clean in build #1).
      * Removed Camera.CFrame writes. We send mouse delta instead.
]]

local repo = "https://raw.githubusercontent.com/Tzvyy/JopLib/main/"
local Library      = loadstring(game:HttpGet(repo .. "Library.lua"))()
local Elements     = loadstring(game:HttpGet(repo .. "Elements.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "ThemeManager.lua"))()
local SaveManager  = loadstring(game:HttpGet(repo .. "SaveManager.lua"))()
Elements:Setup(Library)
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)

local Toggles = Library.Toggles
local Options = Library.Options

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer= Players.LocalPlayer
local Camera     = workspace.CurrentCamera
local V2, V3     = Vector2.new, Vector3.new
local clamp      = math.clamp

-- Mouse-delta sender. Resolved LAZILY on first use.
-- IMPORTANT: NO VirtualInputManager fallback. SendMouseMoveEvent is a known
-- AC trigger that fires bans even when the camera doesn't visibly move
-- (because in first-person the cursor is locked center, but the AC sees the
--  synthetic input event regardless). If the executor lacks a real
-- mousemoverel, aim assist is disabled entirely â€” better than banning.
local _mousemove
local _mouseMoveResolved = false
local _mouseMoveAvailable = false

local function getMouseMove()
    if _mouseMoveResolved then return _mousemove end
    _mouseMoveResolved = true

    -- Executor builtins live in getgenv(), not _G.
    local sources = {}
    if type(getgenv) == "function" then
        local ok, g = pcall(getgenv); if ok then sources[#sources+1] = g end
    end
    sources[#sources+1] = _G

    local names = { "mousemoverel", "mouse_move_relative", "MouseMoveRel" }
    for _, src in ipairs(sources) do
        if type(src) == "table" then
            for _, n in ipairs(names) do
                local fn = rawget(src, n)
                if type(fn) == "function" then
                    _mousemove = fn
                    _mouseMoveAvailable = true
                    return fn
                end
            end
        end
    end
    -- Last resort: getfenv-based lookup (only here, never at load)
    if type(getfenv) == "function" then
        local ok, env = pcall(getfenv, 0)
        if ok and type(env) == "table" then
            for _, n in ipairs(names) do
                local fn = rawget(env, n)
                if type(fn) == "function" then
                    _mousemove = fn
                    _mouseMoveAvailable = true
                    return fn
                end
            end
        end
    end
    return nil
end

local Window = Library:CreateWindow({ Title = "Helper", Center = true, AutoShow = true })
local Tabs = {
    Aim     = Window:AddTab("Aimbot"),
    Visuals = Window:AddTab("Visuals"),
    World   = Window:AddTab("World"),
    Skins   = Window:AddTab("Skins"),
    Conf    = Window:AddTab("Config"),
}

local function mkDraw(t, props)
    local d = Drawing.new(t)
    for k, v in pairs(props or {}) do d[k] = v end
    d.Visible = false
    return d
end

-- =========================================================================
-- Team / alive
-- =========================================================================
local function isEnemy(plr)
    if plr == LocalPlayer then return false end
    if workspace:GetAttribute("Gamemode") == "Deathmatch" then return true end
    local mine, theirs = LocalPlayer:GetAttribute("Team"), plr:GetAttribute("Team")
    if not mine or not theirs then return false end
    return mine ~= theirs
end
local function isAlive(plr)
    local c = plr.Character
    if not c or not c:IsDescendantOf(workspace) then return false end
    if c:GetAttribute("Dead") == true then return false end
    local h = c:FindFirstChildOfClass("Humanoid")
    return h ~= nil and h.Health > 0, c, h
end

-- =========================================================================
-- Visibility (lazy raycast params, only created when wallcheck used)
-- =========================================================================
local rcParams
local function ensureRC()
    if rcParams then return rcParams end
    rcParams = RaycastParams.new()
    rcParams.FilterType = Enum.RaycastFilterType.Exclude
    rcParams.IgnoreWater = true
    return rcParams
end
-- Multi-part visibility: returns true if ANY of the listed body parts has a
-- clear line of sight from `origin`. Used for both target selection and
-- per-shot LOS gating. If even an arm is exposed, we consider the player
-- visible.
local VIS_PART_NAMES = {
    "Head",
    "UpperTorso", "LowerTorso", "Torso", "HumanoidRootPart",
    "LeftUpperArm", "RightUpperArm",
    "LeftLowerArm", "RightLowerArm",
    "LeftHand", "RightHand",
    "LeftUpperLeg", "RightUpperLeg",
}
local function isVisibleMulti(char, origin)
    if not char then return false end
    local p = ensureRC()
    local ignore = { LocalPlayer.Character }
    local debris = workspace:FindFirstChild("Debris")
    if debris then table.insert(ignore, debris) end
    p.FilterDescendantsInstances = ignore
    for _, name in ipairs(VIS_PART_NAMES) do
        local part = char:FindFirstChild(name)
        if part and part:IsA("BasePart") then
            local dir = part.Position - origin
            local hit = workspace:Raycast(origin, dir, p)
            if not hit then return true end
            if char:IsAncestorOf(hit.Instance) or hit.Instance == part then
                return true
            end
        end
    end
    return false
end
-- Backwards-compat alias for any leftover callers
local isVisible = isVisibleMulti

-- =========================================================================
-- Target picker
-- =========================================================================
local function findBest(camCF, fovRad, maxDist, requireVis)
    local origin, look = camCF.Position, camCF.LookVector
    local best, bestScore = nil, 0
    for _, plr in ipairs(Players:GetPlayers()) do
        if isEnemy(plr) then
            local alive, char = isAlive(plr)
            if alive and char and char.PrimaryPart then
                local d = char.PrimaryPart.Position - origin
                local dist = d.Magnitude
                if dist <= maxDist then
                    local cos = clamp(look:Dot(d.Unit), -1, 1)
                    local angle = math.acos(cos)
                    if angle <= fovRad then
                        if not requireVis or isVisible(char, origin) then
                            local score = (1 - angle / fovRad) / (dist + 1)
                            if score > bestScore then bestScore, best = score, char end
                        end
                    end
                end
            end
        end
    end
    return best
end

-- =========================================================================
-- ESP / Visuals constants
-- =========================================================================
local ESP_MAX_DIST = 500

-- Skeleton bone pairs (R15 + R6 fallback). Each pair becomes one Line drawing.
local SKELETON_BONES_R15 = {
    {"Head", "UpperTorso"}, {"UpperTorso", "LowerTorso"},
    {"UpperTorso", "LeftUpperArm"}, {"LeftUpperArm", "LeftLowerArm"}, {"LeftLowerArm", "LeftHand"},
    {"UpperTorso", "RightUpperArm"}, {"RightUpperArm", "RightLowerArm"}, {"RightLowerArm", "RightHand"},
    {"LowerTorso", "LeftUpperLeg"}, {"LeftUpperLeg", "LeftLowerLeg"}, {"LeftLowerLeg", "LeftFoot"},
    {"LowerTorso", "RightUpperLeg"}, {"RightUpperLeg", "RightLowerLeg"}, {"RightLowerLeg", "RightFoot"},
}
local SKELETON_BONES_R6 = {
    {"Head", "Torso"}, {"Torso", "Left Arm"}, {"Torso", "Right Arm"},
    {"Torso", "Left Leg"}, {"Torso", "Right Leg"},
}
-- Combined: render whichever pairs the rig has. Missing parts are skipped per frame.
local SKELETON_BONES = {}
for _, p in ipairs(SKELETON_BONES_R15) do SKELETON_BONES[#SKELETON_BONES+1] = p end
for _, p in ipairs(SKELETON_BONES_R6)  do SKELETON_BONES[#SKELETON_BONES+1] = p end

-- =========================================================================
-- ESP cache â€” per-player drawings + Highlight (chams)
-- =========================================================================
local cache = {}
local function mkLine(c) return mkDraw("Line", { Thickness = 1, Color = c or Color3.new(1,1,1) }) end

local function getEntry(plr)
    local e = cache[plr]
    if e then return e end
    e = {
        -- Box: Full
        box  = mkDraw("Square", { Thickness = 1, Filled = false }),
        bg   = mkDraw("Square", { Thickness = 3, Filled = false, Color = Color3.new(0,0,0), Transparency = 0.5 }),
        -- Box: Corner â€” 8 short lines (4 corners x 2 lines each)
        corners = (function()
            local t = {}
            for i = 1, 8 do t[i] = mkLine() end
            return t
        end)(),
        -- Box: 3D â€” 12 wireframe edges
        cube = (function()
            local t = {}
            for i = 1, 12 do t[i] = mkLine() end
            return t
        end)(),
        -- Skeleton lines
        skeleton = (function()
            local t = {}
            for i = 1, #SKELETON_BONES do t[i] = mkLine() end
            return t
        end)(),
        -- Text
        name = mkDraw("Text",   { Size = 13, Center = true, Outline = true, Font = 2 }),
        dist = mkDraw("Text",   { Size = 11, Center = true, Outline = true, Font = 2 }),
        -- Health bar
        hpBg = mkDraw("Square", { Thickness = 1, Filled = true, Color = Color3.new(0,0,0), Transparency = 0.7 }),
        hpFg = mkDraw("Square", { Thickness = 0, Filled = true, Color = Color3.fromRGB(0,255,0) }),
        hpOl = mkDraw("Square", { Thickness = 1, Filled = false, Color = Color3.new(0,0,0) }),
        -- Tracer
        tracer = mkDraw("Line", { Thickness = 1 }),
        -- Dual chams Highlights (CS half/half), created lazily
        chamHid = nil,
        chamVis = nil,
    }
    cache[plr] = e
    return e
end

local function hideEntry(e)
    if not e then return end
    e.box.Visible, e.bg.Visible = false, false
    for _, l in ipairs(e.corners)  do l.Visible = false end
    for _, l in ipairs(e.cube)     do l.Visible = false end
    for _, l in ipairs(e.skeleton) do l.Visible = false end
    e.name.Visible, e.dist.Visible = false, false
    e.hpBg.Visible, e.hpFg.Visible, e.hpOl.Visible = false, false, false
    e.tracer.Visible = false
    if e.chamHid then e.chamHid.Enabled = false end
    if e.chamVis then e.chamVis.Enabled = false end
end
-- Backwards-compat: old name `hide` still used by some logic
local hide = hideEntry

local function destroyEntry(plr)
    local e = cache[plr]; if not e then return end
    pcall(function() e.box:Remove() end)
    pcall(function() e.bg:Remove() end)
    for _, l in ipairs(e.corners)  do pcall(function() l:Remove() end) end
    for _, l in ipairs(e.cube)     do pcall(function() l:Remove() end) end
    for _, l in ipairs(e.skeleton) do pcall(function() l:Remove() end) end
    pcall(function() e.name:Remove() end)
    pcall(function() e.dist:Remove() end)
    pcall(function() e.hpBg:Remove() end)
    pcall(function() e.hpFg:Remove() end)
    pcall(function() e.hpOl:Remove() end)
    pcall(function() e.tracer:Remove() end)
    if e.chamHid then pcall(function() e.chamHid:Destroy() end) end
    if e.chamVis then pcall(function() e.chamVis:Destroy() end) end
    cache[plr] = nil
end

-- =========================================================================
-- Aimbot UI â€” minimal, high-quality tracker
-- =========================================================================
local WHITE = Color3.new(1, 1, 1)

local ag = Tabs.Aim:AddLeftGroupbox("Aimbot")
ag:AddToggle("AimTgl", { Text = "Enable", Default = false }):AddKeyPicker(
    "AimKey", { Default = "None", Mode = "Hold", Text = "Hold key", SyncToggleState = false })
ag:AddSlider("AimFov",    { Text = "FOV (deg)",   Min = 1, Max = 60, Default = 8,  Rounding = 1 })
ag:AddSlider("AimSmooth", { Text = "Smoothness",  Min = 1, Max = 20, Default = 10, Rounding = 0,
    Tooltip = "1 = slow drift, 20 = near-instant snap. ~10 = fast snap." })
ag:AddToggle("AimShow",   { Text = "Show FOV circle", Default = false })
    :AddColorPicker("AimFovColor", { Default = Color3.fromRGB(255, 255, 255), Title = "FOV color" })
ag:AddToggle("AimWall",   { Text = "Wallcheck", Default = true })
ag:AddDropdown("AimPart", {
    Text = "Target part", Default = "Head",
    Values = { "Head", "UpperTorso", "HumanoidRootPart", "LowerTorso", "Nearest" },
})
ag:AddToggle("AimSnap",   { Text = "Snapline", Default = false })
    :AddColorPicker("AimSnapColor", { Default = WHITE })

-- Silent Aim group (upvalue-swap mechanism â€” see modifyPacket comments)
local sg = Tabs.Aim:AddRightGroupbox("Silent Aim")
sg:AddToggle("UvSilent", { Text = "Enable", Default = false,
    Tooltip = "Rewrites ShootWeapon packet's Hits[].Instance to enemy body part." })
    :AddKeyPicker("UvKey", { Default = "None", Mode = "Hold", Text = "Hold key", SyncToggleState = false })
sg:AddSlider("UvFov",        { Text = "FOV (deg)",    Min = 1, Max = 60,  Default = 10, Rounding = 1 })
sg:AddSlider("UvHitChance",  { Text = "Hit chance %", Min = 20, Max = 100, Default = 100, Rounding = 0 })
sg:AddDropdown("UvPart",     { Text = "Target part",  Default = "Head",
    Values = { "Head", "UpperTorso", "HumanoidRootPart", "LowerTorso", "Nearest" } })
sg:AddToggle("UvWall",       { Text = "Wallcheck", Default = true })
sg:AddToggle("UvWallbang",   { Text = "Allow wallbangs", Default = false,
    Tooltip = "ON = shots land through walls. OFF = per-shot LOS gate." })
sg:AddToggle("UvShowFov",    { Text = "Show FOV circle", Default = false })
    :AddColorPicker("UvFovColor", { Default = Color3.fromRGB(255, 80, 80), Title = "FOV color" })
sg:AddToggle("UvSnap",       { Text = "Snapline", Default = false })
    :AddColorPicker("UvSnapColor", { Default = WHITE })
sg:AddToggle("UvDebug",      { Text = "Debug log",       Default = false })

-- =========================================================================
-- Visuals UI â€” per-element toggles, each with own colorpicker
-- =========================================================================
local vg = Tabs.Visuals:AddLeftGroupbox("ESP")

vg:AddToggle("EspMaster",   { Text = "Enable", Default = false })
vg:AddToggle("EspBox",      { Text = "Box",      Default = false }):AddColorPicker("EspBoxColor",     { Default = WHITE })
vg:AddToggle("EspSkeleton", { Text = "Skeleton", Default = false }):AddColorPicker("EspSkelColor",    { Default = WHITE })
vg:AddToggle("EspName",     { Text = "Name",     Default = false }):AddColorPicker("EspNameColor",   { Default = WHITE })
vg:AddToggle("EspDist",     { Text = "Distance", Default = false }):AddColorPicker("EspDistColor",   { Default = WHITE })
vg:AddToggle("EspHealth",   { Text = "Health",   Default = false }):AddColorPicker("EspHealthColor", { Default = WHITE })
vg:AddToggle("EspTracer",   { Text = "Tracer",   Default = false }):AddColorPicker("EspTracerColor", { Default = WHITE })

vg:AddToggle("WallTgl", { Text = "Wallcheck (override colors)", Default = false })
    :AddColorPicker("EspVisColor", { Default = Color3.fromRGB(0, 255, 80), Title = "Visible" })
    :AddColorPicker("EspHidColor", { Default = Color3.fromRGB(255, 60, 60), Title = "Hidden" })

-- Style dropdowns at the bottom (dependency-driven)
local boxDep = vg:AddDependencyBox()
boxDep:AddDropdown("BoxStyle", { Text = "Box style", Default = "Full", Values = { "Full", "Corner", "3D" } })
boxDep:SetupDependencies({ { Toggles.EspBox, true } })

local tracerDep = vg:AddDependencyBox()
tracerDep:AddDropdown("TracerOrigin", { Text = "Tracer origin", Default = "Bottom", Values = { "Top", "Middle", "Bottom" } })
tracerDep:SetupDependencies({ { Toggles.EspTracer, true } })

local cg = Tabs.Visuals:AddRightGroupbox("Chams")
cg:AddToggle("ChamsTgl", { Text = "Enable", Default = false })
    :AddColorPicker("ChamsColor", { Default = Color3.fromRGB(255, 255, 255), Title = "Chams color" })
cg:AddToggle("ChamsVisState", { Text = "Visible state (color by visibility)", Default = false })
    :AddColorPicker("ChamsVisColor", { Default = Color3.fromRGB(0, 255, 80), Title = "Visible" })
    :AddColorPicker("ChamsHidColor", { Default = Color3.fromRGB(255, 60, 60), Title = "Hidden" })
cg:AddSlider("ChamsFillT", { Text = "Fill transparency",    Min = 0, Max = 1, Default = 0.5, Rounding = 2 })
cg:AddSlider("ChamsOutT",  { Text = "Outline transparency", Min = 0, Max = 1, Default = 0,   Rounding = 2 })

-- Bullet tracer (your local shots) â€” separate groupbox on Visuals tab
local btg = Tabs.Visuals:AddRightGroupbox("Bullet Tracer")
btg:AddToggle("BulletTracer", { Text = "Enable", Default = false })
    :AddColorPicker("BulletTracerColor", { Default = WHITE })
btg:AddSlider("BulletTracerDur",   { Text = "Duration (s)", Min = 0.5, Max = 3.0, Default = 0.4, Rounding = 2 })
btg:AddSlider("BulletTracerThick", { Text = "Thickness",    Min = 1,   Max = 8,   Default = 1,   Rounding = 0 })

local fovCircle       = mkDraw("Circle", { NumSides = 64, Thickness = 1, Filled = false, Color = Color3.fromRGB(255,255,255) })
local silentFovCircle = mkDraw("Circle", { NumSides = 64, Thickness = 1, Filled = false, Color = Color3.fromRGB(255, 80, 80) })

-- Snaplines (one for aimbot, one for silent aim)
local aimSnapLine    = mkDraw("Line", { Thickness = 1, Color = WHITE })
local silentSnapLine = mkDraw("Line", { Thickness = 1, Color = WHITE })

-- 3D bullet tracer pool. Reused round-robin. Each entry is a thin Neon Part
-- in workspace, CFrame'd from origin â†’ hit. Fades out by ramping Transparency
-- in the render loop. Parts are parented to a dedicated Folder; CanCollide/
-- CanQuery/CanTouch all off so they can't affect gameplay or raycasts.
local BULLET_TRACER_POOL_SIZE = 32
local bulletTracerFolder = Instance.new("Folder")
bulletTracerFolder.Name   = "_helper_bullet_tracers"
bulletTracerFolder.Parent = workspace

local bulletTracerPool = {}
local bulletTracerNext = 1
for i = 1, BULLET_TRACER_POOL_SIZE do
    local p = Instance.new("Part")
    p.Name         = "BulletTracer" .. i
    p.Anchored     = true
    p.CanCollide   = false
    p.CanQuery     = false
    p.CanTouch     = false
    p.CastShadow   = false
    p.Massless     = true
    p.Material     = Enum.Material.Neon
    p.Color        = Color3.new(1, 1, 1)
    p.Size         = Vector3.new(0.1, 0.1, 1)
    p.Transparency = 1   -- fully invisible until activated
    p.Parent       = bulletTracerFolder
    bulletTracerPool[i] = {
        part   = p,
        t0     = 0,
        active = false,
    }
end

-- Find a world-space muzzle position for the equipped weapon. Bloxstrike uses
-- a Camera-parented viewmodel containing the weapon; we walk the character's
-- equipped Tool first (Handle attachments named FirePoint/Muzzle/Tip), then
-- fall back to scanning Camera descendants for an attachment with one of
-- those names, then to the Handle position + look offset, then nil.
local MUZZLE_ATTACH_NAMES = {
    "FirePoint", "Muzzle", "MuzzlePoint", "Tip", "ShootPoint", "BarrelEnd", "Fire",
}
local function _findMuzzleIn(inst)
    if not inst then return nil end
    for _, name in ipairs(MUZZLE_ATTACH_NAMES) do
        local a = inst:FindFirstChild(name, true)
        if a and a:IsA("Attachment") then return a.WorldPosition end
    end
    return nil
end
-- Forward offset (studs) added past the resolved muzzle so the tracer line
-- visibly leaves the gun instead of starting glued to the screen.
local TRACER_FORWARD_STUDS = 1.5
local function resolveLocalMuzzle()
    local char = LocalPlayer.Character
    if char then
        -- Equipped Tool on character
        local tool = char:FindFirstChildOfClass("Tool")
        if tool then
            local handle = tool:FindFirstChild("Handle")
            local fwd = (handle and handle:IsA("BasePart")) and handle.CFrame.LookVector or Camera.CFrame.LookVector
            local p = _findMuzzleIn(tool)
            if p then return p + fwd * TRACER_FORWARD_STUDS end
            if handle and handle:IsA("BasePart") then
                return handle.Position + fwd * (handle.Size.Z * 0.5 + TRACER_FORWARD_STUDS)
            end
        end
    end
    -- Camera-parented viewmodel (CS-style FPS games like Bloxstrike)
    local fwd = Camera.CFrame.LookVector
    local p = _findMuzzleIn(Camera)
    if p then return p + fwd * TRACER_FORWARD_STUDS end
    for _, d in ipairs(Camera:GetDescendants()) do
        if d:IsA("BasePart") then
            local n = string.lower(d.Name)
            if n:find("barrel") or n:find("muzzle") or n:find("tip") then
                return d.Position + d.CFrame.LookVector * (d.Size.Z * 0.5 + TRACER_FORWARD_STUDS)
            end
        end
    end
    return nil
end

local function spawnBulletTracer(originVec, hitVec)
    if not Toggles.BulletTracer.Value then return end
    if typeof(originVec) ~= "Vector3" or typeof(hitVec) ~= "Vector3" then return end
    local slot = bulletTracerPool[bulletTracerNext]
    bulletTracerNext = (bulletTracerNext % BULLET_TRACER_POOL_SIZE) + 1

    local len = (hitVec - originVec).Magnitude
    if len < 0.01 then return end
    local thick = math.max(0.05, (Options.BulletTracerThick.Value or 1) * 0.05)
    slot.part.Size   = Vector3.new(thick, thick, len)
    slot.part.CFrame = CFrame.lookAt(originVec, hitVec) * CFrame.new(0, 0, -len / 2)
    slot.part.Color  = Options.BulletTracerColor.Value
    slot.part.Transparency = 0
    slot.t0     = tick()
    slot.active = true
end

-- =========================================================================
-- Aimbot logic â€” high-quality mouse-delta tracker
--   - Predictive aim using HRP velocity + lead time
--   - Sub-pixel accumulator (no fractional motion lost)
--   - dt-scaled exponential lerp (frame-rate independent)
--   - Distance-aware easing (faster when far, smoother when close)
--   - Micro-jitter to defeat "perfectly still" tells
-- =========================================================================
local function aimActive()
    if not Toggles.AimTgl.Value then return false end
    local kp = Options.AimKey
    if kp and kp.GetState then return kp:GetState() end
    return true
end

-- Silent aim active gate: ON only if its toggle is on AND (no key bound or key held).
local function silentActive()
    if not Toggles.UvSilent.Value then return false end
    local kp = Options.UvKey
    if kp and kp.GetState then
        -- If user bound a real key, require it held; an unbound keypicker
        -- still has GetState() returning false, so we treat "None"-bound as
        -- always-on by checking the displayed value.
        local v = kp.Value
        if v == nil or v == "None" or v == "" then return true end
        return kp:GetState()
    end
    return true
end

local _lastAimT    = nil
local _accX, _accY = 0, 0   -- sub-pixel accumulator

-- Shared part resolver for Aimbot + Silent Aim. `mode` is one of:
--   "Head", "UpperTorso", "HumanoidRootPart", "LowerTorso", "Nearest"
-- "Nearest" picks the candidate whose 2D screen projection is closest to the
-- screen center (i.e. crosshair). Falls back to Head â†’ UpperTorso â†’ primary.
local AIM_CANDIDATES = { "Head", "UpperTorso", "HumanoidRootPart", "LowerTorso", "Torso" }
local function resolveAimPart(char, mode)
    if not char then return nil end
    if mode and mode ~= "Nearest" then
        local p = char:FindFirstChild(mode)
        if p and p:IsA("BasePart") then return p end
    end
    if mode == "Nearest" then
        local vp = Camera.ViewportSize
        local cx, cy = vp.X / 2, vp.Y / 2
        local best, bestD = nil, math.huge
        for _, name in ipairs(AIM_CANDIDATES) do
            local p = char:FindFirstChild(name)
            if p and p:IsA("BasePart") then
                local s, ok = Camera:WorldToViewportPoint(p.Position)
                if ok and s.Z > 0 then
                    local dx, dy = s.X - cx, s.Y - cy
                    local d = dx * dx + dy * dy
                    if d < bestD then best, bestD = p, d end
                end
            end
        end
        if best then return best end
    end
    return char:FindFirstChild("Head")
        or char:FindFirstChild("UpperTorso")
        or char:FindFirstChild("Torso")
        or char.PrimaryPart
end

-- Updated each frame; consumed by the snapline render block.
local currentAimTarget = nil   -- Character model
local currentAimPart   = nil   -- Part

local function applyAim()
    if not aimActive() then
        _lastAimT = nil
        currentAimTarget, currentAimPart = nil, nil
        return
    end
    local fov = math.rad(Options.AimFov.Value)
    local target = findBest(Camera.CFrame, fov, ESP_MAX_DIST, Toggles.AimWall.Value)
    if not target then
        _lastAimT = nil
        currentAimTarget, currentAimPart = nil, nil
        return
    end

    local part = resolveAimPart(target, Options.AimPart.Value)
    if not part then
        currentAimTarget, currentAimPart = nil, nil
        return
    end

    currentAimTarget, currentAimPart = target, part

    local screen, onScr = Camera:WorldToViewportPoint(part.Position)
    if not onScr or screen.Z <= 0 then
        _lastAimT = nil
        return
    end

    local vp = Camera.ViewportSize
    local pixelDX = screen.X - vp.X / 2
    local pixelDY = screen.Y - vp.Y / 2

    -- Frame-rate-independent dt
    local now = tick()
    local dt = _lastAimT and clamp(now - _lastAimT, 0.0, 0.05) or (1 / 60)
    _lastAimT = now

    -- Half-life lerp: alpha = 1 - 0.5^(dt * smoothness * 2)
    --   smoothness=1  â†’ ~1 s  half-life (drift)
    --   smoothness=10 â†’ ~50 ms half-life
    --   smoothness=20 â†’ ~25 ms half-life (near-instant snap)
    local smooth = clamp(Options.AimSmooth.Value, 1, 20)
    local alpha = clamp(1 - 0.5 ^ (dt * smooth * 2), 0, 1)

    local desiredDx = pixelDX * alpha
    local desiredDy = pixelDY * alpha

    -- Sub-pixel accumulator: keep fractional motion across frames
    _accX = _accX + desiredDx
    _accY = _accY + desiredDy
    local sendX = (_accX >= 0) and math.floor(_accX) or math.ceil(_accX)
    local sendY = (_accY >= 0) and math.floor(_accY) or math.ceil(_accY)
    _accX = _accX - sendX
    _accY = _accY - sendY

    if sendX == 0 and sendY == 0 then return end

    local mm = getMouseMove()
    if mm then pcall(mm, sendX, sendY) end
end

-- Refuse to enable aim if mousemoverel is unavailable.
Toggles.AimTgl:OnChanged(function()
    if Toggles.AimTgl.Value then
        if not getMouseMove() then
            Library:Notify(
                "Aim disabled: executor has no mousemoverel function.\n" ..
                "VirtualInputManager fallback was removed because it bans without working.",
                8
            )
            Toggles.AimTgl:SetValue(false)
        end
    end
end)

-- Cached for the cleanup-from-prior-load block below.
local raknet = (getgenv and getgenv().raknet) or rawget(_G, "raknet")

-- =========================================================================
-- CRITICAL: Clean up any state left over from a previous load of this script.
-- Stale RakNet hooks, BindToRenderStep bindings, or Drawing objects from
-- prior sessions can corrupt packets after this script unloads/reloads,
-- which causes bans on subsequent loads even with "safe" versions.
-- =========================================================================
do
    -- Kill any leftover raknet hooks before installing new ones.
    if type(raknet) == "table" then
        pcall(function() if raknet.remove_send_hook then raknet.remove_send_hook() end end)
        pcall(function() if raknet.remove_receive_hook then raknet.remove_receive_hook() end end)
        pcall(function() if raknet.clear_send_hooks then raknet.clear_send_hooks() end end)
        pcall(function() if raknet.clear_hooks then raknet.clear_hooks() end end)
    end
    -- Kill any leftover BindToRenderStep bindings from previous builds.
    pcall(function() RunService:UnbindFromRenderStep("BloxstrikeAim") end)
    pcall(function() RunService:UnbindFromRenderStep("BloxstrikeESP") end)
end

-- Track every connection we create so we can disconnect on unload.
local connections = {}
local function track(conn) connections[#connections+1] = conn; return conn end
local function disconnectAll()
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    table.clear(connections)
end

-- "dead" flag â€” checked by every hook/connection so leftover invocations
-- after unload become no-ops instead of touching unloaded state.
local scriptAlive = true

-- =========================================================================
-- Silent Aim â€” UPVALUE-SWAP implementation
--
-- Mechanism (verified safe by stealth-recon):
--   Send closure at Network:508 has 5 upvalues. upv[5] is the ShootWeapon
--   RemoteEvent. We replace it with a Lua table that has a :FireServer method.
--   The Send closure's pointer/bytecode/upvalue-count never change. Only one
--   upvalue's VALUE is swapped. Most ACs don't enumerate every closure's
--   upvalues per scan â€” too expensive.
--
--   Game flow: Weapon.shoot builds packet â†’ Network.Send(packet) is called â†’
--   logPacket logs (no-op in production) â†’ u131:FireServer(packet) where u131
--   is now our wrapper table â†’ wrapper rewrites packet.Bullets[].Hits[] â†’
--   wrapper calls realRemote:FireServer(modifiedPacket) â†’ server validates
--   the now-internally-consistent packet â†’ damage applied to enemy.
-- =========================================================================
local uvHookInstalled = false
local uvSendClosure   = nil
local uvRealRemote    = nil  -- saved original ShootWeapon RemoteEvent
local UV_REMOTE_SLOT  = 5

local function pickSilentPart(char)
    return resolveAimPart(char, Options.UvPart.Value)
end

-- Recursively walk a table for "Hits"-array shapes (entries with .Instance + .Position)
local function findHitsArrays(t, out, depth)
    depth = depth or 0
    if type(t) ~= "table" or depth > 6 then return end
    out = out or {}
    if #t > 0 then
        local first = t[1]
        if type(first) == "table"
           and (rawget(first, "Instance") ~= nil or rawget(first, "instance") ~= nil)
           and (rawget(first, "Position") ~= nil or rawget(first, "position") ~= nil) then
            out[#out+1] = t
            return out
        end
    end
    for _, v in pairs(t) do
        if type(v) == "table" then findHitsArrays(v, out, depth + 1) end
    end
    return out
end

-- Recursively walk for Direction Vec3 fields
local function findDirectionContainers(t, out, depth)
    depth = depth or 0
    if type(t) ~= "table" or depth > 6 then return end
    out = out or {}
    for k, v in pairs(t) do
        if (k == "Direction" or k == "direction") and typeof(v) == "Vector3" then
            out[#out+1] = { tbl = t, key = k }
        end
        if type(v) == "table" then findDirectionContainers(v, out, depth + 1) end
    end
    return out
end

local function findShootWeaponSendClosure()
    local _getUps = getupvalues or (debug and debug.getupvalues)
    if not _getUps then return nil end
    for _, fn in ipairs(getgc(true)) do
        if type(fn) == "function" then
            local oks, src = pcall(debug.info, fn, "s")
            if oks and type(src) == "string" and src:find("Network", 1, true) then
                local okn, name = pcall(debug.info, fn, "n")
                if okn and name == "Send" then
                    local oku, ups = pcall(_getUps, fn)
                    if oku and ups then
                        for _, u in ipairs(ups) do
                            if typeof(u) == "Instance" and u.Name == "ShootWeapon" then
                                return fn
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- Updated each render frame. Used by tracer/snapline to retarget the silent
-- aim's chosen body part. Not used by modifyPacket itself (which re-runs
-- target selection per shot for max accuracy).
local currentSilentTarget = nil      -- Character model
local currentSilentPart   = nil      -- Part (head, etc.)

local _enemyDiagDone = false
local function modifyPacket(packet)
    local dbg = Toggles.UvDebug.Value
    if math.random(1, 100) > Options.UvHitChance.Value then
        if dbg then print("[uv-silent] modifyPacket: skipped by hit-chance gate") end
        return false
    end

    -- One-time enemy enumeration so we know if isEnemy is filtering everyone
    if dbg and not _enemyDiagDone then
        _enemyDiagDone = true
        local gm = workspace:GetAttribute("Gamemode")
        local myTeam = LocalPlayer:GetAttribute("Team")
        print(("[uv-silent] gamemode=%s, my team=%s"):format(tostring(gm), tostring(myTeam)))
        for _, plr in ipairs(Players:GetPlayers()) do
            local theirTeam = plr:GetAttribute("Team")
            local enemy = isEnemy(plr)
            local alive, char = isAlive(plr)
            print(("  %-20s team=%s alive=%s isEnemy=%s hasChar=%s"):format(
                plr.Name, tostring(theirTeam), tostring(alive), tostring(enemy), tostring(char ~= nil)))
        end
    end

    local fov = math.rad(Options.UvFov.Value)
    local target = findBest(Camera.CFrame, fov, 500, Toggles.UvWall.Value)
    if not target then
        if dbg then print(("[uv-silent] modifyPacket: NO TARGET (fov=%.1f deg, wallcheck=%s)")
            :format(Options.UvFov.Value, tostring(Toggles.UvWall.Value))) end
        return false
    end
    local part = pickSilentPart(target)
    if not part then
        if dbg then print("[uv-silent] modifyPacket: target found but no aim part") end
        return false
    end

    -- Per-shot LOS gate: only rewrite if AT LEAST ONE body part is visible
    -- from camera. Skipped when "Allow wallbangs" is enabled.
    if not Toggles.UvWallbang.Value then
        if not isVisibleMulti(target, Camera.CFrame.Position) then
            if dbg then print(("[uv-silent] modifyPacket: LOS blocked (target=%s) â€” letting shot miss")
                :format(target.Name)) end
            return false
        end
    end

    if dbg then print(("[uv-silent] modifyPacket: target=%s part=%s"):format(
        target.Name, part:GetFullName())) end

    local mutated = false
    -- Direct path: we know the structure now. packet.Bullets[i].Hits[1] is what we want.
    local bullets = rawget(packet, "Bullets")
    if dbg then
        print(("[uv-silent] packet.Bullets type=%s, len=%d"):format(
            type(bullets), type(bullets) == "table" and #bullets or -1))
    end
    if type(bullets) == "table" then
        for i, bullet in ipairs(bullets) do
            local hits = rawget(bullet, "Hits")
            local origin = rawget(bullet, "Origin")
            if dbg then
                print(("[uv-silent]   Bullet[%d] hits=%s origin=%s"):format(
                    i, type(hits), tostring(origin)))
            end
            if type(hits) == "table" and #hits > 0 then
                local h = hits[1]
                if dbg then
                    print(("[uv-silent]   Bullet[%d] Hits[1].Instance: %s -> %s"):format(
                        i, tostring(rawget(h, "Instance")), part:GetFullName()))
                end
                h.Instance = part
                h.Position = part.Position
                h.Normal   = Vector3.new(0, 1, 0)
                if typeof(origin) == "Vector3" then
                    h.Distance = (part.Position - origin).Magnitude
                end
                h.Exit = false
                -- Material can stay whatever, server probably doesn't care
                mutated = true
            end
            -- Rewrite Direction to point from Origin to enemy part
            if typeof(origin) == "Vector3" then
                bullet.Direction = (part.Position - origin).Unit
            end
        end
    end

    local dirs = findDirectionContainers(packet)
    if dirs then
        for _, d in ipairs(dirs) do
            local origin = rawget(d.tbl, "Origin") or rawget(d.tbl, "origin")
            if typeof(origin) == "Vector3" then
                d.tbl[d.key] = (part.Position - origin).Unit
                mutated = true
            end
        end
    end
    return mutated
end

local function installUpvalueHook()
    if uvHookInstalled then return true end
    if type(setupvalue) ~= "function" then
        return false, "Executor lacks setupvalue"
    end

    local fn = findShootWeaponSendClosure()
    if not fn then
        return false, "Send-for-ShootWeapon closure not found (equip a weapon first)"
    end

    local ups = (getupvalues or debug.getupvalues)(fn)
    local realRemote = ups[UV_REMOTE_SLOT]
    if typeof(realRemote) ~= "Instance" or realRemote.ClassName ~= "RemoteEvent" then
        return false, "upv[5] is not a RemoteEvent (got " .. typeof(realRemote) .. ")"
    end
    if realRemote.Name ~= "ShootWeapon" then
        return false, "upv[5] is not ShootWeapon (got " .. realRemote.Name .. ")"
    end

    uvSendClosure = fn
    uvRealRemote  = realRemote

    -- Build the wrapper.
    local wrapper = {}
    local fireCount = 0
    local dumpedOnce = false

    -- Recursive structure dumper for diagnosing packet shape
    local function dumpVal(v, indent, depth, seen)
        depth = depth or 0
        seen = seen or {}
        if depth > 5 then return "...(maxdepth)" end
        local tn = typeof(v)
        if tn == "Instance" then return ("<%s %s>"):format(v.ClassName, v:GetFullName()) end
        if tn == "Vector3" then return ("Vec3(%.2f,%.2f,%.2f)"):format(v.X, v.Y, v.Z) end
        if tn == "CFrame" then return "CFrame(...)" end
        if tn ~= "table" then
            if tn == "string" then return ("%q"):format(v) end
            return tostring(v) .. " (" .. tn .. ")"
        end
        if seen[v] then return "<cycle>" end
        seen[v] = true
        local lines = { "{" }
        for k, val in pairs(v) do
            lines[#lines+1] = string.rep("  ", depth+1)
                .. "[" .. tostring(k) .. "] = " .. dumpVal(val, indent, depth+1, seen)
        end
        lines[#lines+1] = string.rep("  ", depth) .. "}"
        return table.concat(lines, "\n")
    end

    function wrapper:FireServer(packet)
        fireCount = fireCount + 1
        -- One-time deep dump of first packet to a file (always, regardless of debug toggle)
        if not dumpedOnce and type(packet) == "table" then
            dumpedOnce = true
            local dump = dumpVal(packet, "", 0)
            print("[uv-silent] FIRST PACKET STRUCTURE (also written to uv-packet-dump.txt):")
            print(dump)
            if writefile then
                pcall(writefile, "uv-packet-dump.txt", dump)
            end
            if setclipboard then pcall(setclipboard, dump) end
        end
        if Toggles.UvDebug.Value then
            print(("[uv-silent] wrapper.FireServer called #%d, packet type=%s")
                :format(fireCount, type(packet)))
        end
        if not scriptAlive then
            return uvRealRemote:FireServer(packet)
        end
        if type(packet) == "table" and silentActive() then
            pcall(modifyPacket, packet)
        end
        -- Bullet tracer: spawn AFTER any silent-aim rewrites, so the line
        -- shows where the server actually receives the shot.
        if Toggles.BulletTracer.Value and type(packet) == "table" then
            local bullets = rawget(packet, "Bullets")
            local spawned = 0
            -- Resolve a world-space muzzle position from the equipped Tool on
            -- the local character. We *only* use this for the visual tracer â€”
            -- the packet sent to the server is untouched.
            local muzzle = resolveLocalMuzzle()
            if type(bullets) == "table" then
                for _, b in ipairs(bullets) do
                    local origin = muzzle  -- prefer weapon muzzle for visual
                    local hits = rawget(b, "Hits")
                    local hitPos
                    if type(hits) == "table" and hits[1] then
                        hitPos = rawget(hits[1], "Position")
                    end
                    if not hitPos then
                        local pktOrigin = rawget(b, "Origin")
                        local dir = rawget(b, "Direction")
                        if typeof(pktOrigin) == "Vector3" and typeof(dir) == "Vector3" then
                            hitPos = pktOrigin + dir * 500
                        end
                    end
                    -- Skip drawing this shot if we couldn't resolve a muzzle â€”
                    -- you shouldn't be able to shoot without a weapon anyway.
                    if typeof(origin) == "Vector3" and typeof(hitPos) == "Vector3" then
                        spawnBulletTracer(origin, hitPos)
                        spawned = spawned + 1
                    end
                end
            end
            if Toggles.UvDebug.Value then
                print(("[bullet-tracer] wrapper fired, packet bullets=%s, spawned=%d")
                    :format(type(bullets) == "table" and #bullets or "nil", spawned))
            end
        end
        return uvRealRemote:FireServer(packet)
    end
    setmetatable(wrapper, {
        __index = function(_, k) return uvRealRemote[k] end,
    })

    if type(setstackhidden) == "function" then pcall(setstackhidden, true) end

    -- Perform the swap
    local ok, err = pcall(setupvalue, fn, UV_REMOTE_SLOT, wrapper)
    if not ok then
        return false, "setupvalue failed: " .. tostring(err)
    end

    -- Verify the swap took effect by reading back
    local _readBack = (getupvalue or debug.getupvalue)
    local okR, current = pcall(_readBack, fn, UV_REMOTE_SLOT)
    if okR then
        print(("[uv-silent] post-swap: upv[5] is now %s (wrapper=%s, real=%s)"):format(
            tostring(current), tostring(wrapper), tostring(uvRealRemote)))
        if current ~= wrapper then
            return false, "setupvalue silently failed: upv[5] was not actually replaced"
        end
    else
        print("[uv-silent] could not read back upv[5]: " .. tostring(current))
    end

    uvHookInstalled = true
    return true
end

local function uninstallUpvalueHook()
    if not uvHookInstalled or not uvSendClosure or not uvRealRemote then return end
    pcall(setupvalue, uvSendClosure, UV_REMOTE_SLOT, uvRealRemote)
    uvHookInstalled = false
    uvSendClosure = nil
    uvRealRemote = nil
end

local function ensureWrapperHook(featureName)
    if uvHookInstalled then return true end
    local ok, err = installUpvalueHook()
    if not ok then
        Library:Notify((featureName or "Hook") .. " unavailable: " .. tostring(err), 8)
    end
    return ok
end

Toggles.UvSilent:OnChanged(function()
    if Toggles.UvSilent.Value then
        if ensureWrapperHook("Silent aim") then
            Library:Notify("Silent aim enabled", 3)
        else
            Toggles.UvSilent:SetValue(false)
        end
    end
end)

Toggles.BulletTracer:OnChanged(function()
    if Toggles.BulletTracer.Value then
        if ensureWrapperHook("Bullet tracer") then
            Library:Notify("Bullet tracer enabled (fire a shot to test)", 3)
        else
            Toggles.BulletTracer:SetValue(false)
        end
    end
end)

-- =========================================================================
-- Render-loop helpers
-- =========================================================================
local function tracerOrigin2D(vp)
    local mode = Options.TracerOrigin.Value
    if mode == "Top"    then return V2(vp.X / 2, 0) end
    if mode == "Middle" then return V2(vp.X / 2, vp.Y / 2) end
    return V2(vp.X / 2, vp.Y)  -- Bottom default
end

-- ============================================================================
-- Chams â€” true CS half/half via dual Highlight
-- ============================================================================
--   To force Roblox to render BOTH highlights (instead of de-duping when both
--   share the same Adornee), each Highlight lives in a SEPARATE Folder under
--   gethui()/CoreGui. The AlwaysOnTop "hidden" highlight is created FIRST so
--   it's drawn first; the Occluded "visible" highlight is created SECOND so
--   it overlays the visible portion of the model.
-- ============================================================================
local _hui_ok, _hui = pcall(function() return gethui and gethui() end)
local chamsParent = (_hui_ok and _hui) or game:GetService("CoreGui")

-- Wipe stale folders from previous executions of this script. Old Highlights
-- left adornee'd to viewmodel parts will otherwise survive and color the
-- hands/weapons with the previous version's logic.
for _, c in ipairs(chamsParent:GetChildren()) do
    local n = c.Name
    if n == "_helper_vm_chams" or n == "_helper_chams_hid" or n == "_helper_chams_vis" then
        pcall(function() c:Destroy() end)
    end
end

local chamsFolderHid = Instance.new("Folder")
chamsFolderHid.Name = "_helper_chams_hid"
chamsFolderHid.Parent = chamsParent

local chamsFolderVis = Instance.new("Folder")
chamsFolderVis.Name = "_helper_chams_vis"
chamsFolderVis.Parent = chamsParent

-- Backwards-compat alias used by the unload block
local chamsFolder = chamsFolderHid

local function destroyHid(e)
    if e.chamHid then pcall(function() e.chamHid:Destroy() end); e.chamHid = nil end
end
local function destroyVis(e)
    if e.chamVis then pcall(function() e.chamVis:Destroy() end); e.chamVis = nil end
end

-- We use ONE Highlight per character (`chamHid`, AlwaysOnTop) for both modes.
-- The `chamVis` field is always destroyed in this design â€” it stays here only
-- so legacy hide/destroy code paths keep working.
local function ensureHid(e, char)
    if e.chamHid and e.chamHid.Adornee == char then return e.chamHid end
    destroyHid(e)
    local h = Instance.new("Highlight")
    h.Adornee   = char
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    h.Parent    = chamsFolderHid
    e.chamHid = h
    return h
end

local function applyCham(e, char)
    if not Toggles.ChamsTgl.Value then
        destroyHid(e); destroyVis(e)
        return
    end
    -- Guarantee no Occluded highlight is around â€” its presence breaks the
    -- AlwaysOnTop one in this executor (the bug we keep hitting).
    destroyVis(e)

    local fillT, outT = Options.ChamsFillT.Value, Options.ChamsOutT.Value
    local h = ensureHid(e, char)

    local color
    if Toggles.ChamsVisState.Value then
        -- Whole-model color flips based on character LOS. Picks head visibility
        -- as the representative test (covers the typical peek scenario well).
        local visible = isVisibleMulti(char, Camera.CFrame.Position)
        color = visible and Options.ChamsVisColor.Value or Options.ChamsHidColor.Value
    else
        color = Options.ChamsColor.Value
    end

    h.FillColor             = color
    h.OutlineColor          = color
    h.FillTransparency      = fillT
    h.OutlineTransparency   = outT
    h.Enabled               = true
end

-- 12 edges of a cube (corner-index pairs into the 8-corner array)
local CUBE_EDGES = {
    {1,2},{2,4},{4,3},{3,1},   -- bottom
    {5,6},{6,8},{8,7},{7,5},   -- top
    {1,5},{2,6},{3,7},{4,8},   -- verticals
}

local function drawBox3D(e, char, color)
    local pivot = char:GetPivot()
    -- Skinnier cube: shrink horizontal extents (X/Z) so the box hugs the body.
    local raw   = char:GetExtentsSize()
    local sz    = Vector3.new(raw.X * 0.5, raw.Y, raw.Z * 0.5) * 0.5
    -- 8 corners in local space
    local locals = {
        Vector3.new(-sz.X, -sz.Y, -sz.Z),
        Vector3.new( sz.X, -sz.Y, -sz.Z),
        Vector3.new(-sz.X, -sz.Y,  sz.Z),
        Vector3.new( sz.X, -sz.Y,  sz.Z),
        Vector3.new(-sz.X,  sz.Y, -sz.Z),
        Vector3.new( sz.X,  sz.Y, -sz.Z),
        Vector3.new(-sz.X,  sz.Y,  sz.Z),
        Vector3.new( sz.X,  sz.Y,  sz.Z),
    }
    local screen = {}
    for i, lp in ipairs(locals) do
        local wp = pivot * lp
        local sp, ok = Camera:WorldToViewportPoint(wp)
        if not ok or sp.Z <= 0 then
            for _, l in ipairs(e.cube) do l.Visible = false end
            return
        end
        screen[i] = V2(sp.X, sp.Y)
    end
    for i, edge in ipairs(CUBE_EDGES) do
        local l = e.cube[i]
        l.From, l.To = screen[edge[1]], screen[edge[2]]
        l.Color   = color
        l.Visible = true
    end
end

local function drawBoxCorner(e, cx, cy, width, height, color)
    -- top-left, top-right, bottom-left, bottom-right; 2 lines per corner
    local len = math.max(2, math.min(width, height) * 0.25)
    local x1, y1 = cx - width/2, cy
    local x2, y2 = cx + width/2, cy
    local x3, y3 = cx - width/2, cy + height
    local x4, y4 = cx + width/2, cy + height
    local segs = {
        { V2(x1,y1), V2(x1+len,y1) }, { V2(x1,y1), V2(x1,y1+len) },
        { V2(x2,y2), V2(x2-len,y2) }, { V2(x2,y2), V2(x2,y2+len) },
        { V2(x3,y3), V2(x3+len,y3) }, { V2(x3,y3), V2(x3,y3-len) },
        { V2(x4,y4), V2(x4-len,y4) }, { V2(x4,y4), V2(x4,y4-len) },
    }
    for i, s in ipairs(segs) do
        local l = e.corners[i]
        l.From, l.To = s[1], s[2]
        l.Color   = color
        l.Visible = true
    end
end

local function drawSkeleton(e, char, color)
    for i, pair in ipairs(SKELETON_BONES) do
        local l = e.skeleton[i]
        local p1 = char:FindFirstChild(pair[1])
        local p2 = char:FindFirstChild(pair[2])
        if p1 and p2 and p1:IsA("BasePart") and p2:IsA("BasePart") then
            local s1, ok1 = Camera:WorldToViewportPoint(p1.Position)
            local s2, ok2 = Camera:WorldToViewportPoint(p2.Position)
            if ok1 and ok2 and s1.Z > 0 and s2.Z > 0 then
                l.From, l.To = V2(s1.X, s1.Y), V2(s2.X, s2.Y)
                l.Color   = color
                l.Visible = true
            else
                l.Visible = false
            end
        else
            l.Visible = false
        end
    end
end

local function drawHealthBar(e, cx, cy, width, height, char)
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then
        e.hpBg.Visible, e.hpFg.Visible, e.hpOl.Visible = false, false, false
        return
    end
    local pct = clamp(hum.Health / math.max(1, hum.MaxHealth), 0, 1)
    local barW   = 3
    local x      = cx - width/2 - barW - 2
    local fillH  = math.max(1, math.floor(height * pct))
    e.hpBg.Position = V2(x, cy)
    e.hpBg.Size     = V2(barW, height)
    e.hpFg.Position = V2(x, cy + height - fillH)
    e.hpFg.Size     = V2(barW, fillH)
    -- Color: redâ†’yellowâ†’green
    local r = (pct < 0.5) and 1 or (1 - (pct - 0.5) * 2)
    local gC = (pct < 0.5) and (pct * 2) or 1
    e.hpFg.Color = Color3.new(r, gC, 0)
    e.hpOl.Position = e.hpBg.Position
    e.hpOl.Size     = e.hpBg.Size
    e.hpBg.Visible, e.hpFg.Visible, e.hpOl.Visible = true, true, true
end

-- =========================================================================
-- Single render loop
-- =========================================================================
track(RunService.RenderStepped:Connect(function()
    if not scriptAlive then return end

    -- Aim
    pcall(applyAim)

    -- Update silent-aim target reference (used for tracer retargeting)
    if silentActive() then
        local t = findBest(Camera.CFrame, math.rad(Options.UvFov.Value), ESP_MAX_DIST,
                           Toggles.UvWall.Value)
        if t then
            currentSilentTarget = t
            currentSilentPart   = pickSilentPart(t)
        else
            currentSilentTarget = nil
            currentSilentPart   = nil
        end
    else
        currentSilentTarget = nil
        currentSilentPart   = nil
    end

    -- FOV circles â€” visible iff their Show toggle is on (independent of Enable)
    local vp = Camera.ViewportSize
    local centerX, centerY = vp.X / 2, vp.Y / 2
    local pxPerDeg = (vp.Y / math.tan(math.rad(Camera.FieldOfView) / 2)) / 2

    if Toggles.AimShow.Value then
        fovCircle.Position = V2(centerX, centerY)
        fovCircle.Radius   = math.tan(math.rad(Options.AimFov.Value) / 2) * pxPerDeg
        fovCircle.Color    = Options.AimFovColor.Value
        fovCircle.Visible  = true
    else
        fovCircle.Visible = false
    end

    if Toggles.UvShowFov.Value then
        silentFovCircle.Position = V2(centerX, centerY)
        silentFovCircle.Radius   = math.tan(math.rad(Options.UvFov.Value) / 2) * pxPerDeg
        silentFovCircle.Color    = Options.UvFovColor.Value
        silentFovCircle.Visible  = true
    else
        silentFovCircle.Visible = false
    end

    -- ESP / Visuals â€” per-element toggles, each with own color
    local wallOverride = Toggles.WallTgl.Value
    local visOverride = Options.EspVisColor.Value
    local hidOverride = Options.EspHidColor.Value
    local boxStyle    = Options.BoxStyle.Value
    local camPos      = Camera.CFrame.Position
    local tracerOrig  = tracerOrigin2D(vp)

    local function colorize(baseColor, char)
        if not wallOverride then return baseColor, true end
        local vis = isVisibleMulti(char, camPos)
        return (vis and visOverride or hidOverride), vis
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        if not isEnemy(plr) then
            hideEntry(cache[plr])
        else
            local alive, char = isAlive(plr)
            if not alive or not char.PrimaryPart then
                hideEntry(cache[plr])
            else
                local hrp = char.PrimaryPart
                local dist = (hrp.Position - camPos).Magnitude
                if dist > ESP_MAX_DIST then
                    hideEntry(cache[plr])
                else
                    local head = char:FindFirstChild("Head") or hrp
                    local top, onScr = Camera:WorldToViewportPoint(head.Position + V3(0, 1.5, 0))
                    local bot        = Camera:WorldToViewportPoint(hrp.Position  - V3(0, 3.0, 0))
                    if not onScr or top.Z <= 0 then
                        hideEntry(cache[plr])
                    else
                        local e = getEntry(plr)
                        applyCham(e, char)

                        if not Toggles.EspMaster.Value then
                            -- Master off: hide all ESP drawings but keep chams active.
                            e.box.Visible, e.bg.Visible = false, false
                            for _, l in ipairs(e.corners)  do l.Visible = false end
                            for _, l in ipairs(e.cube)     do l.Visible = false end
                            for _, l in ipairs(e.skeleton) do l.Visible = false end
                            e.name.Visible, e.dist.Visible = false, false
                            e.hpBg.Visible, e.hpFg.Visible, e.hpOl.Visible = false, false, false
                            e.tracer.Visible = false
                        else

                        local height = math.abs(top.Y - bot.Y)
                        local width  = height * 0.55
                        local cx, cy = top.X, math.min(top.Y, bot.Y)

                        -- BOX
                        if Toggles.EspBox.Value then
                            local color = colorize(Options.EspBoxColor.Value, char)
                            if boxStyle == "Full" then
                                e.bg.Position  = V2(cx - width/2, cy)
                                e.bg.Size      = V2(width, height)
                                e.box.Position = e.bg.Position
                                e.box.Size     = e.bg.Size
                                e.box.Color    = color
                                e.bg.Visible, e.box.Visible = true, true
                                for _, l in ipairs(e.corners) do l.Visible = false end
                                for _, l in ipairs(e.cube)    do l.Visible = false end
                            elseif boxStyle == "Corner" then
                                drawBoxCorner(e, cx, cy, width, height, color)
                                e.bg.Visible, e.box.Visible = false, false
                                for _, l in ipairs(e.cube) do l.Visible = false end
                            else
                                drawBox3D(e, char, color)
                                e.bg.Visible, e.box.Visible = false, false
                                for _, l in ipairs(e.corners) do l.Visible = false end
                            end
                        else
                            e.bg.Visible, e.box.Visible = false, false
                            for _, l in ipairs(e.corners) do l.Visible = false end
                            for _, l in ipairs(e.cube)    do l.Visible = false end
                        end

                        -- SKELETON
                        if Toggles.EspSkeleton.Value then
                            drawSkeleton(e, char, colorize(Options.EspSkelColor.Value, char))
                        else
                            for _, l in ipairs(e.skeleton) do l.Visible = false end
                        end

                        -- NAME
                        if Toggles.EspName.Value then
                            e.name.Text     = plr.DisplayName ~= "" and plr.DisplayName or plr.Name
                            e.name.Position = V2(cx, cy - 14)
                            e.name.Color    = colorize(Options.EspNameColor.Value, char)
                            e.name.Visible  = true
                        else e.name.Visible = false end

                        -- DISTANCE
                        if Toggles.EspDist.Value then
                            e.dist.Text     = string.format("[%dm]", math.floor(dist))
                            e.dist.Position = V2(cx, cy + height + 2)
                            e.dist.Color    = colorize(Options.EspDistColor.Value, char)
                            e.dist.Visible  = true
                        else e.dist.Visible = false end

                        -- HEALTH
                        if Toggles.EspHealth.Value then
                            drawHealthBar(e, cx, cy, width, height, char)
                            local tint = colorize(Options.EspHealthColor.Value, char)
                            e.hpOl.Color = tint
                        else
                            e.hpBg.Visible, e.hpFg.Visible, e.hpOl.Visible = false, false, false
                        end

                        -- TRACER
                        if Toggles.EspTracer.Value then
                            local sp, ok = Camera:WorldToViewportPoint(hrp.Position)
                            if ok and sp.Z > 0 then
                                e.tracer.From    = tracerOrig
                                e.tracer.To      = V2(sp.X, sp.Y)
                                e.tracer.Color   = colorize(Options.EspTracerColor.Value, char)
                                e.tracer.Visible = true
                            else
                                e.tracer.Visible = false
                            end
                        else e.tracer.Visible = false end
                        end -- end EspMaster else
                    end
                end
            end
        end
    end

    -- =========================================================================
    -- Aimbot snapline: center of screen â†’ currentAimPart
    -- =========================================================================
    if Toggles.AimSnap.Value and currentAimPart then
        local sp, ok = Camera:WorldToViewportPoint(currentAimPart.Position)
        if ok and sp.Z > 0 then
            aimSnapLine.From    = V2(centerX, centerY)
            aimSnapLine.To      = V2(sp.X, sp.Y)
            aimSnapLine.Color   = Options.AimSnapColor.Value
            aimSnapLine.Visible = true
        else
            aimSnapLine.Visible = false
        end
    else
        aimSnapLine.Visible = false
    end

    -- =========================================================================
    -- Silent-aim snapline: center of screen â†’ currentSilentPart
    -- =========================================================================
    if Toggles.UvSnap.Value and currentSilentPart then
        local sp, ok = Camera:WorldToViewportPoint(currentSilentPart.Position)
        if ok and sp.Z > 0 then
            silentSnapLine.From    = V2(centerX, centerY)
            silentSnapLine.To      = V2(sp.X, sp.Y)
            silentSnapLine.Color   = Options.UvSnapColor.Value
            silentSnapLine.Visible = true
        else
            silentSnapLine.Visible = false
        end
    else
        silentSnapLine.Visible = false
    end

    -- =========================================================================
    -- Bullet tracers: advance pool, fade, recompute screen positions each frame
    -- =========================================================================
    local btDuration = math.max(0.1, Options.BulletTracerDur.Value)
    local now        = tick()
    for _, slot in ipairs(bulletTracerPool) do
        if slot.active then
            local age = now - slot.t0
            if age >= btDuration then
                slot.active = false
                slot.part.Transparency = 1
            else
                slot.part.Transparency = age / btDuration  -- 0 â†’ 1 fade-out
            end
        else
            slot.part.Transparency = 1
        end
    end
end))

track(Players.PlayerRemoving:Connect(destroyEntry))

-- =========================================================================
-- World tab â€” render tweaks, ambience, cleanup, viewmodel chams
-- =========================================================================
local Lighting = game:GetService("Lighting")

-- Render groupbox -----------------------------------------------------------
local wrg = Tabs.World:AddLeftGroupbox("Render")
-- NOTE: aspect-ratio slider was removed â€” Roblox doesn't expose viewport
-- stretching from a script, only vertical FOV, so a "stretched res" feel
-- isn't reachable here. Use Roblox's own GraphicsQualityLevel / fullscreen
-- aspect-ratio override instead.
wrg:AddToggle("WorldForceFov", { Text = "Force FOV", Default = false })
wrg:AddSlider("WorldFov", { Text = "FOV", Min = 60, Max = 120, Default = 70, Rounding = 0 })

-- Ambience groupbox ---------------------------------------------------------
local wam = Tabs.World:AddRightGroupbox("Ambience")
wam:AddToggle("AmbOn", { Text = "Override Lighting", Default = false })
    :AddColorPicker("AmbColor", { Default = Color3.fromRGB(140, 140, 160), Title = "Ambient color" })
wam:AddSlider("AmbBrightness", { Text = "Brightness", Min = 0, Max = 5, Default = 1, Rounding = 2 })
wam:AddSlider("AmbClockTime",  { Text = "ClockTime",  Min = 0, Max = 24, Default = 14, Rounding = 1 })
wam:AddToggle("AmbFog", { Text = "Custom fog", Default = false })
    :AddColorPicker("AmbFogColor", { Default = Color3.fromRGB(180, 180, 200), Title = "Fog color" })
wam:AddSlider("AmbFogStart", { Text = "Fog start", Min = 0,    Max = 1000, Default = 0,   Rounding = 0 })
wam:AddSlider("AmbFogEnd",   { Text = "Fog end",   Min = 50,   Max = 5000, Default = 1000,Rounding = 0 })
wam:AddSlider("AmbSat",      { Text = "Saturation", Min = -1, Max = 1, Default = 0, Rounding = 2 })
wam:AddSlider("AmbCon",      { Text = "Contrast",   Min = -1, Max = 1, Default = 0, Rounding = 2 })
wam:AddLabel("Tint"):AddColorPicker("AmbTint", { Default = Color3.new(1,1,1), Title = "Tint" })

-- Cleanup groupbox ----------------------------------------------------------
local wcl = Tabs.World:AddRightGroupbox("Cleanup")
wcl:AddToggle("WorldKillSmokes",   { Text = "Remove smoke/flash GUIs", Default = false })
wcl:AddToggle("WorldSmokeDebug",   { Text = "Debug: log new GUIs", Default = false,
    Tooltip = "Logs every new ScreenGui/Frame/etc added under PlayerGui â€” trigger a smoke/flash, copy names from console" })
wcl:AddToggle("WorldHideViewmodel",{ Text = "Hide hands/gloves only", Default = false })

-- Viewmodel chams groupbox --------------------------------------------------
local wvc = Tabs.World:AddLeftGroupbox("Viewmodel Chams")
wvc:AddToggle("VmHandsTgl", { Text = "Hand chams (incl. gloves)", Default = false })
    :AddColorPicker("VmHandsColor", { Default = Color3.fromRGB(120, 200, 255), Title = "Hand color" })
wvc:AddToggle("VmWeaponTgl", { Text = "Weapon chams", Default = false })
    :AddColorPicker("VmWeaponColor", { Default = Color3.fromRGB(255, 180, 60), Title = "Weapon color" })
wvc:AddToggle("VmDebug", { Text = "Debug: log viewmodel parts", Default = false,
    Tooltip = "Once per second prints unique BasePart names found under Camera. Use to identify glove names" })

-- Lighting AC bypass --------------------------------------------------------
local wac = Tabs.World:AddLeftGroupbox("Anticheat")
wac:AddToggle("WorldAcBypass", { Text = "Lighting AC bypass (experimental)", Default = false, Risky = true,
    Tooltip = "Hooks __namecall and silently swallows FireServer/InvokeServer calls whose args mention Lighting/Mod/Cheat. Watch the debug log first" })
wac:AddToggle("WorldAcDebug",  { Text = "Debug: log all FireServer", Default = false,
    Tooltip = "Prints every FireServer/InvokeServer call (remote name + first arg) so you can identify the AC reporter" })

-- ============================================================================
-- World implementations
-- ============================================================================

-- Save originals so we can fully revert on unload / disable.
local _origFov    = Camera.FieldOfView
local _origAspect = nil  -- we don't actually mutate viewport; aspect is FOV-based
local _origLight  = {
    Ambient        = Lighting.Ambient,
    OutdoorAmbient = Lighting.OutdoorAmbient,
    Brightness     = Lighting.Brightness,
    ClockTime      = Lighting.ClockTime,
    FogColor       = Lighting.FogColor,
    FogStart       = Lighting.FogStart,
    FogEnd         = Lighting.FogEnd,
}

local _ccEffect          -- injected ColorCorrectionEffect (nil when off)
local _vmHidden = {}     -- [BasePart] = originalLocalTransparencyModifier
local _hideVmConn        -- Camera.DescendantAdded connection for live hides
local _killSmokesConn    -- PlayerGui.DescendantAdded connection
local _killWsConn        -- workspace.DescendantAdded connection (voxel smoke)

local GUI_FLASH_PATTERNS = {
    "flash", "flashbang", "blind", "vision", "stun", "concuss",
    "screenshot",                  -- FlashScreenshot / ScreenshotImage
}
local WS_SMOKE_PATTERNS = {
    "voxelsmoke", "smokevoxel", "smokecloud", "smokepart",
    "smoke", "voxel",              -- broad fallback, workspace-only
    "flashpart",                   -- some games render flash light as a part
}
local function nameMatchesAny(name, list)
    if type(name) ~= "string" then return false end
    local n = string.lower(name)
    for _, p in ipairs(list) do
        if n:find(p, 1, true) then return true end
    end
    return false
end
local function nameMatchesSmokeOrFlash(name)  -- legacy: still used by debug logger
    return nameMatchesAny(name, GUI_FLASH_PATTERNS) or nameMatchesAny(name, WS_SMOKE_PATTERNS)
end

-- Aggressive flash kill: destroy GUI, also disable rendering on parents in case
-- the game guards against destroy by re-adding (we re-disable on every fire).
local function killFlashGui(d)
    pcall(function()
        if d:IsA("GuiObject") then d.Visible = false end
        if d:IsA("ScreenGui") then d.Enabled = false end
        d:Destroy()
    end)
end

local function sweepSmokesAndFlashes()
    -- 1. PlayerGui flashes
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then
        for _, d in ipairs(pg:GetDescendants()) do
            if nameMatchesAny(d.Name, GUI_FLASH_PATTERNS) then
                killFlashGui(d)
            end
        end
    end
    -- 2. Workspace voxel smoke (parts/folders named VoxelSmoke etc.)
    for _, d in ipairs(workspace:GetDescendants()) do
        if (d:IsA("BasePart") or d:IsA("Folder") or d:IsA("Model"))
           and nameMatchesAny(d.Name, WS_SMOKE_PATTERNS) then
            -- For BaseParts, hide rather than destroy first (some games rebuild
            -- destroyed voxels on every server tick â€” invisibility is enough).
            if d:IsA("BasePart") then
                pcall(function()
                    d.Transparency = 1
                    d.CanCollide = false
                    d.CanQuery = false
                    d.LocalTransparencyModifier = 1
                end)
            else
                pcall(function() d:Destroy() end)
            end
        end
    end
end

-- Structural classifier: in this game every viewmodel is shaped as
--   Camera.<WeaponName> (Model)
--     â”œâ”€â”€ Weapon        (Model/Folder, every gun/knife mesh lives here)
--     â”œâ”€â”€ Interactables (Model, holds MuzzlePart, etc.)
--     â”œâ”€â”€ DummyParts    (Model, animation dummies â€” render but ARE the weapon)
--     â”œâ”€â”€ HumanoidRootPart
--     â””â”€â”€ Left Arm / Right Arm / their children (the player's hands+gloves)
-- So "is this part a HAND?" == "is this part NOT inside a weapon-side container?"
-- This is far more reliable than name matching, which misses cream untextured
-- arm parts and double-tags Handle/HandGuard as hands.
local WEAPON_CONTAINERS = {
    Weapon = true, Interactables = true, DummyParts = true,
}
-- Some games (this one for the knife) put arm placeholder MeshParts under
-- DummyParts and only the Motor6D child reveals their role (e.g.
-- DummyParts.CameraModel1 has a Motor6D named "Left Arm"). Detect that.
-- Only match the EXACT joint names the engine uses for player arm anchors.
-- Substring matching falsely flagged things like ChargingHandle / Forearm
-- guides on guns.
local ARM_JOINT_NAMES = {
    ["left arm"]  = true,
    ["right arm"] = true,
    ["lefthand"]  = true,
    ["righthand"] = true,
    ["leftglove"] = true,
    ["rightglove"]= true,
}
local function partHasArmJointChild(part)
    for _, c in ipairs(part:GetChildren()) do
        if c:IsA("Motor6D") or c:IsA("Weld") or c:IsA("ManualWeld") then
            if ARM_JOINT_NAMES[string.lower(c.Name)] then return true end
        end
    end
    return false
end

local function VM_isArmPart(part)
    if part.Name == "HumanoidRootPart" then return false end
    -- Joint-name override: if this part has an arm-named Motor6D/Weld child,
    -- it's an arm placeholder regardless of where it sits in the hierarchy.
    if partHasArmJointChild(part) then return true end
    local p = part.Parent
    while p and p ~= Camera do
        if WEAPON_CONTAINERS[p.Name] then return false end
        p = p.Parent
    end
    return true
end

-- Forward-declared so the __newindex hook below can reference it without
-- the hideVmDescendant closure capturing nil.
local _hookedHands = setmetatable({}, { __mode = "k" })  -- weak keys

-- _vmHidden[part] = { ltm, t, size } â€” guns hide via Transparency alone, but
-- the knife arms have a child SurfaceAppearance that ignores Transparency.
-- We additionally (a) shrink Size to ~0 and (b) detach SurfaceAppearance
-- children, restoring both on toggle-off. Welds use CFrame so the weapon
-- pose isn't affected by Size.
local TINY_SIZE = Vector3.new(0.001, 0.001, 0.001)
-- _vmStashedSurfaces[surfaceAppearance] = originalParent
local _vmStashedSurfaces = {}

local function stashSurfaceAppearancesOf(part)
    for _, c in ipairs(part:GetChildren()) do
        if c:IsA("SurfaceAppearance") and _vmStashedSurfaces[c] == nil then
            _vmStashedSurfaces[c] = c.Parent
            pcall(function() c.Parent = nil end)
        end
    end
end

local function hideVmDescendant(inst)
    if inst:IsA("BasePart") and VM_isArmPart(inst) then
        if _vmHidden[inst] == nil then
            _vmHidden[inst] = {
                ltm  = inst.LocalTransparencyModifier,
                t    = inst.Transparency,
                size = inst.Size,
            }
        end
        _hookedHands[inst] = true
        inst.LocalTransparencyModifier = 1
        inst.Transparency = 1
        pcall(function() inst.Size = TINY_SIZE end)
        stashSurfaceAppearancesOf(inst)
    end
end

-- The viewmodel animator writes Transparency / LocalTransparencyModifier
-- from C-side after every Lua callback (RenderStepped, BindToRenderStep with
-- priority Last, etc.) for character body parts in first person, so simply
-- pinning the value every frame is not enough on the knife. We instead hook
-- __newindex on `game` and silently swallow writes to those properties on
-- any BasePart we've classified as a hand-side viewmodel part.
local _hideHookInstalled = false
local function installHidewriteHook()
    if _hideHookInstalled then return end
    local ok, err = pcall(function()
        local function blocker(oldNi, self, key, value)
            if _hookedHands[self] and (key == "Transparency" or key == "LocalTransparencyModifier") then
                return oldNi(self, key, 1)
            end
            return oldNi(self, key, value)
        end
        if hookmetamethod then
            local oldNi
            oldNi = hookmetamethod(game, "__newindex", function(self, k, v) return blocker(oldNi, self, k, v) end)
        else
            local mt = getrawmetatable(game)
            local oldNi = mt.__newindex
            setreadonly(mt, false)
            mt.__newindex = newcclosure(function(self, k, v) return blocker(oldNi, self, k, v) end)
            setreadonly(mt, true)
        end
        _hideHookInstalled = true
    end)
    if not ok then
        warn("[hide-vm] hook install FAILED: " .. tostring(err))
    end
end

local function applyHideViewmodel(on)
    if on then
        installHidewriteHook()
        if _hideVmConn then _hideVmConn:Disconnect() end
        for _, d in ipairs(Camera:GetDescendants()) do hideVmDescendant(d) end
        _hideVmConn = Camera.DescendantAdded:Connect(hideVmDescendant)
    else
        if _hideVmConn then _hideVmConn:Disconnect(); _hideVmConn = nil end
        -- Disengage the __newindex hook for these parts BEFORE writing the
        -- restore values, otherwise the hook would slam them back to 1.
        for part in pairs(_hookedHands) do _hookedHands[part] = nil end
        for sa, origParent in pairs(_vmStashedSurfaces) do
            if sa and origParent and origParent.Parent then
                pcall(function() sa.Parent = origParent end)
            end
            _vmStashedSurfaces[sa] = nil
        end
        for part, orig in pairs(_vmHidden) do
            if part and part.Parent and type(orig) == "table" then
                pcall(function()
                    part.LocalTransparencyModifier = orig.ltm or 0
                    part.Transparency              = orig.t   or 0
                    if orig.size then part.Size    = orig.size end
                end)
            end
        end
        _vmHidden = {}
    end
end

-- Viewmodel chams: dedicated folder + one Highlight per part group.
local vmChamsFolder = Instance.new("Folder")
vmChamsFolder.Name = "_helper_vm_chams"
vmChamsFolder.Parent = chamsParent

local _vmHandHighlights   = {}  -- [BasePart] = Highlight
local _vmWeaponHighlights = {}  -- [BasePart] = Highlight

local function destroyHighlights(tbl)
    for p, h in pairs(tbl) do
        pcall(function() h:Destroy() end)
        tbl[p] = nil
    end
end

local function applyVmChams()
    local wantHand = Toggles.VmHandsTgl.Value
    local wantWep  = Toggles.VmWeaponTgl.Value
    if not wantHand and not wantWep then
        destroyHighlights(_vmHandHighlights)
        destroyHighlights(_vmWeaponHighlights)
        return
    end
    local handColor = Options.VmHandsColor.Value
    local wepColor  = Options.VmWeaponColor.Value

    -- If Hide Viewmodel is on, suppress hand chams on parts we're hiding â€”
    -- otherwise the Highlight renders the cream fill color over an invisible
    -- arm and looks like the arm is still there.
    local hidingHands = Toggles.WorldHideViewmodel.Value
    local seenHand, seenWep = {}, {}
    for _, d in ipairs(Camera:GetDescendants()) do
        if d:IsA("BasePart") then
            local isArm = VM_isArmPart(d)
            if isArm and wantHand and not hidingHands then
                seenHand[d] = true
                local h = _vmHandHighlights[d]
                if not h or h.Adornee ~= d then
                    if h then pcall(function() h:Destroy() end) end
                    h = Instance.new("Highlight")
                    h.Adornee   = d
                    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    h.Parent    = vmChamsFolder
                    _vmHandHighlights[d] = h
                end
                h.FillColor = handColor
                h.OutlineColor = handColor
                h.FillTransparency = 0
                h.OutlineTransparency = 1
                h.Enabled = true
            elseif (not isArm) and wantWep then
                seenWep[d] = true
                local h = _vmWeaponHighlights[d]
                if not h or h.Adornee ~= d then
                    if h then pcall(function() h:Destroy() end) end
                    h = Instance.new("Highlight")
                    h.Adornee   = d
                    -- Occluded so the player's hands (which use AlwaysOnTop)
                    -- visually cover the weapon where they overlap.
                    h.DepthMode = Enum.HighlightDepthMode.Occluded
                    h.Parent    = vmChamsFolder
                    _vmWeaponHighlights[d] = h
                end
                h.FillColor = wepColor
                h.OutlineColor = wepColor
                h.FillTransparency = 0
                h.OutlineTransparency = 1
                h.Enabled = true
            end
        end
    end
    for p, h in pairs(_vmHandHighlights) do
        if not seenHand[p] then pcall(function() h:Destroy() end); _vmHandHighlights[p] = nil end
    end
    for p, h in pairs(_vmWeaponHighlights) do
        if not seenWep[p] then pcall(function() h:Destroy() end); _vmWeaponHighlights[p] = nil end
    end
end

-- Per-frame world driver -----------------------------------------------------
-- Property writes are equality-gated to avoid 7-8 redundant Roblox property
-- updates per frame when the user's settings haven't changed.
track(RunService.RenderStepped:Connect(function()
    if Toggles.WorldForceFov.Value then
        local fov = Options.WorldFov.Value
        if Camera.FieldOfView ~= fov then Camera.FieldOfView = fov end
    end

    if Toggles.AmbOn.Value then
        local c = Options.AmbColor.Value
        if Lighting.Ambient        ~= c then Lighting.Ambient        = c end
        if Lighting.OutdoorAmbient ~= c then Lighting.OutdoorAmbient = c end
        local b = Options.AmbBrightness.Value
        if Lighting.Brightness     ~= b then Lighting.Brightness     = b end
        local t = Options.AmbClockTime.Value
        if Lighting.ClockTime      ~= t then Lighting.ClockTime      = t end
    end
    if Toggles.AmbFog.Value then
        local fc = Options.AmbFogColor.Value
        if Lighting.FogColor ~= fc then Lighting.FogColor = fc end
        local fs = Options.AmbFogStart.Value
        if Lighting.FogStart ~= fs then Lighting.FogStart = fs end
        local fe = Options.AmbFogEnd.Value
        if Lighting.FogEnd   ~= fe then Lighting.FogEnd   = fe end
    end

    local sat, con, tint = Options.AmbSat.Value, Options.AmbCon.Value, Options.AmbTint.Value
    local neutralTint = (tint.R > 0.99 and tint.G > 0.99 and tint.B > 0.99)
    local active = (math.abs(sat) > 0.001) or (math.abs(con) > 0.001) or (not neutralTint)
    if active then
        if not _ccEffect or not _ccEffect.Parent then
            _ccEffect = Instance.new("ColorCorrectionEffect")
            _ccEffect.Name = "_helper_cc"
            _ccEffect.Parent = Lighting
        end
        if _ccEffect.Saturation ~= sat  then _ccEffect.Saturation = sat  end
        if _ccEffect.Contrast   ~= con  then _ccEffect.Contrast   = con  end
        if _ccEffect.TintColor  ~= tint then _ccEffect.TintColor  = tint end
    elseif _ccEffect then
        pcall(function() _ccEffect:Destroy() end)
        _ccEffect = nil
    end

    -- Viewmodel chams: only iterate Camera when at least one toggle is on.
    -- The early-return inside applyVmChams already covers the off case but
    -- skipping the call entirely avoids the table allocations for seenHand/Wep.
    if Toggles.VmHandsTgl.Value or Toggles.VmWeaponTgl.Value then
        applyVmChams()
    elseif next(_vmHandHighlights) or next(_vmWeaponHighlights) then
        applyVmChams()  -- one final call to clean up leftover highlights
    end
end))

-- Hooks that don't need to run every frame.
Toggles.AmbOn:OnChanged(function()
    if not Toggles.AmbOn.Value then
        Lighting.Ambient        = _origLight.Ambient
        Lighting.OutdoorAmbient = _origLight.OutdoorAmbient
        Lighting.Brightness     = _origLight.Brightness
        Lighting.ClockTime      = _origLight.ClockTime
    end
end)
Toggles.AmbFog:OnChanged(function()
    if not Toggles.AmbFog.Value then
        Lighting.FogColor = _origLight.FogColor
        Lighting.FogStart = _origLight.FogStart
        Lighting.FogEnd   = _origLight.FogEnd
    end
end)
local _smokeDebugConn
local function rebuildSmokeHooks()
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if _killSmokesConn then _killSmokesConn:Disconnect(); _killSmokesConn = nil end
    if _killWsConn     then _killWsConn:Disconnect();     _killWsConn = nil end
    if _smokeDebugConn then _smokeDebugConn:Disconnect(); _smokeDebugConn = nil end
    if Toggles.WorldKillSmokes.Value then
        sweepSmokesAndFlashes()
        if pg then
            _killSmokesConn = pg.DescendantAdded:Connect(function(d)
                if nameMatchesAny(d.Name, GUI_FLASH_PATTERNS) then
                    killFlashGui(d)
                end
            end)
        end
        _killWsConn = workspace.DescendantAdded:Connect(function(d)
            if d:IsA("BasePart") and nameMatchesAny(d.Name, WS_SMOKE_PATTERNS) then
                task.defer(function()
                    pcall(function()
                        d.Transparency = 1
                        d.CanCollide = false
                        d.CanQuery = false
                        d.LocalTransparencyModifier = 1
                    end)
                end)
            end
        end)
    end
    if Toggles.WorldSmokeDebug.Value and pg then
        _smokeDebugConn = pg.DescendantAdded:Connect(function(d)
            print(("[smoke-debug] %s :: %s"):format(d.ClassName, d.Name))
        end)
    end
end
Toggles.WorldKillSmokes:OnChanged(rebuildSmokeHooks)
Toggles.WorldSmokeDebug:OnChanged(rebuildSmokeHooks)
Toggles.WorldHideViewmodel:OnChanged(function()
    applyHideViewmodel(Toggles.WorldHideViewmodel.Value)
end)

-- ----------------------------------------------------------------------------
-- VM debug logger: once per second, prints unique BasePart names found under
-- Camera. Use to identify the glove's actual part name.
-- ----------------------------------------------------------------------------
do
    local lastT = 0
    local seen = {}
    track(RunService.RenderStepped:Connect(function()
        if not Toggles.VmDebug.Value then return end
        local now = tick()
        if now - lastT < 1 then return end
        lastT = now
        local fresh = {}
        for _, d in ipairs(Camera:GetDescendants()) do
            if d:IsA("BasePart") then
                local key = d:GetFullName()
                if not seen[key] then
                    seen[key] = true
                    fresh[#fresh+1] = key .. (VM_isArmPart(d) and "  [HAND]" or "  [WEAPON]")
                end
            end
        end
        if #fresh > 0 then
            print("[vm-debug] new viewmodel parts:\n  " .. table.concat(fresh, "\n  "))
        end
    end))
end

-- ----------------------------------------------------------------------------
-- Lighting AC bypass: hook __namecall to filter FireServer / InvokeServer
-- calls whose first string arg looks anti-cheat related.
-- ----------------------------------------------------------------------------
local AC_KEYWORDS = { "lighting", "mod", "cheat", "anticheat", "detect", "violation" }
local function argLooksLikeAcReport(arg)
    if type(arg) ~= "string" then return false end
    local s = string.lower(arg)
    for _, kw in ipairs(AC_KEYWORDS) do
        if s:find(kw, 1, true) then return true end
    end
    return false
end

local _hookInstalled = false
local function installAcHook()
    if _hookInstalled then return end
    if not (hookmetamethod and getnamecallmethod) then
        warn("[ac-bypass] executor missing hookmetamethod/getnamecallmethod â€” bypass unavailable")
        return
    end
    _hookInstalled = true
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        if method == "FireServer" or method == "InvokeServer" then
            local args = { ... }
            -- Debug logger
            if Toggles.WorldAcDebug.Value then
                local first = args[1]
                local firstDesc = type(first) == "string"
                    and ('"' .. (#first > 80 and first:sub(1,80).."â€¦" or first) .. '"')
                    or type(first)
                pcall(function()
                    print(("[ac-debug] %s :: %s(%s)"):format(self:GetFullName(), method, firstDesc))
                end)
            end
            -- Bypass: swallow if any arg matches AC keywords OR remote name does
            if Toggles.WorldAcBypass.Value then
                local rname = ""
                pcall(function() rname = string.lower(self.Name or "") end)
                local block = false
                for _, kw in ipairs(AC_KEYWORDS) do
                    if rname:find(kw, 1, true) then block = true; break end
                end
                if not block then
                    for i = 1, math.min(#args, 4) do
                        if argLooksLikeAcReport(args[i]) then block = true; break end
                    end
                end
                if block then
                    if Toggles.WorldAcDebug.Value then
                        print("[ac-bypass] BLOCKED " .. self:GetFullName())
                    end
                    return  -- silently swallow
                end
            end
        end
        return oldNamecall(self, ...)
    end)
end
-- Install lazily on first use of either AC toggle.
Toggles.WorldAcBypass:OnChanged(function()
    if Toggles.WorldAcBypass.Value then installAcHook() end
end)
Toggles.WorldAcDebug:OnChanged(function()
    if Toggles.WorldAcDebug.Value then installAcHook() end
end)

-- =========================================================================
-- Config
-- =========================================================================
local cn = Tabs.Conf:AddLeftGroupbox("Menu")
cn:AddButton({ Text = "Unload", Func = function() Library:Unload() end })
cn:AddLabel("Menu key"):AddKeyPicker("MenuKey", { Default = "End", NoUI = true, Text = "Toggle" })
Library.ToggleKeybind = Options.MenuKey

SaveManager:IgnoreThemeSettings()
-- CRITICAL: never auto-restore aim toggles or master toggles from saved config.
-- A saved AimTgl=true would activate the aimbot the instant the GUI loads,
-- which is exactly what's been getting fresh alts banned in-match.
SaveManager:SetIgnoreIndexes({
    "MenuKey",
    "AimTgl", "AimKey",                   -- aimbot MUST start off every session
    "UvSilent", "UvKey",                  -- silent aim MUST start off every session
    "ChamsTgl",                           -- chams starts off
    "AimSnap", "UvSnap",                  -- snaplines start off
    "BulletTracer",                       -- bullet tracer starts off
    "WorldAcBypass", "WorldAcDebug",      -- AC hook stays off until user opts in
    "WorldHideViewmodel",                 -- viewmodel restored fresh
    "VmHandsTgl", "VmWeaponTgl",          -- viewmodel chams off
    "AmbOn", "AmbFog",                    -- lighting overrides off (kicks without bypass)
    "SkinsEnabled",                       -- skin changer off until user opts in
})

ThemeManager:SetFolder("helper")
SaveManager:SetFolder("helper/configs")

-- Apply theme tab BEFORE building the config section so theme controls appear first
-- (this is the canonical JopLib example order).
ThemeManager:ApplyToTab(Tabs.Conf)
SaveManager:BuildConfigSection(Tabs.Conf)

-- Autoload config + theme. Both must be called explicitly; `LoadAutoloadConfig`
-- does NOT pull in the theme when `IgnoreThemeSettings` is set.
SaveManager:LoadAutoloadConfig()
ThemeManager:LoadAutoloadTheme()

-- ============================================================================
-- Skin Changer
-- ----------------------------------------------------------------------------
-- Uses ReplicatedStorage.Database.Components.Libraries.Skins to clone the
-- camera-side model of any weapon+skin combo, and replaces the live viewmodel
-- with that clone on equip. Name preserved so game LocalScripts that look up
-- the viewmodel by name (e.g. workspace.CurrentCamera["CT Knife"]) still hit
-- our replacement. Cross-weapon disguises (e.g. CT Knife â†’ Karambit) bring
-- their own AnimationController so animations work correctly.
-- ============================================================================
local SkinsLib do
    local rs = game:GetService("ReplicatedStorage")
    local lib = rs:FindFirstChild("Database")
    lib = lib and lib:FindFirstChild("Components")
    lib = lib and lib:FindFirstChild("Libraries")
    lib = lib and lib:FindFirstChild("Skins")
    if lib then
        local ok, mod = pcall(require, lib)
        if ok then SkinsLib = mod end
    end
    print("[skins] SkinsLib loaded:", SkinsLib ~= nil,
          "GetCameraModel:", SkinsLib and SkinsLib.GetCameraModel ~= nil,
          "GetAllSkinsForWeapon:", SkinsLib and SkinsLib.GetAllSkinsForWeapon ~= nil)
end

-- Categorized weapon list. Keys = group display name, values = weapon names.
-- Grenades are intentionally omitted (no skin variants).
local SKIN_GROUPS = {
    { name = "Knives",   items = { "Butterfly Knife","CT Knife","Flip Knife","Gut Knife","Karambit","M9 Bayonet","Skeleton Knife","Stiletto Knife","T Knife" } },
    { name = "Gloves",   items = { "CT Glove","Driver Gloves","Hand Wraps","Operator Gloves","Sports Gloves","T Glove" } },
    { name = "Rifles",   items = { "AK-47","AUG","FAMAS","Galil AR","M4A1-S","M4A4","SG 553" } },
    { name = "SMGs",     items = { "MAC-10","MP9","P90" } },
    { name = "Snipers",  items = { "AWP","SSG 08" } },
    { name = "Pistols",  items = { "Desert Eagle","Dual Berettas","Five-SeveN","Glock-18","P250","R8 Revolver","Tec-9","USP-S" } },
    { name = "Shotguns", items = { "MAG-7","Nova","Sawed-Off","XM1014" } },
    { name = "Heavy",    items = { "Negev","Zeus x27" } },
}

-- weapon -> category lookup
local _weaponCategory = {}
for _, g in ipairs(SKIN_GROUPS) do
    for _, w in ipairs(g.items) do _weaponCategory[w] = g.name end
end

-- For each category build a flat list of "<Weapon> | <SkinName>" labels by
-- querying GetAllSkinsForWeapon on every weapon in the category. Picking
-- "AK-47 | Asiimov" in the Rifles dropdown means: whenever the user equips
-- any rifle, replace its viewmodel with an AK-47 Asiimov clone.
local _categoryLabels = {}            -- [category] = { "Default", "AK-47 | Asiimov", ... }
local _labelToTuple   = {}            -- [label]    = { weapon=, skin= }
local _skinChoice     = {}            -- [category] = { weapon=, skin= }  (selected)

local function _enumerateSkins()
    for _, g in ipairs(SKIN_GROUPS) do
        _categoryLabels[g.name] = { "Default" }
        local count = 0
        for _, w in ipairs(g.items) do
            if SkinsLib and SkinsLib.GetAllSkinsForWeapon then
                local ok, list = pcall(SkinsLib.GetAllSkinsForWeapon, w)
                if ok and type(list) == "table" then
                    for _, s in ipairs(list) do
                        local n, pid
                        if type(s) == "string" then n = s
                        elseif type(s) == "table" then
                            n   = s.skin or s.Name or s.DisplayName or s.Id
                            pid = s.paintId
                        end
                        if n then
                            local label = w .. " | " .. tostring(n)
                            table.insert(_categoryLabels[g.name], label)
                            _labelToTuple[label] = {
                                weapon = w,
                                skin = tostring(n),
                                paintId = pid,
                            }
                            count = count + 1
                        end
                    end
                else
                    print(("[skins] GetAllSkinsForWeapon failed for %q: %s"):format(w, tostring(list)))
                end
            end
        end
        print(("[skins] category %-9s: %d skin options"):format(g.name, count))
    end
end
_enumerateSkins()

-- Hook SkinsLib.GetCameraModel / GetCharacterModel / GetWorldModel so the
-- game's own viewmodel loader receives our chosen skin model in place of
-- the one matching the user's actual inventory. The game then runs all its
-- own animation binding, rig setup, and weapon mechanics against our model
-- and never knows the difference. Gated on Toggles.SkinsEnabled at call
-- time so the hook is a no-op when off.
local _skinHookInstalled = false
local function _installSkinHook()
    if _skinHookInstalled then return end
    if not SkinsLib then return end
    if type(hookfunction) ~= "function" then
        print("[skins] hookfunction unavailable, model redirect disabled")
        return
    end
    local function makeRedirect(name)
        local orig = SkinsLib[name]
        if type(orig) ~= "function" then return end
        local hooked
        hooked = hookfunction(orig, function(weapon, skin, ...)
            if not (Toggles.SkinsEnabled and Toggles.SkinsEnabled.Value) then
                return hooked(weapon, skin, ...)
            end
            local cat = _weaponCategory[weapon]
            local choice = cat and _skinChoice[cat]
            if choice and (choice.weapon ~= weapon or choice.skin ~= skin) then
                local ok, result = pcall(hooked, choice.weapon, choice.skin, ...)
                if ok and result then return result end
            end
            return hooked(weapon, skin, ...)
        end)
        print("[skins] hooked SkinsLib."..name)
    end
    makeRedirect("GetCameraModel")
    makeRedirect("GetCharacterModel")
    makeRedirect("GetWorldModel")
    _skinHookInstalled = true
end
-- DISABLED: this hook (combined with weapon-data patches) caused account
-- bans. Do NOT re-enable without a fundamentally different approach.
-- _installSkinHook()

-- NEW APPROACH: hook InventoryController.getInventoryItemFromLoadout. The
-- equipped item table carries `Name` (weapon) and `Skin` (variant) fields;
-- changing them BEFORE the game's equip() reads them causes the game to
-- spawn the disguised weapon's viewmodel + animations using its own native
-- code path. No model reparent, no MeshId writes, no weapon-data mutation.
local _loadoutHookInstalled = false
local function _installLoadoutHook()
    if _loadoutHookInstalled then return end
    if type(hookfunction) ~= "function" then
        print("[skins] hookfunction unavailable")
        return
    end
    local ok, ic = pcall(require, game:GetService("ReplicatedStorage").Controllers.InventoryController)
    if not ok or type(ic) ~= "table" then
        print("[skins] InventoryController unavailable:", tostring(ic))
        return
    end
    local target = ic.getInventoryItemFromLoadout
    if type(target) ~= "function" then
        print("[skins] getInventoryItemFromLoadout missing")
        return
    end
    local hooked
    hooked = hookfunction(target, function(...)
        local item = hooked(...)
        local args = {...}
        print("[skins] loadout-hook called args=", args[1], args[2], "->",
              type(item) == "table" and (item.Name.."/"..tostring(item.Skin)) or tostring(item))
        if type(item) ~= "table" then return item end
        if not (Toggles.SkinsEnabled and Toggles.SkinsEnabled.Value) then return item end
        local cat = _weaponCategory[item.Name]
        local choice = cat and _skinChoice[cat]
        if not choice then return item end
        if choice.weapon == item.Name and choice.skin == item.Skin then return item end
        local fake = {}
        for k, v in pairs(item) do fake[k] = v end
        fake.Name = choice.weapon
        fake.Skin = choice.skin
        fake._id  = choice.weapon .. "_" .. choice.skin
        print("[skins] loadout-hook REWROTE to", fake.Name.."/"..fake.Skin)
        return fake
    end)
    _loadoutHookInstalled = true
    print("[skins] hooked InventoryController.getInventoryItemFromLoadout")
end
_installLoadoutHook()

-- Weapon-data redirect: the game loads animations by looking up fields on
-- the weapon's data module (e.g. CT_Knife_Data.CameraAnimations), separate
-- from the viewmodel model. Our GetCameraModel hook gives the karambit
-- model but animations would still be CT-knife's. We patch the source
-- module's animation fields to point at the target's so the game loads
-- the correct animations onto the karambit rig.
local _origWeaponFields = {}   -- [moduleTable] = { CameraAnimations=..., CharacterAnimations=... }
local _patchedModules   = {}   -- set of patched module tables
local _wfRoot = nil do
    local rs = game:GetService("ReplicatedStorage")
    local db = rs:FindFirstChild("Database")
    db = db and db:FindFirstChild("Custom")
    _wfRoot = db and db:FindFirstChild("Weapons")
end

local ANIM_FIELDS = { "CameraAnimations", "CharacterAnimations", "Animations" }

local function _getWeaponData(name)
    if not _wfRoot then return nil end
    local mod = _wfRoot:FindFirstChild(name)
    if not mod then return nil end
    local ok, data = pcall(require, mod)
    if ok and type(data) == "table" then return data end
    return nil
end

local function _revertWeaponPatches()
    for tbl, orig in pairs(_origWeaponFields) do
        for k, v in pairs(orig) do
            pcall(function() tbl[k] = v end)
        end
    end
    _origWeaponFields = {}
    _patchedModules   = {}
end

local function _applyWeaponPatches()
    -- DISABLED: writes to weapon data tables raise "readonly" errors and
    -- caused account bans. Function kept so call sites still resolve, but
    -- it intentionally does nothing now.
    if true then return end
    _revertWeaponPatches()
    if not (Toggles.SkinsEnabled and Toggles.SkinsEnabled.Value) then return end
    for cat, choice in pairs(_skinChoice) do
        local group
        for _, g in ipairs(SKIN_GROUPS) do if g.name == cat then group = g; break end end
        if group then
            local tgtData = _getWeaponData(choice.weapon)
            if tgtData then
                for _, srcName in ipairs(group.items) do
                    if srcName ~= choice.weapon then
                        local srcData = _getWeaponData(srcName)
                        if srcData and not _patchedModules[srcData] then
                            local stash = {}
                            for _, field in ipairs(ANIM_FIELDS) do
                                if tgtData[field] ~= nil then
                                    stash[field] = srcData[field]
                                    pcall(function() srcData[field] = tgtData[field] end)
                                    local nowVal = srcData[field]
                                    print(("[skins] patch %s.%s: %s -> %s | verify=%s"):format(
                                        srcName, field,
                                        tostring(stash[field]), tostring(tgtData[field]),
                                        tostring(nowVal == tgtData[field])))
                                end
                            end
                            _origWeaponFields[srcData] = stash
                            _patchedModules[srcData]   = true
                        end
                    end
                end
            end
        end
    end
    print("[skins] applied weapon-data patches for", next(_skinChoice) and "selections" or "<empty>")
end

-- UI -----------------------------------------------------------------------
local SkinMaster = Tabs.Skins:AddLeftGroupbox("Skin Changer")

SkinMaster:AddToggle("SkinsEnabled", {
    Text    = "Enable skin changer",
    Default = false,
    Tooltip = "Redirects the game's viewmodel loader to your chosen skin.\nTake effect on next weapon equip (switch slot and back).",
})
Toggles.SkinsEnabled:OnChanged(function()
    if Toggles.SkinsEnabled.Value then
        _applyWeaponPatches()
    else
        _revertWeaponPatches()
    end
end)
SkinMaster:AddButton({
    Text = "Clear all",
    Func = function()
        for k in pairs(_skinChoice) do _skinChoice[k] = nil end
        for _, g in ipairs(SKIN_GROUPS) do
            local flag = "SkinCat_" .. g.name
            if Options[flag] then pcall(function() Options[flag]:SetValue("Default") end) end
        end
        print("[skins] cleared all selections")
    end,
})

-- One dropdown per category. Each dropdown lists every available skin from
-- every weapon in the category, formatted as "<Weapon> | <SkinName>".
local _skinSideToggle = true
for _, group in ipairs(SKIN_GROUPS) do
    local box = _skinSideToggle
        and Tabs.Skins:AddLeftGroupbox(group.name)
         or Tabs.Skins:AddRightGroupbox(group.name)
    _skinSideToggle = not _skinSideToggle
    local flag = "SkinCat_" .. group.name
    local values = _categoryLabels[group.name] or { "Default" }
    box:AddDropdown(flag, {
        Text    = group.name,
        Values  = values,
        Default = "Default",
    })
    Options[flag]:OnChanged(function()
        local label = Options[flag].Value
        if label == "Default" then
            _skinChoice[group.name] = nil
        else
            _skinChoice[group.name] = _labelToTuple[label]
        end
        if Toggles.SkinsEnabled and Toggles.SkinsEnabled.Value then
            _applyWeaponPatches()
        end
    end)
end

Library:OnUnload(function()
    -- Mark dead FIRST so any in-flight hook callbacks become no-ops.
    scriptAlive = false

    -- Restore any weapon-data field patches we made for the skin changer.
    pcall(_revertWeaponPatches)

    -- Disconnect every tracked RBXScriptConnection (RenderStepped, etc.).
    disconnectAll()

    -- Remove our raknet send hook so it doesn't keep firing after unload.
    if type(raknet) == "table" then
        pcall(function() if raknet.remove_send_hook then raknet.remove_send_hook() end end)
        pcall(function() if raknet.clear_send_hooks then raknet.clear_send_hooks() end end)
    end
    -- Restore Send's upvalue to the real RemoteEvent BEFORE anything else.
    pcall(uninstallUpvalueHook)

    -- Tear down ESP entries and Drawing objects.
    for plr, _ in pairs(cache) do destroyEntry(plr) end
    pcall(function() fovCircle:Remove() end)
    pcall(function() silentFovCircle:Remove() end)
    pcall(function() aimSnapLine:Remove() end)
    pcall(function() silentSnapLine:Remove() end)
    pcall(function() bulletTracerFolder:Destroy() end)
    pcall(function() chamsFolderHid:Destroy() end)
    pcall(function() chamsFolderVis:Destroy() end)
    pcall(function() vmChamsFolder:Destroy() end)
    -- Revert World tab side effects
    pcall(function() Camera.FieldOfView = _origFov end)
    pcall(function()
        Lighting.Ambient        = _origLight.Ambient
        Lighting.OutdoorAmbient = _origLight.OutdoorAmbient
        Lighting.Brightness     = _origLight.Brightness
        Lighting.ClockTime      = _origLight.ClockTime
        Lighting.FogColor       = _origLight.FogColor
        Lighting.FogStart       = _origLight.FogStart
        Lighting.FogEnd         = _origLight.FogEnd
    end)
    if _ccEffect then pcall(function() _ccEffect:Destroy() end) end
    if _hideVmConn then pcall(function() _hideVmConn:Disconnect() end) end
    -- Disengage hook for any tracked parts so the restore writes below stick.
    for part in pairs(_hookedHands) do _hookedHands[part] = nil end
    if _killSmokesConn then pcall(function() _killSmokesConn:Disconnect() end) end
    if _killWsConn     then pcall(function() _killWsConn:Disconnect()     end) end
    if _smokeDebugConn then pcall(function() _smokeDebugConn:Disconnect() end) end
    for sa, origParent in pairs(_vmStashedSurfaces) do
        if sa and origParent and origParent.Parent then
            pcall(function() sa.Parent = origParent end)
        end
    end
    _vmStashedSurfaces = {}
    for part, orig in pairs(_vmHidden) do
        if part and part.Parent and type(orig) == "table" then
            pcall(function()
                part.LocalTransparencyModifier = orig.ltm or 0
                part.Transparency              = orig.t   or 0
                if orig.size then part.Size    = orig.size end
            end)
        end
    end
end)
