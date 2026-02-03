--[[
    Szczeszczyr - Smart Resurrection Addon
    State.lua - Central state management
]]

local Szcz = Szczeszczyr

-- Localize globals
local GetNumRaidMembers = GetNumRaidMembers
local GetNumPartyMembers = GetNumPartyMembers
local GetBattlefieldStatus = GetBattlefieldStatus
local pairs = pairs

--[[
    Central state - no scattered globals
]]
Szcz.state = {
    inGroup = false,
    inCombat = false,
    inBattleground = false,
    unlocked = false,       -- UI position unlocked for editing
    trackedGUID = nil,      -- Current corpse being tracked on minimap (set by CorpseTracker)
}

-- Skipped targets (right-click cycling)
Szcz.skippedTargets = {}
Szcz.skipTimestamp = 0  -- GetTime() of last skip

-- Dead player cache (on-demand, only for dead players)
Szcz.deadCache = {}          -- unitId -> { guid, classFile, name }
Szcz.deadCacheStale = false  -- Set true on roster/zone change

-- Pool for reusing cache entry tables (avoids garbage when players get ressed)
local deadCachePool = {}
local deadCachePoolSize = 0

function Szcz.GetDeadCacheEntry()
    if deadCachePoolSize > 0 then
        local entry = deadCachePool[deadCachePoolSize]
        deadCachePool[deadCachePoolSize] = nil
        deadCachePoolSize = deadCachePoolSize - 1
        return entry
    end
    return {}
end

function Szcz.ReturnDeadCacheEntry(entry)
    entry.guid = nil
    entry.classFile = nil
    entry.name = nil
    deadCachePoolSize = deadCachePoolSize + 1
    deadCachePool[deadCachePoolSize] = entry
end

--[[
    Mark dead cache as stale (lazy invalidation)
]]
function Szcz.InvalidateDeadCache()
    Szcz.deadCacheStale = true
end

--[[
    Clear dead cache entirely (called when leaving group)
]]
function Szcz.ClearDeadCache()
    for unitId, entry in pairs(Szcz.deadCache) do
        Szcz.ReturnDeadCacheEntry(entry)
        Szcz.deadCache[unitId] = nil
    end
    Szcz.deadCacheStale = false
end

--[[
    Update group state and manage tracking/buttons
]]
function Szcz.UpdateGroupState()
    local wasInGroup = Szcz.state.inGroup
    Szcz.state.inGroup = GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0

    if Szcz.state.inGroup and not wasInGroup then
        -- Entered group
        Szcz.RegisterCastTracking()
        if not Szcz.state.inCombat then
            Szcz.ShowButtons()
        end
    elseif not Szcz.state.inGroup and wasInGroup then
        -- Left group
        Szcz.UnregisterCastTracking()
        Szcz.ClearAllTracking()
        Szcz.HideButtons()
    end
end

--[[
    Update combat state and handle UI
]]
function Szcz.UpdateCombatState(inCombat)
    Szcz.state.inCombat = inCombat

    if inCombat then
        Szcz.HideButtons()
        Szcz.StopCorpseTracking()
    else
        -- Refresh salts state after combat (verify CD, handle edge cases)
        Szcz.RefreshSaltsState()
        if Szcz.state.inGroup then
            Szcz.ShowButtons()
        end
    end
end

--[[
    Check if player is in a battleground
]]
function Szcz.CheckBattleground()
    local status = GetBattlefieldStatus(1)
    Szcz.state.inBattleground = (status == "active")
    return Szcz.state.inBattleground
end

--[[
    Clear all tracking data
    Note: Tables (pendingRes, casterToTarget, recentlyRessed) always exist after Tracking.lua loads
]]
function Szcz.ClearAllTracking()
    for k in pairs(Szcz.pendingRes) do
        Szcz.pendingRes[k] = nil
    end

    for k in pairs(Szcz.casterToTarget) do
        Szcz.casterToTarget[k] = nil
    end

    for k in pairs(Szcz.recentlyRessed) do
        Szcz.recentlyRessed[k] = nil
    end

    Szcz.ResetSkippedTargets()
    Szcz.state.trackedGUID = nil
    Szcz.ClearDeadCache()

    Szcz.StopCorpseTracking()
end

--[[
    Check if addon should be active
]]
function Szcz.IsAddonActive()
    return Szcz.state.inGroup and not Szcz.state.inBattleground and not Szcz.state.inCombat
end

--[[
    Skip a target (right-click cycling)
]]
function Szcz.SkipTarget(guid)
    if not guid then return end
    Szcz.skippedTargets[guid] = true
    Szcz.skipTimestamp = GetTime()
end

--[[
    Check if target is skipped
]]
function Szcz.IsSkipped(guid)
    return guid and Szcz.skippedTargets[guid] or false
end

--[[
    Reset all skipped targets
]]
function Szcz.ResetSkippedTargets()
    for k in pairs(Szcz.skippedTargets) do
        Szcz.skippedTargets[k] = nil
    end
    Szcz.skipTimestamp = 0
end
