--[[
	WARNING: Heads up! This script has not been verified by ScriptBlox. Use at your own risk!
]]
if getgenv().TAS_PlayGUI_Running then
    pcall(function() getgenv().TAS_PlayGUI_Disconnect() end)
    task.wait(0.2)
end
getgenv().TAS_PlayGUI_Running = true

local RunService  = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Players     = game:GetService("Players")
local Workspace   = game:GetService("Workspace")
local StarterGui  = game:GetService("StarterGui")
local LocalPlayer = Players.LocalPlayer

local REPO_BASE   = "https://raw.githubusercontent.com/ZXPQ812/tas/refs/heads/main/"
local MANIFEST_URL = REPO_BASE .. "manifest.txt"
local FOLDER      = "TAS_Recorder"

local DISPLAY_NAMES = {
    ["bootleft"]   = "Bootcamp (Left)",
    ["bootright"]   = "Bootcamp (Middle)",
    ["cave"]    = "Cave Chaos",
    ["colosseum"]   = "Colosseum Climb",
    ["construct"]    = "Construct Course",
    ["hill"]    = "Hill Hike",
    ["Lavadash"]    = "Lava Dash",
    ["obstacle"]   = "Obstacle Course",
    ["pond"]    = "Pond Pier",
    ["rickety"] = "Rickety Rails",
    ["rockleft"]   = "Rockwall (Left)",
    ["rockright"]   = "Rockwall (Right)",
    ["spinner"]    = "Spinner",
    ["tightrope"]   = "Tightrope",
    ["unstab"]     = "Unstable Savannah",
    ["reallyfake"]     = "Fakest Obstacle Course route",
}

local function notify(text, title, dur)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title or "TAS Player", Text = text or "", Duration = dur or 3
        })
    end)
end

-- Reads manifest.txt from the repo, returns list of {id, label} in order
local function FetchManifest()
    local ok, content = pcall(function()
        return game:HttpGet(MANIFEST_URL, true)
    end)
    if not ok or not content or #content < 3 then return nil end
    local runs = {}
    for line in content:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            local id = line:gsub("%.json$", "")
            local label = DISPLAY_NAMES[id] or id
            table.insert(runs, { id = id, label = label })
        end
    end
    return #runs > 0 and runs or nil
end

-- Downloads any runs listed in the manifest that aren't already on disk
local function EnsureRuns(runs)
    if not isfolder(FOLDER) then makefolder(FOLDER) end
    local downloaded = 0
    local skipped    = 0
    for _, run in ipairs(runs) do
        local path = FOLDER .. "/" .. run.id .. ".json"
        if isfile(path) then
            skipped = skipped + 1
        else
            local ok, content = pcall(function()
                return game:HttpGet(REPO_BASE .. run.id .. ".json", true)
            end)
            if ok and content and #content > 10 then
                pcall(function() writefile(path, content) end)
                downloaded = downloaded + 1
            end
        end
    end
    if downloaded > 0 then
        notify("Downloaded " .. downloaded .. " new run(s). " .. skipped .. " already existed.", "LifeHub", 5)
    end
end

-- Playback engine
local ValToStateName = {}
for _, s in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
    ValToStateName[s.Value] = s.Name
end

local KeepEnabled = {
    [Enum.HumanoidStateType.Dead]      = true,
    [Enum.HumanoidStateType.GettingUp] = true,
    [Enum.HumanoidStateType.Landed]    = true,
    [Enum.HumanoidStateType.None]      = true,
}

local function CFrameToQuat(cf)
    local ax, ang = cf:ToAxisAngle()
    local sh = math.sin(ang / 2)
    return ax.X*sh, ax.Y*sh, ax.Z*sh, math.cos(ang / 2)
end

local function QuatToCFrame(x, y, z, qx, qy, qz, qw)
    return CFrame.new(x, y, z, qx, qy, qz, qw)
end

local function NormaliseFrame(f)
    if type(f.CF) == "table" then
        if #f.CF == 12 then
            local cf = CFrame.new(table.unpack(f.CF))
            local qx,qy,qz,qw = CFrameToQuat(cf)
            f.CF = {cf.X, cf.Y, cf.Z, qx, qy, qz, qw}
        elseif #f.CF == 6 then
            local cf = CFrame.new(f.CF[1],f.CF[2],f.CF[3]) * CFrame.fromEulerAnglesYXZ(f.CF[4],f.CF[5],f.CF[6])
            local qx,qy,qz,qw = CFrameToQuat(cf)
            f.CF = {cf.X, cf.Y, cf.Z, qx, qy, qz, qw}
        end
    end
    if type(f.CCF) == "table" then
        if #f.CCF == 12 then
            local ccf = CFrame.new(table.unpack(f.CCF))
            local qx,qy,qz,qw = CFrameToQuat(ccf)
            f.CCF = {ccf.X, ccf.Y, ccf.Z, qx, qy, qz, qw}
        elseif #f.CCF == 6 then
            local ccf = CFrame.new(f.CCF[1],f.CCF[2],f.CCF[3]) * CFrame.fromEulerAnglesYXZ(f.CCF[4],f.CCF[5],f.CCF[6])
            local qx,qy,qz,qw = CFrameToQuat(ccf)
            f.CCF = {ccf.X, ccf.Y, ccf.Z, qx, qy, qz, qw}
        end
    end
    -- AN (animation data) is already a plain table, no conversion needed
end

local PlayConn       = nil
local IsPlaying      = false
local CurrentRunName = ""

local function StopPlayback()
    if PlayConn then PlayConn:Disconnect(); PlayConn = nil end
    IsPlaying = false
    getgenv().TAS_IsPlaying = false
    CurrentRunName = ""
    local char = LocalPlayer.Character
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    if root then
        root.Anchored    = false
        root.Velocity    = Vector3.zero
        root.RotVelocity = Vector3.zero
    end
    local hum = char:FindFirstChild("Humanoid")
    if hum then
        for _, st in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
            pcall(function() hum:SetStateEnabled(st, true) end)
        end
        pcall(function()
            if hum:GetState() ~= Enum.HumanoidStateType.GettingUp then
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            end
        end)
    end
end

local function PlayRun(label, rawJson)
    if IsPlaying then StopPlayback(); task.wait(0.05) end
    local ok, data = pcall(HttpService.JSONDecode, HttpService, rawJson)
    if not ok or type(data) ~= "table" or type(data[1]) ~= "table" or type(data[2]) ~= "table" then
        notify("Bad data for: " .. label, "TAS Error"); return
    end
    local frames = {}
    for _, seg in ipairs(data[1]) do
        for _, f in ipairs(seg) do NormaliseFrame(f); table.insert(frames, f) end
    end
    for _, f in ipairs(data[2]) do
        NormaliseFrame(f); table.insert(frames, f)
    end
    if #frames == 0 then notify("No frames in: " .. label, "TAS Error"); return end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum  = char and char:FindFirstChild("Humanoid")
    if not root then notify("Respawn first!", "TAS Error"); return end
    IsPlaying = true
    CurrentRunName = label
    getgenv().TAS_IsPlaying = true
    root.Anchored = false
    if hum then
        for _, st in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
            if not KeepEnabled[st] then
                pcall(function() hum:SetStateEnabled(st, false) end)
            end
        end
    end
    notify("▶  " .. label, "TAS Player", 2)
    local t0  = os.clock()
    local idx = 1
    PlayConn = RunService.Heartbeat:Connect(function()
        if not char or not char.Parent or not root or not root.Parent then
            StopPlayback(); return
        end
        if hum and hum.Health <= 0 then StopPlayback(); return end
        local elapsed = os.clock() - t0
        while idx < #frames and frames[idx+1] and frames[idx+1].T <= elapsed do
            idx = idx + 1
        end
        local fA = frames[idx]
        local fB = frames[idx + 1]
        if fB and type(fA)=="table" and type(fB)=="table"
            and fA.CF and fB.CF and fA.V and fB.V and fA.RV and fB.RV then
            local dt    = fB.T - fA.T
            local alpha = (dt > 0) and math.clamp((elapsed - fA.T) / dt, 0, 1) or 0
            root.CFrame = QuatToCFrame(table.unpack(fA.CF)):Lerp(QuatToCFrame(table.unpack(fB.CF)), alpha)
            if type(fA.CCF)=="table" and type(fB.CCF)=="table" then
                Workspace.CurrentCamera.CFrame =
                    QuatToCFrame(table.unpack(fA.CCF)):Lerp(QuatToCFrame(table.unpack(fB.CCF)), alpha)
            end
            local vA  = Vector3.new(table.unpack(fA.V));  local vB  = Vector3.new(table.unpack(fB.V))
            local rvA = Vector3.new(table.unpack(fA.RV)); local rvB = Vector3.new(table.unpack(fB.RV))
            local cv  = vA:Lerp(vB, alpha)
            local crv = rvA:Lerp(rvB, alpha)
            for _, p in ipairs(char:GetDescendants()) do
                if p:IsA("BasePart") then p.Velocity = cv; p.RotVelocity = crv end
            end
            if hum and fA.HS then
                local sname = type(fA.HS)=="number" and ValToStateName[fA.HS] or fA.HS
                if sname and sname ~= "None" then
                    local cur = hum:GetState().Name
                    if cur ~= sname then
                        local enum = Enum.HumanoidStateType[sname]
                        if enum then pcall(function() hum:ChangeState(enum) end) end
                    end
                end
            end

            -- Replay animations recorded in this frame
            if type(fA.AN) == "table" then
                local animator = hum and hum:FindFirstChildOfClass("Animator")
                if animator then
                    local desiredAnims = {}
                    for _, animData in ipairs(fA.AN) do
                        if animData.Id and animData.Id ~= "" then
                            desiredAnims[animData.Id] = animData
                        end
                    end
                    -- Stop tracks that shouldn't be playing
                    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                        local id = track.Animation and track.Animation.AnimationId
                        if id and not desiredAnims[id] then
                            track:Stop(0)
                        end
                    end
                    -- Start or update tracks that should be playing
                    for animId, animData in pairs(desiredAnims) do
                        local found = false
                        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                            if track.Animation and track.Animation.AnimationId == animId then
                                found = true
                                track:AdjustSpeed(animData.Speed or 1)
                                track:AdjustWeight(animData.Weight or 1, 0)
                                pcall(function() track.TimePosition = animData.Pos or 0 end)
                                break
                            end
                        end
                        if not found then
                            local anim = Instance.new("Animation")
                            anim.AnimationId = animId
                            local ok, track = pcall(function()
                                return animator:LoadAnimation(anim)
                            end)
                            if ok and track then
                                track:Play(0, animData.Weight or 1, animData.Speed or 1)
                                pcall(function() track.TimePosition = animData.Pos or 0 end)
                            end
                            anim:Destroy()
                        end
                    end
                end
            end
        else
            StopPlayback()
            notify("✔  Finished: " .. label, "TAS Player", 3)
        end
    end)
end

local function LoadRunFromFile(id, label)
    local path = FOLDER .. "/" .. id .. ".json"
    if not isfile(path) then
        notify("File not found: " .. id .. ".json", "TAS Error"); return
    end
    local ok, content = pcall(readfile, path)
    if not ok or not content then
        notify("Could not read: " .. label, "TAS Error"); return
    end
    PlayRun(label, content)
end

-- Fetch manifest and download missing runs before building the GUI
local GITHUB_API   = "https://api.github.com/repos/ZXPQ812/tas/commits?path="
local TIMESTAMPS_FILE = FOLDER .. "/timestamps.json"

local function GetLocalTimestamps()
    if not isfolder(FOLDER) then return {} end
    if not isfile(TIMESTAMPS_FILE) then return {} end
    local ok, content = pcall(readfile, TIMESTAMPS_FILE)
    if not ok or not content or #content < 2 then return {} end
    local ok2, data = pcall(function() return HttpService:JSONDecode(content) end)
    return (ok2 and type(data) == "table") and data or {}
end

local function SaveLocalTimestamps(timestamps)
    pcall(function()
        writefile(TIMESTAMPS_FILE, HttpService:JSONEncode(timestamps))
    end)
end

local function GetRemoteCommitDate(filename)
    local ok, content = pcall(function()
        return game:HttpGet(GITHUB_API .. filename .. "&per_page=1", true)
    end)
    if not ok or not content or #content < 5 then return nil end
    local ok2, data = pcall(function() return HttpService:JSONDecode(content) end)
    if not ok2 or type(data) ~= "table" or not data[1] then return nil end
    local commit = data[1].commit
    if not commit then return nil end
    local date = commit.committer and commit.committer.date
    return date
end

local function EnsureRunsWithDateCheck(runs)
    if not isfolder(FOLDER) then makefolder(FOLDER) end

    local timestamps = GetLocalTimestamps()
    local downloaded = 0
    local updated    = 0
    local skipped    = 0

    for _, run in ipairs(runs) do
        local filename = run.id .. ".json"
        local path     = FOLDER .. "/" .. filename
        local exists   = isfile(path)

        local remoteDate = GetRemoteCommitDate(filename)
        local localDate  = timestamps[filename]

        local needsUpdate = false
        if not exists then
            needsUpdate = true
        elseif remoteDate and localDate and remoteDate ~= localDate then
            needsUpdate = true
        elseif remoteDate and not localDate then
            needsUpdate = true
        end

        if needsUpdate then
            local ok, content = pcall(function()
                return game:HttpGet(REPO_BASE .. filename, true)
            end)
            if ok and content and #content > 10 then
                pcall(function() writefile(path, content) end)
                if remoteDate then
                    timestamps[filename] = remoteDate
                end
                if exists then
                    updated = updated + 1
                else
                    downloaded = downloaded + 1
                end
            end
        else
            skipped = skipped + 1
        end
    end

    SaveLocalTimestamps(timestamps)

    if updated > 0 and downloaded > 0 then
        notify("Updated " .. updated .. " and downloaded " .. downloaded .. " new run(s).", "LifeHub", 5)
    elseif updated > 0 then
        notify("Updated " .. updated .. " run(s) to latest versions.", "LifeHub", 5)
    elseif downloaded > 0 then
        notify("Downloaded " .. downloaded .. " new run(s).", "LifeHub", 5)
    end
end

local runs = FetchManifest()
if not runs then
    if not isfolder(FOLDER) then makefolder(FOLDER) end
    local allFiles = listfiles(FOLDER)
    runs = {}
    for _, path in ipairs(allFiles) do
        local filename = path:match("([^/\\]+)$") or path
        if filename:match("%.json$") and filename ~= "timestamps.json" then
            local id = filename:gsub("%.json$", "")
            local label = DISPLAY_NAMES[id] or id
            table.insert(runs, { id = id, label = label })
        end
    end
    table.sort(runs, function(a, b) return a.id < b.id end)
    notify("Could not fetch manifest — showing local runs only.", "LifeHub", 4)
else
    EnsureRunsWithDateCheck(runs)
end

-- GUI
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name            = "TAS Player",
    LoadingTitle    = "TAS Player",
    LoadingSubtitle = "Loading runs...",
    ConfigurationSaving = { Enabled = false },
    Discord         = { Enabled = false },
    KeySystem       = false,
})

local RunTab = Window:CreateTab("Runs", 4483362458)
RunTab:CreateSection("Saved Runs (" .. #runs .. ") — click to play")

for _, run in ipairs(runs) do
    RunTab:CreateButton({
        Name        = run.label,
        Description = run.id .. ".json",
        Callback    = function()
            LoadRunFromFile(run.id, run.label)
        end,
    })
end

local CtrlTab = Window:CreateTab("Controls", 4483362458)
CtrlTab:CreateSection("Playback")

CtrlTab:CreateButton({
    Name        = "Stop Playback",
    Description = "Stops any active TAS playback",
    Callback    = function()
        StopPlayback()
        notify("Playback stopped.", "TAS Player", 2)
    end,
})

CtrlTab:CreateSection("Script")

CtrlTab:CreateButton({
    Name        = "Unload GUI",
    Description = "Removes this GUI and cleans up",
    Callback    = function()
        getgenv().TAS_PlayGUI_Disconnect()
    end,
})

getgenv().TAS_PlayGUI_Disconnect = function()
    StopPlayback()
    pcall(function() Rayfield:Destroy() end)
    getgenv().TAS_PlayGUI_Running = false
    notify("TAS Play GUI unloaded.", "TAS Player")
end

notify("TAS Player ready! " .. #runs .. " run(s) loaded.", "TAS Player", 4)
