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

--[[
    Salts State
]]
Szcz.saltsState = {
    available = false,
    onCooldown = false,
    cdEndTime = nil,  -- Exact time when cooldown ends (for efficient polling)
    bag = nil,
    slot = nil,
    count = 0,
}

--[[
    Scan bags for salts, check cooldown, update state
]]
function Szcz.ScanForSalts()
    local itemId = Szcz.Data.SALTS_ITEM_ID

    -- Reset state
    Szcz.saltsState.available = false
    Szcz.saltsState.bag = nil
    Szcz.saltsState.slot = nil
    Szcz.saltsState.count = 0

    -- Scan bags 0-4
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, _, id = string_find(link, "item:(%d+)")
                if id and tonumber(id) == itemId then
                    local _, count = GetContainerItemInfo(bag, slot)
                    Szcz.saltsState.bag = bag
                    Szcz.saltsState.slot = slot
                    Szcz.saltsState.count = count or 1

                    local start, duration = GetContainerItemCooldown(bag, slot)
                    if start and start > 0 and duration and duration > 0 then
                        local remaining = (start + duration) - GetTime()
                        Szcz.saltsState.onCooldown = (remaining > 0)
                        Szcz.saltsState.cdEndTime = start + duration  -- Store exact end time
                    else
                        Szcz.saltsState.onCooldown = false
                        Szcz.saltsState.cdEndTime = nil
                    end

                    Szcz.saltsState.available = not Szcz.saltsState.onCooldown
                    return
                end
            end
        end
    end
end

--[[
    Called when UNIT_CASTEVENT detects player casting salts
]]
function Szcz.OnSaltsCast()
    Szcz.saltsState.onCooldown = true
    Szcz.saltsState.available = false
    Szcz.saltsState.cdEndTime = GetTime() + Szcz.Data.SALTS_COOLDOWN
end

--[[
    Check if player can use salts right now
]]
function Szcz.CanUseSalts()
    local state = Szcz.state
    if state and state.inCombat then return false end
    return Szcz.saltsState.available and Szcz.saltsState.bag ~= nil
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
