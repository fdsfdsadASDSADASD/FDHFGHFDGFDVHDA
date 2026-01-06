if not game:IsLoaded() then
    game.Loaded:Wait()
end

local plr = game:GetService("Players").LocalPlayer
local char = plr.Character or plr.CharacterAdded:Wait()
char:WaitForChild("Humanoid")
char:WaitForChild("HumanoidRootPart")
task.wait(3)

getgenv().AutoParryEnabled = getgenv().AutoParryEnabled or false
getgenv().DEBUG_ENABLED = getgenv().DEBUG_ENABLED or false
getgenv().DETECTION_DISTANCE = tonumber(getgenv().DETECTION_DISTANCE) or 20
getgenv().BLOCK_M1_ENABLED = getgenv().BLOCK_M1_ENABLED or false
getgenv().TARGET_FACING_CHECK_ENABLED = getgenv().TARGET_FACING_CHECK_ENABLED or false
getgenv().TARGET_FACING_ANGLE = tonumber(getgenv().TARGET_FACING_ANGLE) or 75
getgenv().SHEATH_CHECK_ENABLED = getgenv().SHEATH_CHECK_ENABLED or false
getgenv().LEADERBOARD_SPECTATE_ENABLED = getgenv().LEADERBOARD_SPECTATE_ENABLED or false
local PING_COMP_BASE = 0
getgenv().PING_COMPENSATION = tonumber(getgenv().PING_COMPENSATION) or PING_COMP_BASE
getgenv().WHITELISTED_PLAYERS = getgenv().WHITELISTED_PLAYERS or {}
getgenv().FAILURE_RATE = tonumber(getgenv().FAILURE_RATE) or 0
getgenv().ROLL_ON_COOLDOWN_ENABLED = getgenv().ROLL_ON_COOLDOWN_ENABLED or false
getgenv().ANIMATION_CHECK_ENABLED = getgenv().ANIMATION_CHECK_ENABLED or false
getgenv().LAST_PARRY_TIME = tonumber(getgenv().LAST_PARRY_TIME) or 0
getgenv().PARRY_COOLDOWN = tonumber(getgenv().PARRY_COOLDOWN) or 0.5
getgenv().ACTUAL_PARRY_COOLDOWN = tonumber(getgenv().ACTUAL_PARRY_COOLDOWN) or 0.5
getgenv().PARRY_WITH_DASH_ONLY_DEBUG = getgenv().PARRY_WITH_DASH_ONLY_DEBUG or false

local lp = game.Players.LocalPlayer
local character = lp.Character or lp.CharacterAdded:Wait()
local connections = {}
local allAnims = {}
local activeBlockWindows = {}
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BlockRemote = ReplicatedStorage:WaitForChild("Bridgenet2Main"):WaitForChild("dataRemoteEvent")

local CP = game:GetService("ContentProvider")

local old_namecall
old_namecall = hookmetamethod(game, "__namecall", function(self, ...)
    local method = getnamecallmethod()
    if self == CP and (method == "GetAssetFetchStatus" or method == "GetAssetFetchStatusChangedSignal") then
        return task.wait(9e9)
    end
    return old_namecall(self, ...)
end)

local function sendAction(moduleName, extra)
    local payload = {Module = moduleName}
    if extra then
        for k, v in pairs(extra) do
            payload[k] = v
        end
    end
    local args = {
        [1] = {
            [1] = {
                [1] = "\3",
                [2] = payload
            }
        }
    }
    pcall(function()
        BlockRemote:FireServer(unpack(args))
    end)
end

local function normalizeAnimId(idStr)
    if not idStr then return "" end
    local digits = tostring(idStr):match("%d+")
    return digits or tostring(idStr)
end

local function debugPrint(...)
    if getgenv().DEBUG_ENABLED then
        print(...)
    end
end

local function isTargetFacingMe(attackerHRP, myHRP)
    if not attackerHRP or not myHRP then return false end
    if not attackerHRP.Position or not myHRP.Position then return false end
    local toMe = myHRP.Position - attackerHRP.Position
    local mag = toMe.Magnitude
    if mag < 1e-4 then return false end
    local forward = attackerHRP.CFrame.LookVector
    local dot = forward:Dot(toMe / mag)
    local cosThresh = math.cos(math.rad(getgenv().TARGET_FACING_ANGLE or 75))
    return dot >= cosThresh
end

local function isWeaponOut()
    local entities = workspace:FindFirstChild("Entities")
    if not entities then return false end
    local playerEntity = entities:FindFirstChild(lp.Name)
    if not playerEntity then return false end
    local toggleValue = playerEntity:FindFirstChild("Toggle")
    if toggleValue and toggleValue:IsA("BoolValue") then
        return toggleValue.Value == true
    end
    return false
end

local function notify(title, text, duration)
    duration = duration or 2
    local ok = pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = duration
        })
    end)
    if not ok then
        debugPrint("Notify:", title, text)
    end
end

local spectateState = {
    connections = {},
    childConn = nil,
    guiConn = nil,
    prevSubject = nil,
    prevType = nil,
    targetName = nil,
    highlight = nil,
    activeButton = nil,
    labelColors = {},
}

local function getLeaderboardContainer()
    local playerGui = lp:FindFirstChild("PlayerGui")
    local lbGui = playerGui and playerGui:FindFirstChild("Leaderboard")
    local lbFrame = lbGui and lbGui:FindFirstChild("Leaderboard")
    return lbFrame
end

local function restoreCamera()
    local cam = workspace.CurrentCamera
    if spectateState.prevSubject then
        cam.CameraSubject = spectateState.prevSubject
    end
    if spectateState.prevType then
        cam.CameraType = spectateState.prevType
    end
    if spectateState.highlight then
        spectateState.highlight:Destroy()
        spectateState.highlight = nil
    end
    if spectateState.activeButton and spectateState.labelColors[spectateState.activeButton] then
        for lbl, color in pairs(spectateState.labelColors[spectateState.activeButton]) do
            if lbl and lbl.Parent then
                lbl.TextColor3 = color
            end
        end
    end
    spectateState.activeButton = nil
    spectateState.prevSubject = nil
    spectateState.prevType = nil
    spectateState.targetName = nil
end

local function setButtonHighlight(btn, isActive)
    if not btn then return end
    if not spectateState.labelColors[btn] then
        spectateState.labelColors[btn] = {}
    end
    for _, d in ipairs(btn:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            if isActive then
                if not spectateState.labelColors[btn][d] then
                    spectateState.labelColors[btn][d] = d.TextColor3
                end
                d.TextColor3 = Color3.fromRGB(255, 0, 0)
            else
                if spectateState.labelColors[btn][d] then
                    d.TextColor3 = spectateState.labelColors[btn][d]
                end
            end
        end
    end
    if not isActive then
        spectateState.labelColors[btn] = nil
    end
end

local function setSpectateTarget(btn)
    if not (btn and btn.Name) then return end
    local name = btn.Name

    if spectateState.targetName == name and spectateState.activeButton == btn then
        debugPrint("[SPECTATE] Stopping spectate on", name)
        restoreCamera()
        return
    end

    local targetPlr = game:GetService("Players"):FindFirstChild(name)
    if not targetPlr then return end
    local targetChar = targetPlr.Character or targetPlr.CharacterAdded:Wait()
    local humanoid = targetChar:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end

    if spectateState.highlight then
        spectateState.highlight:Destroy()
        spectateState.highlight = nil
    end
    local hl = Instance.new("Highlight")
    hl.FillTransparency = 1
    hl.OutlineTransparency = 0
    hl.OutlineColor = Color3.fromRGB(255, 0, 0)
    hl.Adornee = targetChar
    hl.Parent = targetChar
    spectateState.highlight = hl

    local cam = workspace.CurrentCamera
    if not spectateState.prevSubject then
        spectateState.prevSubject = cam.CameraSubject
        spectateState.prevType = cam.CameraType
    end
    cam.CameraType = Enum.CameraType.Custom
    cam.CameraSubject = humanoid

    if spectateState.activeButton and spectateState.activeButton ~= btn then
        setButtonHighlight(spectateState.activeButton, false)
    end
    setButtonHighlight(btn, true)
    spectateState.activeButton = btn
    spectateState.targetName = name
    debugPrint("[SPECTATE] Now spectating:", name)
end

local function connectButton(btn)
    if not (btn and btn:IsA("ImageButton")) then return end
    if spectateState.connections[btn] then return end
    spectateState.connections[btn] = btn.MouseButton1Click:Connect(function()
        if getgenv().LEADERBOARD_SPECTATE_ENABLED then
            setSpectateTarget(btn)
        end
    end)
end

local function bindLeaderboardButtons(container)
    if not container then return end
    for _, child in ipairs(container:GetChildren()) do
        connectButton(child)
    end
    if spectateState.childConn then
        spectateState.childConn:Disconnect()
    end
    spectateState.childConn = container.ChildAdded:Connect(connectButton)
end

function enableLeaderboardSpectate()
    local container = getLeaderboardContainer()
    if container then
        spectateState.container = container
        bindLeaderboardButtons(container)
    else
        debugPrint("[SPECTATE] Leaderboard UI not found; waiting for it to appear")
        local playerGui = lp:FindFirstChild("PlayerGui")
        if playerGui then
            if spectateState.guiConn then
                spectateState.guiConn:Disconnect()
            end
            spectateState.guiConn = playerGui.ChildAdded:Connect(function(child)
                if child.Name == "Leaderboard" then
                    local lbFrame = child:FindFirstChild("Leaderboard")
                    if lbFrame then
                        bindLeaderboardButtons(lbFrame)
                    end
                end
            end)
        end
    end
end

function disableLeaderboardSpectate()
    for _, conn in pairs(spectateState.connections) do
        if conn then conn:Disconnect() end
    end
    spectateState.connections = {}
    if spectateState.childConn then
        spectateState.childConn:Disconnect()
    end
    spectateState.childConn = nil
    if spectateState.guiConn then
        spectateState.guiConn:Disconnect()
    end
    spectateState.guiConn = nil
    if spectateState.activeButton then
        setButtonHighlight(spectateState.activeButton, false)
    end
    spectateState.activeButton = nil
    restoreCamera()
end

local DATA_URL = "https://raw.githubusercontent.com/fdsfdsadASDSADASD/FDHFGHFDGFDVHDA/refs/heads/main/ghdfghdgfdgdsf.txt"

local function base64Decode(data)
    local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    data = string.gsub(data, '[^'..b..'=]', '')
    return (data:gsub('.', function(x)
        if (x == '=') then return '' end
        local r,f='',(b:find(x)-1)
        for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
        return r;
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if (#x ~= 8) then return '' end
        local c=0
        for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
        return string.char(c)
    end))
end

local function loadAnimationData()
    local http = game:GetService("HttpService")
    local okFetch, encoded = pcall(function()
        return game:HttpGet(DATA_URL)
    end)
    if okFetch and type(encoded) == "string" and #encoded > 0 then
        local okBase64, decoded = pcall(function()
            return base64Decode(encoded)
        end)
        if not okBase64 then
            debugPrint("Base64 decode failed")
            return {}
        end
        
        local okDecode, data = pcall(function()
            return http:JSONDecode(decoded)
        end)
        if okDecode and type(data) == "table" then
            debugPrint("Loaded animation data from GitHub")
            return data
        else
            debugPrint("JSON decode failed")
            return {}
        end
    end
    debugPrint("Failed to load from GitHub — using empty dataset")
    return {}
end

local combatAnims = {}
local animationData = loadAnimationData()

for animId, animInfo in pairs(animationData) do
    if type(animInfo) ~= "table" then continue end
    
    local hitWindows = {}
    local baseHold = tonumber(animInfo.hold)
    if not baseHold or type(baseHold) ~= "number" then baseHold = 0.15 end

    for key, value in pairs(animInfo) do
        local idxStr = tostring(key):match("^startSec(%d*)$")
        if idxStr ~= nil then
            local startSec = tonumber(value)
            if startSec and type(startSec) == "number" then
                local holdKey = "hold" .. (idxStr ~= "" and idxStr or "")
                local hold = tonumber(animInfo[holdKey]) or baseHold
                
                table.insert(hitWindows, {
                    startTime = startSec,
                    hold = hold
                })
            end
        end
    end

    table.sort(hitWindows, function(a, b)
        return a.startTime < b.startTime
    end)

    local normalizedId = normalizeAnimId(animId)
    local entry = {
        AnimationId = normalizedId,
        Hold = baseHold,
        HitWindows = hitWindows
    }

    table.insert(combatAnims, entry)
end

local function cleanupConnections()
    for i, connection in pairs(connections) do
        if typeof(connection) == "RBXScriptConnection" then
            connection:Disconnect()
        end
    end
    table.clear(connections)
    table.clear(allAnims)
end

local function setupPlayerAnimations(player)
    if not player or player.Name == lp.Name then return end
    
    local humanoid = player:FindFirstChild("Humanoid")
    if not humanoid then return end
    
    local connection = humanoid.AnimationPlayed:Connect(function(animationTrack)
        local info = {
            anim = animationTrack.Animation,
            plr = player,
            startTime = tick(),
            parried = false
        }
        allAnims[animationTrack] = info
        
        animationTrack.Ended:Once(function()
            allAnims[animationTrack] = nil
        end)
        
        animationTrack.Stopped:Once(function()
            allAnims[animationTrack] = nil
        end)
    end)
    
    table.insert(connections, connection)
end

for _, player in pairs(game.Workspace.Entities:GetChildren()) do
    setupPlayerAnimations(player)
end

local con = game.Workspace.Entities.ChildAdded:Connect(function (child)
    wait(1)
    setupPlayerAnimations(child)
end)
table.insert(connections,con)

local lastBlockAttempt = {}
local function setupDamageMonitor()
    local humanoid = character and character:FindFirstChild("Humanoid")
    if not humanoid then return end
    local prev = humanoid.Health
    local conn = humanoid.HealthChanged:Connect(function(newHealth)
        prev = newHealth
    end)
    table.insert(connections, conn)
end

setupDamageMonitor()

local function setupCooldownTracking()
    local replicatedStorage = game:GetService("ReplicatedStorage")
    pcall(function()
        local cooldownRemote = replicatedStorage:WaitForChild("Remotes"):WaitForChild("HUDCooldownUpdate")
        cooldownRemote.OnClientEvent:Connect(function(abilityName, cooldownDuration)
            if abilityName == "Block" or abilityName == "Parry" then
                getgenv().ACTUAL_PARRY_COOLDOWN = tonumber(cooldownDuration) or 0.5
                debugPrint("[COOLDOWN] Server reported parry cooldown:", getgenv().ACTUAL_PARRY_COOLDOWN, "seconds")
            end
        end)
    end)
end

setupCooldownTracking()

local isCurrentlyParrying = false
local lastParryTime = 0

task.spawn(function()
    while true do
        task.wait(0.016)
        
        if (not character) or (not character.Parent) then
            character = lp.Character or lp.CharacterAdded:Wait()
            setupDamageMonitor()
            continue
        end
        
        if not getgenv().AutoParryEnabled then
            isCurrentlyParrying = false
            continue
        end
        
        local myHRP = character:FindFirstChild("HumanoidRootPart")
        if not myHRP then continue end
        
        for animTrack, animInfo in pairs(allAnims) do
            if animInfo.parried then continue end
            
            local player = animInfo.plr
            if not player or not player.Parent then continue end
            
            if table.find(getgenv().WHITELISTED_PLAYERS or {}, player.Name) then
                continue
            end
            
            local attackerHRP = player:FindFirstChild("HumanoidRootPart")
            if not attackerHRP then continue end
            
            local distance = (myHRP.Position - attackerHRP.Position).Magnitude
            if distance > getgenv().DETECTION_DISTANCE then continue end
            
            if getgenv().TARGET_FACING_CHECK_ENABLED and not isTargetFacingMe(attackerHRP, myHRP) then
                continue
            end
            
            if getgenv().SHEATH_CHECK_ENABLED and not isWeaponOut() then
                continue
            end
            
            local anim = animInfo.anim
            if not anim then continue end
            
            local animId = normalizeAnimId(anim.AnimationId)
            local combatEntry = nil
            for _, entry in ipairs(combatAnims) do
                if entry.AnimationId == animId then
                    combatEntry = entry
                    break
                end
            end
            
            if not combatEntry then continue end
            
            local elapsed = tick() - animInfo.startTime
            local windows = combatEntry.HitWindows
            
            if #windows == 0 then
                local defaultHold = combatEntry.Hold or 0.15
                windows = {{startTime = 0, hold = defaultHold}}
            end
            
            for _, window in ipairs(windows) do
                local startSec = window.startTime
                local hold = window.hold
                local pingComp = (getgenv().PING_COMPENSATION or 0) / 1000
                local targetTime = startSec - hold + pingComp
                
                if elapsed >= targetTime and not animInfo.parried then
                    if getgenv().ANIMATION_CHECK_ENABLED then
                        task.wait(0.01)
                        if not animTrack or not animTrack.IsPlaying then
                            debugPrint("[ANIMATION CHECK] Animation stopped before parry - skipping")
                            continue
                        end
                    end
                    
                    if getgenv().FAILURE_RATE > 0 then
                        local roll = math.random(1, 100)
                        if roll <= getgenv().FAILURE_RATE then
                            debugPrint("[FAILURE] Intentionally skipping parry (" .. roll .. " <= " .. getgenv().FAILURE_RATE .. "%)")
                            animInfo.parried = true
                            break
                        end
                    end
                    
                    if isCurrentlyParrying then
                        debugPrint("[SPAM BLOCK] Already parrying, skipping")
                        break
                    end
                    
                    isCurrentlyParrying = true
                    local currentTime = tick()
                    
                    local onCooldown = (currentTime - lastParryTime) < getgenv().ACTUAL_PARRY_COOLDOWN
                    
                    if onCooldown and getgenv().ROLL_ON_COOLDOWN_ENABLED then
                        debugPrint("[ROLL] Parry on cooldown, rolling instead")
                        sendAction("Dash")
                    else
                        if getgenv().PARRY_WITH_DASH_ONLY_DEBUG then
                            sendAction("Dash")
                            debugPrint("[DEBUG] Dash-only mode: using Dash instead of Block")
                        else
                            sendAction("Block")
                        end
                    end
                    
                    lastParryTime = currentTime
                    getgenv().LAST_PARRY_TIME = currentTime
                    animInfo.parried = true
                    
                    if getgenv().BLOCK_M1_ENABLED then
                        activeBlockWindows[animTrack] = {
                            endTime = currentTime + 0.1,
                            animName = anim.Name or "Unknown"
                        }
                    end
                    
                    debugPrint(string.format("[PARRY] Player: %s | Anim: %s | Distance: %.1f | Window: %.3fs | Hold: %.3fs", 
                        player.Name, anim.Name or "Unknown", distance, startSec, hold))
                    
                    task.delay(0.05, function()
                        isCurrentlyParrying = false
                    end)
                    
                    break
                end
            end
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(5)
        for animTrack, _ in pairs(allAnims) do
            if not animTrack or not animTrack.IsPlaying then
                allAnims[animTrack] = nil
            end
        end
        local currentTick = tonumber(tick())
        local lastTick = tonumber(lastParryTime)
        if currentTick and lastTick and type(currentTick) == "number" and type(lastTick) == "number" then
            if isCurrentlyParrying and (currentTick - lastTick) > 1 then
                isCurrentlyParrying = false
                debugPrint("[RESET] Parry lock reset")
            end
        end
    end
end)

lp.CharacterAdded:Connect(function(newCharacter)
    character = newCharacter
    setupDamageMonitor()
    allAnims = {}
    isCurrentlyParrying = false
end)

print("[AUTOPARRY] Loaded successfully!")
