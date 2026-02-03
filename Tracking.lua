--[[
    Szczeszczyr - Smart Resurrection Addon
    Tracking.lua - Optimized UNIT_CASTEVENT handling
]]

local Szcz = Szczeszczyr

-- Localize globals for hot path
local pairs = pairs
local GetTime = GetTime

--[[
    Pending resurrections table (supports multiple casters per target)
    Key: targetGUID
    Value: { casters = { [casterGUID] = endTime, ... } }
]]
Szcz.pendingRes = {}

--[[
    Reverse lookup: casterGUID -> targetGUID
    Used for FAIL events (which have empty targetGUID in SuperWoW)
]]
Szcz.casterToTarget = {}

--[[
    Check if a target has any active casters (non-expired)
    Returns: true if any caster is still casting, false otherwise
]]
local function HasActiveCasters(targetGUID)
    local pending = Szcz.pendingRes[targetGUID]
    if not pending or not pending.casters then return false end

    local now = GetTime()
    for casterGUID, endTime in pairs(pending.casters) do
        if endTime > now then
            return true
        end
    end
    return false
end

--[[
    Recently resurrected players (received res, waiting to accept)
    Key: targetGUID
    Value: timestamp
]]
Szcz.recentlyRessed = {}

-- Use shared constant from Data.lua
local RECENTLY_TIMEOUT = Szcz.Data.RECENTLY_TIMEOUT

--[[
    Dedicated event frame for UNIT_CASTEVENT
]]
local castFrame = CreateFrame("Frame", "SzczeszczyrCastFrame")

local function OnCastEvent()
    -- Fast exit: check spell ID first
    local spellId = arg4
    local TRACKED = Szcz.Data and Szcz.Data.RES_SPELL_IDS
    if not TRACKED then return end

    local spellType = TRACKED[spellId]
    if not spellType then return end

    local eventType = arg3
    local casterGUID = arg1
    local targetGUID = arg2
    local now = GetTime()

    if eventType == "START" then
        local duration = arg5 * 0.001
        local endTime = now + duration

        -- Initialize target entry if needed (supports multiple casters)
        if not Szcz.pendingRes[targetGUID] then
            Szcz.pendingRes[targetGUID] = { casters = {} }
        end

        -- Add/update this caster's entry
        Szcz.pendingRes[targetGUID].casters[casterGUID] = endTime
        Szcz.casterToTarget[casterGUID] = targetGUID
        Szcz.recentlyRessed[targetGUID] = nil

        -- If someone else started ressing our tracked target, clear tracking
        if targetGUID == Szcz.state.trackedGUID and casterGUID ~= Szcz.playerGUID then
            Szcz.StopCorpseTracking()
            Szcz.ForceButtonUpdate()
        end

    elseif eventType == "CAST" then
        -- Remove this caster from the target's casters list
        Szcz.casterToTarget[casterGUID] = nil
        if Szcz.pendingRes[targetGUID] then
            Szcz.pendingRes[targetGUID].casters[casterGUID] = nil
            -- Only remove target entry if no active casters remain
            if not HasActiveCasters(targetGUID) then
                Szcz.pendingRes[targetGUID] = nil
            end
        end

        -- Target received res, add to recently ressed
        Szcz.recentlyRessed[targetGUID] = now

        -- If player cast salts, mark on cooldown
        if spellType == "salts" and casterGUID == Szcz.playerGUID then
            Szcz.OnSaltsCast()
        end

        -- If our tracked target was ressed, clear tracking
        if targetGUID == Szcz.state.trackedGUID then
            Szcz.StopCorpseTracking()
        end

        Szcz.ForceButtonUpdate()

    elseif eventType == "FAIL" or eventType == "FAILED" or eventType == "INTERRUPT" then
        -- FAIL has empty targetGUID in SuperWoW - use reverse lookup
        local actualTarget = targetGUID
        if not actualTarget or actualTarget == "" then
            actualTarget = Szcz.casterToTarget[casterGUID]
        end

        -- Remove this caster's entries
        Szcz.casterToTarget[casterGUID] = nil
        if actualTarget and Szcz.pendingRes[actualTarget] then
            Szcz.pendingRes[actualTarget].casters[casterGUID] = nil
            -- Only remove target entry if no active casters remain
            if not HasActiveCasters(actualTarget) then
                Szcz.pendingRes[actualTarget] = nil
            end
        end

        Szcz.ForceButtonUpdate()
    end
end

--[[
    Register UNIT_CASTEVENT (called when entering group)
]]
function Szcz.RegisterCastTracking()
    castFrame:RegisterEvent("UNIT_CASTEVENT")
    castFrame:SetScript("OnEvent", OnCastEvent)
end

--[[
    Unregister UNIT_CASTEVENT (called when leaving group)
]]
function Szcz.UnregisterCastTracking()
    castFrame:UnregisterEvent("UNIT_CASTEVENT")
    castFrame:SetScript("OnEvent", nil)
end

--[[
    Check if a target is being resurrected
    Returns: isPending, remainingSeconds (or nil)
]]
function Szcz.IsPendingRes(targetGUID)
    local pending = Szcz.pendingRes[targetGUID]
    if not pending or not pending.casters then
        return false, nil
    end

    local now = GetTime()
    local maxEndTime = 0

    -- Check all casters, clean expired ones lazily
    for casterGUID, endTime in pairs(pending.casters) do
        if endTime > now then
            if endTime > maxEndTime then
                maxEndTime = endTime
            end
        else
            -- Expired caster, clean up
            pending.casters[casterGUID] = nil
            Szcz.casterToTarget[casterGUID] = nil
        end
    end

    -- If no active casters remain, remove the target entry
    if maxEndTime == 0 then
        Szcz.pendingRes[targetGUID] = nil
        return false, nil
    end

    return true, maxEndTime - now
end

--[[
    Check if player was recently resurrected (waiting to accept)
]]
function Szcz.IsRecentlyRessed(targetGUID)
    local timestamp = Szcz.recentlyRessed[targetGUID]
    if not timestamp then
        return false
    end

    local now = GetTime()
    if now - timestamp > RECENTLY_TIMEOUT then
        Szcz.recentlyRessed[targetGUID] = nil
        return false
    end

    return true
end

--[[
    Clear recently ressed status for a player
]]
function Szcz.ClearRecentlyRessed(targetGUID)
    Szcz.recentlyRessed[targetGUID] = nil
end

--[[
    Clean stale entries from all tracking tables
]]
function Szcz.CleanStalePending()
    local now = GetTime()

    -- Clean pendingRes - iterate each target's casters
    for targetGUID, data in pairs(Szcz.pendingRes) do
        if data.casters then
            -- Clean expired casters for this target
            for casterGUID, endTime in pairs(data.casters) do
                if endTime < now then
                    data.casters[casterGUID] = nil
                    Szcz.casterToTarget[casterGUID] = nil
                end
            end
            -- Remove target entry if no casters remain
            if not HasActiveCasters(targetGUID) then
                Szcz.pendingRes[targetGUID] = nil
            end
        else
            -- Legacy format or corrupted entry, remove it
            Szcz.pendingRes[targetGUID] = nil
        end
    end

    -- Clean recentlyRessed
    for guid, timestamp in pairs(Szcz.recentlyRessed) do
        if now - timestamp > RECENTLY_TIMEOUT then
            Szcz.recentlyRessed[guid] = nil
        end
    end
end
