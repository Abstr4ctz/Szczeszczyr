--[[
    Szczeszczyr - Smart Resurrection Addon
    Casting.lua - Salts management, spell casting
]]

local Szcz = Szczeszczyr

-- Localize
local GetTime = GetTime
local GetContainerNumSlots = GetContainerNumSlots
local GetContainerItemLink = GetContainerItemLink
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerItemCooldown = GetContainerItemCooldown
local UseContainerItem = UseContainerItem
local CastSpellByName = CastSpellByName
local TargetUnit = TargetUnit
local UnitIsDead = UnitIsDead
local GetNumRaidMembers = GetNumRaidMembers
local GetNumPartyMembers = GetNumPartyMembers
local string_find = string.find
local tonumber = tonumber
local time = time
local math_ceil = math.ceil
local math_abs = math.abs

--[[
    Salts State (simplified, event-driven)
]]
Szcz.saltsState = {
    hasSalts = false,    -- Are salts currently in bags?
    bag = nil,           -- Bag index (0-4)
    slot = nil,          -- Slot index
    cdEndUnix = nil,     -- Unix timestamp when CD ends (mirrors DB)
}

-- Throttle for bag scanning (handles bag-sorting addon spam)
local lastSaltsScan = 0
local SALTS_SCAN_THROTTLE = 5  -- seconds

--[[
    Check if item at specific slot is salts, update cooldown if found
    Returns: true if salts found at this location, false otherwise
]]
local function CheckSaltsAtSlot(bag, slot)
    local link = GetContainerItemLink(bag, slot)
    if not link then return false end

    local _, _, id = string_find(link, "item:(%d+)")
    if not id or tonumber(id) ~= Szcz.Data.SALTS_ITEM_ID then
        return false
    end

    -- Salts found at cached location, check cooldown
    local start, duration = GetContainerItemCooldown(bag, slot)
    if start and start > 0 and duration and duration > 0 then
        local remaining = (start + duration) - GetTime()
        if remaining > 0 then
            -- Convert to Unix timestamp (ceil to be conservative - CD never ends early)
            local newCdEnd = time() + math_ceil(remaining)
            -- Only update DB if difference > 10 seconds (avoids spurious writes, negligible for 5h CD)
            local currentCd = Szcz.saltsState.cdEndUnix
            if not currentCd or math_abs(currentCd - newCdEnd) > 10 then
                Szcz.saltsState.cdEndUnix = newCdEnd
                Szcz.SetSetting("saltsCdEndUnix", newCdEnd)
            end
        else
            -- CD expired
            if Szcz.saltsState.cdEndUnix then
                Szcz.saltsState.cdEndUnix = nil
                Szcz.SetSetting("saltsCdEndUnix", nil)
            end
        end
    else
        -- No cooldown
        if Szcz.saltsState.cdEndUnix then
            Szcz.saltsState.cdEndUnix = nil
            Szcz.SetSetting("saltsCdEndUnix", nil)
        end
    end

    Szcz.saltsState.hasSalts = true
    return true
end

--[[
    Full bag scan for salts (slow path)
]]
local function ScanAllBagsForSalts()
    local itemId = Szcz.Data.SALTS_ITEM_ID

    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, _, id = string_find(link, "item:(%d+)")
                if id and tonumber(id) == itemId then
                    -- Found salts, update location
                    Szcz.saltsState.bag = bag
                    Szcz.saltsState.slot = slot
                    -- Check cooldown at this location
                    CheckSaltsAtSlot(bag, slot)
                    return
                end
            end
        end
    end

    -- Salts not found in bags
    Szcz.saltsState.hasSalts = false
    Szcz.saltsState.bag = nil
    Szcz.saltsState.slot = nil
    -- Keep cdEndUnix - cooldown is still ticking even if salts are banked
end

--[[
    Refresh salts state (called on PLAYER_ENTERING_WORLD, BAG_UPDATE, PLAYER_REGEN_ENABLED)
    - Throttled to prevent spam from bag-sorting addons
    - Fast path: check cached bag/slot first
    - Slow path: full bag scan if salts moved
]]
function Szcz.RefreshSaltsState()
    -- 1. Throttle (skip if < 5s since last scan)
    local now = GetTime()
    if now - lastSaltsScan < SALTS_SCAN_THROTTLE then
        return
    end
    lastSaltsScan = now

    -- 2. Load DB cooldown into memory (if not already loaded)
    if not Szcz.saltsState.cdEndUnix then
        Szcz.saltsState.cdEndUnix = Szcz.GetSetting("saltsCdEndUnix")
    end

    -- 3. Fast path: check cached bag/slot first
    local state = Szcz.saltsState
    if state.bag and state.slot then
        if CheckSaltsAtSlot(state.bag, state.slot) then
            return  -- Found at cached location, done
        end
    end

    -- 4. Slow path: full bag scan (salts moved or first scan)
    ScanAllBagsForSalts()
end

--[[
    Called when UNIT_CASTEVENT detects player casting salts successfully
]]
function Szcz.OnSaltsCast()
    local cdEnd = time() + Szcz.Data.SALTS_COOLDOWN
    Szcz.saltsState.cdEndUnix = cdEnd
    Szcz.SetSetting("saltsCdEndUnix", cdEnd)
    -- hasSalts stays true (we just used them, they exist)
end

--[[
    Check if player can use salts right now (pure timestamp check, no API calls)
]]
function Szcz.CanUseSalts()
    if Szcz.state and Szcz.state.inCombat then return false end
    if not Szcz.saltsState.hasSalts then return false end
    local cdEnd = Szcz.saltsState.cdEndUnix
    if cdEnd and time() < cdEnd then return false end
    return true
end

--[[
    Legacy function name for compatibility (redirects to new system)
]]
function Szcz.ScanForSalts()
    -- Reset throttle to force immediate scan
    lastSaltsScan = 0
    Szcz.RefreshSaltsState()
end

--[[
    Check if player's class can resurrect with spells
]]
function Szcz.CanPlayerRes()
    local Data = Szcz.Data
    if not Data or not Data.RES_CLASSES then return false end
    return Data.RES_CLASSES[Szcz.playerClass] == true
end

--[[
    Res spell book slot cache (for cooldown/range checking)
]]
local resSpellSlot = nil

function Szcz.CacheResSpellSlot()
    local Data = Szcz.Data
    if not Data or not Data.CLASS_RES_SPELL_NAME then return end
    local spell = Data.CLASS_RES_SPELL_NAME[Szcz.playerClass]
    if not spell then return end

    for i = 1, 200 do
        local name = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if name == spell then
            resSpellSlot = i
            return
        end
    end
end

function Szcz.GetResSpellSlot()
    return resSpellSlot
end

--[[
    Get resurrection spell name for player's class
]]
function Szcz.GetPlayerResSpell()
    local Data = Szcz.Data
    if not Data or not Data.CLASS_RES_SPELL_NAME then return nil end
    return Data.CLASS_RES_SPELL_NAME[Szcz.playerClass]
end

--[[
    Check if target is in salts range
]]
function Szcz.IsInSaltsRange(unitId)
    local distance = Szcz.GetDistance(unitId)
    local saltsRange = (Szcz.Data and Szcz.Data.SALTS_RANGE) or 5
    if distance then
        return distance <= saltsRange
    end
    return true
end

--[[
    Main resurrection function
    useSalts: true = use salts (closest), false = use spell (furthest), nil = auto
]]
function Szcz.DoResurrection(useSalts)
    -- Silent exit if player dead
    if UnitIsDead("player") then
        return
    end

    -- Silent exit if in combat
    local state = Szcz.state
    if state and state.inCombat then
        return
    end

    -- Silent exit if not in group
    if GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0 then
        return
    end

    -- Determine mode if not specified (non-healers always use salts)
    if useSalts == nil then
        useSalts = not Szcz.CanPlayerRes()
    end

    -- Check if we can actually use salts
    if useSalts and not Szcz.CanUseSalts() then
        if not Szcz.CanPlayerRes() then
            DEFAULT_CHAT_FRAME:AddMessage("|cff9acd32Szczeszczyr|r: No salts available")
            return
        end
        useSalts = false
    end

    -- Check if healer trying to use spell but doesn't have one
    if not useSalts and not Szcz.CanPlayerRes() then
        DEFAULT_CHAT_FRAME:AddMessage("|cff9acd32Szczeszczyr|r: Your class cannot resurrect")
        return
    end

    -- Get target
    local unitId, name = Szcz.SelectTarget(useSalts)
    if not unitId then
        return
    end

    -- Target the player
    TargetUnit(unitId)

    -- Cast
    if useSalts then
        UseContainerItem(Szcz.saltsState.bag, Szcz.saltsState.slot)
    else
        local spell = Szcz.GetPlayerResSpell()
        if spell then
            CastSpellByName(spell)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff9acd32Szczeszczyr|r: No resurrection spell found")
        end
    end
end
