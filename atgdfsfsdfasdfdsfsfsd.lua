-- ============================================
-- AUTO PARRY MODULE (Non-Obfuscated)
-- ============================================

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local AutoParry = {}

-- Configuration
getgenv().AutoParryEnabled = getgenv().AutoParryEnabled or false
getgenv().DEBUG_ENABLED = getgenv().DEBUG_ENABLED or false
getgenv().DETECTION_DISTANCE = tonumber(getgenv().DETECTION_DISTANCE) or 20
getgenv().BLOCK_M1_ENABLED = getgenv().BLOCK_M1_ENABLED or false
getgenv().TARGET_FACING_CHECK_ENABLED = getgenv().TARGET_FACING_CHECK_ENABLED or false
getgenv().TARGET_FACING_ANGLE = tonumber(getgenv().TARGET_FACING_ANGLE) or 75
getgenv().SHEATH_CHECK_ENABLED = getgenv().SHEATH_CHECK_ENABLED or false
getgenv().PING_COMPENSATION = tonumber(getgenv().PING_COMPENSATION) or 0
getgenv().WHITELISTED_PLAYERS = getgenv().WHITELISTED_PLAYERS or {}
getgenv().FAILURE_RATE = tonumber(getgenv().FAILURE_RATE) or 0
getgenv().ROLL_ON_COOLDOWN_ENABLED = getgenv().ROLL_ON_COOLDOWN_ENABLED or false
getgenv().ANIMATION_CHECK_ENABLED = getgenv().ANIMATION_CHECK_ENABLED or false
getgenv().LAST_PARRY_TIME = tonumber(getgenv().LAST_PARRY_TIME) or 0
getgenv().PARRY_COOLDOWN = tonumber(getgenv().PARRY_COOLDOWN) or 0.5
getgenv().ACTUAL_PARRY_COOLDOWN = tonumber(getgenv().ACTUAL_PARRY_COOLDOWN) or 0.5

-- Services
local lp = game.Players.LocalPlayer
local character = lp.Character or lp.CharacterAdded:Wait()
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BlockRemote = ReplicatedStorage:WaitForChild("Bridgenet2Main"):WaitForChild("dataRemoteEvent")

-- Variables
local connections = {}
local allAnims = {}
local activeBlockWindows = {}
local isCurrentlyParrying = false
local lastParryTime = 0

-- Anti-detection hook
local CP = game:GetService("ContentProvider")
local old_namecall
old_namecall = hookmetamethod(game, "__namecall", function(self, ...)
    local method = getnamecallmethod()
    if self == CP and (method == "GetAssetFetchStatus" or method == "GetAssetFetchStatusChangedSignal") then
        return task.wait(9e9)
    end
    return old_namecall(self, ...)
end)

-- Helper Functions
local function normalizeAnimId(idStr)
    if not idStr then return "" end
    local digits = tostring(idStr):match("%d+")
    return digits or tostring(idStr)
end

local function debugPrint(...)
    if getgenv().DEBUG_ENABLED then
        print("[AutoParry]", ...)
    end
end

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

-- Base64 decode
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

-- Load animation data
local function loadAnimationData()
    local DATA_URL = "https://raw.githubusercontent.com/fdsfdsadASDSADASD/FDHFGHFDGFDVHDA/refs/heads/main/ghdfghdgfdgdsf.txt"
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
            debugPrint("Animation data loaded successfully")
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

-- Build combatAnims
for animId, animInfo in pairs(animationData) do
    if type(animInfo) ~= "table" then continue end
    
    local hitWindows = {}
    local baseHold = tonumber(animInfo.hold)
    if not baseHold or type(baseHold) ~= "number" then baseHold = 0.15 end

    for key, value in pairs(animInfo) do
        local idxStr = tostring(key):match("^startSec(%d*)$")
        if idxStr ~= nil then
            local idx = (idxStr == "") and 1 or tonumber(idxStr)
            local startTime = tonumber(value)
            if startTime and type(startTime) == "number" then
                local holdKey = (idx == 1) and "hold" or ("hold" .. idx)
                local holdVal = tonumber(animInfo[holdKey])
                if not holdVal or type(holdVal) ~= "number" then
                    holdVal = baseHold
                end
                table.insert(hitWindows, {
                    startTime = startTime,
                    hold = holdVal
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

-- Setup player animations
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

-- Initialize players
for _, player in pairs(game.Workspace.Entities:GetChildren()) do
    setupPlayerAnimations(player)
end

local con = game.Workspace.Entities.ChildAdded:Connect(function(child)
    wait(1)
    setupPlayerAnimations(child)
end)
table.insert(connections, con)

-- Damage monitor
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

-- Cooldown tracking
local function setupCooldownTracking()
    local replicatedStorage = game:GetService("ReplicatedStorage")
    pcall(function()
        local cooldownRemote = replicatedStorage:WaitForChild("Remotes"):WaitForChild("HUDCooldownUpdate")
        cooldownRemote.OnClientEvent:Connect(function(abilityName, cooldownDuration)
            if abilityName == "Block" or abilityName == "Parry" then
                getgenv().ACTUAL_PARRY_COOLDOWN = cooldownDuration or 0.5
                debugPrint("Parry cooldown updated:", cooldownDuration)
            end
        end)
    end)
end

setupCooldownTracking()

-- Main parry loop
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
            
            local animId = normalizeAnimId(animInfo.anim.AnimationId)
            local attackerName = animInfo.plr.Name
            
            -- Whitelist check
            if table.find(getgenv().WHITELISTED_PLAYERS, attackerName) then
                continue
            end
            
            local combatInfo = nil
            for _, entry in ipairs(combatAnims) do
                if entry.AnimationId == animId then
                    combatInfo = entry
                    break
                end
            end
            
            if not combatInfo then continue end
            
            local attackerHRP = animInfo.plr:FindFirstChild("HumanoidRootPart")
            if not attackerHRP then continue end
            
            local dist = (myHRP.Position - attackerHRP.Position).Magnitude
            if dist > getgenv().DETECTION_DISTANCE then continue end
            
            if getgenv().TARGET_FACING_CHECK_ENABLED then
                if not isTargetFacingMe(attackerHRP, myHRP) then
                    continue
                end
            end
            
            if getgenv().SHEATH_CHECK_ENABLED then
                if not isWeaponOut() then
                    continue
                end
            end
            
            -- Failure rate check
            if getgenv().FAILURE_RATE > 0 then
                if math.random(1, 100) <= getgenv().FAILURE_RATE then
                    debugPrint("Intentionally skipping parry due to failure rate")
                    animInfo.parried = true
                    continue
                end
            end
            
            local elapsed = tick() - animInfo.startTime
            
            for _, window in ipairs(combatInfo.HitWindows) do
                local adjustedStart = window.startTime + (getgenv().PING_COMPENSATION / 1000)
                local timeUntilParry = adjustedStart - elapsed
                
                if timeUntilParry > 0 and timeUntilParry < 0.1 then
                    if not isCurrentlyParrying then
                        if getgenv().ANIMATION_CHECK_ENABLED then
                            task.wait(0.01)
                            if not animTrack.IsPlaying then
                                debugPrint("Animation stopped before parry")
                                animInfo.parried = true
                                break
                            end
                        end
                        
                        isCurrentlyParrying = true
                        task.spawn(function()
                            local currentTick = tick()
                            local timeSinceLastParry = currentTick - lastParryTime
                            
                            if timeSinceLastParry < getgenv().ACTUAL_PARRY_COOLDOWN then
                                if getgenv().ROLL_ON_COOLDOWN_ENABLED then
                                    debugPrint("Parry on cooldown - rolling instead")
                                    sendAction("Dodge")
                                else
                                    debugPrint("Parry on cooldown - skipping")
                                end
                            else
                                debugPrint("Parrying", attackerName, "at", string.format("%.3f", elapsed), "s")
                                sendAction("Block")
                                lastParryTime = currentTick
                            end
                            
                            task.wait(0.1)
                            isCurrentlyParrying = false
                        end)
                        
                        animInfo.parried = true
                        break
                    end
                end
            end
        end
    end
end)

-- Cleanup stale entries
task.spawn(function()
    while true do
        task.wait(5)
        for animTrack, _ in pairs(allAnims) do
            if not animTrack.IsPlaying then
                allAnims[animTrack] = nil
            end
        end
        local currentTick = tonumber(tick())
        local lastTick = tonumber(lastParryTime)
        if currentTick and lastTick and type(currentTick) == "number" and type(lastTick) == "number" then
            if isCurrentlyParrying and (currentTick - lastTick > 2) then
                isCurrentlyParrying = false
                debugPrint("Reset stuck parry lock")
            end
        end
    end
end)

-- Character respawn
lp.CharacterAdded:Connect(function(newCharacter)
    character = newCharacter
    setupDamageMonitor()
    allAnims = {}
    isCurrentlyParrying = false
end)

-- Cleanup function
function AutoParry:Cleanup()
    for i, connection in pairs(connections) do
        if typeof(connection) == "RBXScriptConnection" then
            connection:Disconnect()
        end
    end
    table.clear(connections)
    table.clear(allAnims)
end

debugPrint("AutoParry module loaded successfully")

return AutoParry
