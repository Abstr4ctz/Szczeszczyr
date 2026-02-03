--[[
    Szczeszczyr - Smart Resurrection Addon
    Targeting.lua - Priority chain (filter/sort/select)
    Optimized with table pooling to reduce GC pressure
]]

local Szcz = Szczeszczyr

-- Localize frequently used functions
local UnitExists = UnitExists
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsGhost = UnitIsGhost
local UnitIsConnected = UnitIsConnected
local UnitBuff = UnitBuff
local GetNumRaidMembers = GetNumRaidMembers
local GetNumPartyMembers = GetNumPartyMembers
local UnitPosition = UnitPosition
local UnitClass = UnitClass
local UnitName = UnitName
local GetTime = GetTime
local table_getn = table.getn
local table_sort = table.sort
local math_sqrt = math.sqrt
local pairs = pairs

-- Use shared unit ID strings from Data.lua
local RAID_UNITS = Szcz.Data.RAID_UNITS
local PARTY_UNITS = Szcz.Data.PARTY_UNITS

--[[
    Table pools - reused every frame to avoid GC
]]
local deadPool = {}
local validPool = {}
local filteredPool = {}
local tiersPool = { {}, {}, {} }
local tierCounts = { 0, 0, 0 }  -- Pre-allocated, reset each use

-- Player data objects pool (reuse player info tables)
local playerPool = {}
local playerPoolSize = 0
local MAX_POOL_SIZE = 40  -- Max raid size

local function WipeTable(t)
    for k in pairs(t) do t[k] = nil end
end

--[[
    Pre-created sort comparators (avoid closure allocation every call)
    Used by SelectFromList - choosing between these is a simple branch, no alloc
]]
local function SortClosest(a, b)
    if not a or not b then return false end
    if a.inRange ~= b.inRange then return a.inRange end
    if not a.distance then return false end
    if not b.distance then return true end
    return a.distance < b.distance
end

local function SortFurthest(a, b)
    if not a or not b then return false end
    if a.inRange ~= b.inRange then return a.inRange end
    if not a.distance then return false end
    if not b.distance then return true end
    return a.distance > b.distance
end

local function WipeTiers()
    for i = 1, 3 do
        WipeTable(tiersPool[i])
    end
end

local function GetPlayerFromPool()
    if playerPoolSize > 0 then
        local player = playerPool[playerPoolSize]
        playerPool[playerPoolSize] = nil
        playerPoolSize = playerPoolSize - 1
        return player
    end
    return {}
end

local function ReturnPlayerToPool(player)
    if playerPoolSize < MAX_POOL_SIZE then
        -- Clear fields
        player.unitId = nil
        player.classFile = nil
        player.guid = nil
        player.name = nil
        player.distance = nil
        player.inLoS = nil
        playerPoolSize = playerPoolSize + 1
        playerPool[playerPoolSize] = player
    end
end

local function ReturnAllPlayersToPool(list)
    local count = table_getn(list)
    for i = 1, count do
        ReturnPlayerToPool(list[i])
        list[i] = nil
    end
end

--[[
    Get all dead players in raid/party
    On-demand caching: TRUE ZERO allocations when same players dead as last poll
]]
local function GetDeadPlayers(outTable)
    ReturnAllPlayersToPool(outTable)
    local numRaid = GetNumRaidMembers()
    local numParty = GetNumPartyMembers()
    local idx = 0
    local deadCache = Szcz.deadCache
    local cacheStale = Szcz.deadCacheStale

    if numRaid > 0 then
        for i = 1, numRaid do
            local unitId = RAID_UNITS[i]

            -- Fast check: is this player dead and online?
            -- UnitIsDeadOrGhost returns nil for empty slots and alive players
            if UnitIsDeadOrGhost(unitId) and UnitIsConnected(unitId) then
                local cached = deadCache[unitId]

                if cached and not cacheStale then
                    -- Cache hit - ZERO allocation
                    local player = GetPlayerFromPool()
                    player.unitId = unitId
                    player.classFile = cached.classFile
                    player.guid = cached.guid
                    player.name = cached.name
                    idx = idx + 1
                    outTable[idx] = player
                else
                    -- Cache miss or stale - fetch and cache
                    local exists, guid = UnitExists(unitId)
                    if exists and guid then
                        local _, classFile = UnitClass(unitId)
                        local name = UnitName(unitId)

                        -- Get or create cache entry (reuses pooled tables)
                        if not cached then
                            cached = Szcz.GetDeadCacheEntry()
                            deadCache[unitId] = cached
                        end
                        cached.guid = guid
                        cached.classFile = classFile
                        cached.name = name

                        local player = GetPlayerFromPool()
                        player.unitId = unitId
                        player.classFile = classFile
                        player.guid = guid
                        player.name = name
                        idx = idx + 1
                        outTable[idx] = player
                    end
                end
            else
                -- Not dead or offline - return cache entry to pool
                if deadCache[unitId] then
                    Szcz.ReturnDeadCacheEntry(deadCache[unitId])
                    deadCache[unitId] = nil
                end
            end
        end
    elseif numParty > 0 then
        for i = 1, numParty do
            local unitId = PARTY_UNITS[i]

            if UnitIsDeadOrGhost(unitId) and UnitIsConnected(unitId) then
                local cached = deadCache[unitId]

                if cached and not cacheStale then
                    local player = GetPlayerFromPool()
                    player.unitId = unitId
                    player.classFile = cached.classFile
                    player.guid = cached.guid
                    player.name = cached.name
                    idx = idx + 1
                    outTable[idx] = player
                else
                    local exists, guid = UnitExists(unitId)
                    if exists and guid then
                        local _, classFile = UnitClass(unitId)
                        local name = UnitName(unitId)

                        if not cached then
                            cached = Szcz.GetDeadCacheEntry()
                            deadCache[unitId] = cached
                        end
                        cached.guid = guid
                        cached.classFile = classFile
                        cached.name = name

                        local player = GetPlayerFromPool()
                        player.unitId = unitId
                        player.classFile = classFile
                        player.guid = guid
                        player.name = name
                        idx = idx + 1
                        outTable[idx] = player
                    end
                end
            else
                if deadCache[unitId] then
                    Szcz.ReturnDeadCacheEntry(deadCache[unitId])
                    deadCache[unitId] = nil
                end
            end
        end
    end

    -- Clear stale flag after processing all dead players
    if cacheStale then
        Szcz.deadCacheStale = false
    end

    return idx
end

--[[
    Check if a hunter is feigning death
]]
local function IsHunterFeigningDeath(unitId, classFile)
    if classFile ~= "HUNTER" then
        return false
    end
    local feignTexture = Szcz.Data and Szcz.Data.FEIGN_DEATH_TEXTURE
    if not feignTexture then return false end

    for i = 1, 32 do
        local texture = UnitBuff(unitId, i)
        if not texture then break end
        if texture == feignTexture then
            return true
        end
    end
    return false
end

--[[
    Check if unit is in line of sight (requires UnitXP)
]]
function Szcz.IsInLoS(unitId)
    if not Szcz.hasUnitXP then return true end
    return UnitXP("inSight", "player", unitId)
end

--[[
    Filter out invalid targets
    Removes: ghosts, feigning hunters, recently ressed
]]
local function FilterValidTargets(deadList, deadCount, outTable)
    WipeTable(outTable)
    local idx = 0

    for i = 1, deadCount do
        local player = deadList[i]
        local skip = false

        if UnitIsGhost(player.unitId) then
            skip = true
        elseif IsHunterFeigningDeath(player.unitId, player.classFile) then
            skip = true
        elseif Szcz.IsRecentlyRessed(player.guid) then
            if not UnitIsDeadOrGhost(player.unitId) then
                Szcz.ClearRecentlyRessed(player.guid)
            else
                skip = true
            end
        end

        if not skip then
            idx = idx + 1
            outTable[idx] = player
        end
    end

    return idx
end

--[[
    Filter out targets being resurrected by others
]]
local function FilterPendingRes(validList, validCount, outTable)
    WipeTable(outTable)
    local idx = 0
    for i = 1, validCount do
        local player = validList[i]
        local isPending = Szcz.IsPendingRes(player.guid)

        if not isPending then
            idx = idx + 1
            outTable[idx] = player
        end
    end

    return idx
end

--[[
    Filter out skipped targets (right-click cycling)
    Also checks timeout and resets if expired
]]
local function FilterSkippedTargets(validList, validCount, outTable)
    WipeTable(outTable)

    -- Check timeout reset (lazy evaluation - no OnUpdate needed)
    local TARGETING = Szcz.Data.TARGETING or {}
    local SKIP_TIMEOUT = TARGETING.SKIP_TIMEOUT or 20
    if Szcz.skipTimestamp > 0 then
        if GetTime() - Szcz.skipTimestamp >= SKIP_TIMEOUT then
            Szcz.ResetSkippedTargets()
        end
    end

    local idx = 0
    local skippedCount = 0

    for i = 1, validCount do
        local player = validList[i]
        if Szcz.IsSkipped(player.guid) then
            skippedCount = skippedCount + 1
        else
            idx = idx + 1
            outTable[idx] = player
        end
    end

    return idx, skippedCount
end

--[[
    Get distance between player and a unit
    Uses UnitXP's 3D distance if available (more accurate on terrain with elevation)
    Falls back to SuperWoW's 2D calculation otherwise
]]
function Szcz.GetDistance(unitId)
    -- Use UnitXP's 3D distance if available (more accurate on terrain)
    if Szcz.hasUnitXP then
        local dist = UnitXP("distanceBetween", "player", unitId)
        if dist then return dist end
    end

    -- Fallback to 2D calculation via SuperWoW
    local px, py = UnitPosition("player")
    local ux, uy = UnitPosition(unitId)
    if px and ux then
        local dx = px - ux
        local dy = py - uy
        return math_sqrt(dx * dx + dy * dy)
    end
    return nil
end

--[[
    Select best target from a list
    mode: "salts" or "spell"

    Priority order:
    1. Class tier (tier 1 > tier 2 > tier 3) - handled by tier grouping
    2. In range (within RANGE_CAP beats beyond RANGE_CAP)
    3. Distance (salts=closest, spell=configurable)

    LoS is NOT used for sorting (unreliable with terrain height)
    LoS is calculated for visual indicator only (requires UnitXP)
]]
local function SelectFromList(players, playerCount, mode)
    local Data = Szcz.Data
    local CLASS_TIER = Data.CLASS_TIER or {}
    local TARGETING = Data.TARGETING or {}
    local RANGE_CAP = TARGETING.RANGE_CAP or 100

    -- Determine distance preference
    local preferClosest
    if mode == "salts" then
        preferClosest = true
    else
        local distMode = TARGETING.SPELL_DISTANCE_MODE or "furthest"
        preferClosest = (distMode == "closest")
    end

    -- Wipe and group by tier (reset pre-allocated tierCounts, no table creation)
    WipeTiers()
    tierCounts[1], tierCounts[2], tierCounts[3] = 0, 0, 0

    for i = 1, playerCount do
        local player = players[i]
        local tier = CLASS_TIER[player.classFile] or 3
        tierCounts[tier] = tierCounts[tier] + 1
        tiersPool[tier][tierCounts[tier]] = player
    end

    -- Find highest priority non-empty tier
    local selectedTier, selectedCount = nil, 0
    for i = 1, 3 do
        if tierCounts[i] > 0 then
            selectedTier = tiersPool[i]
            selectedCount = tierCounts[i]
            break
        end
    end
    if not selectedTier then return nil end

    -- Pre-calculate derived fields for sorting
    for i = 1, selectedCount do
        local p = selectedTier[i]
        p.inRange = (p.distance and p.distance <= RANGE_CAP) or false
        -- Calculate LoS for visual indicator only (requires UnitXP)
        -- Note: can't use "hasUnitXP and IsInLoS() or true" because false or true = true
        if Szcz.hasUnitXP then
            p.inLoS = Szcz.IsInLoS(p.unitId)
        else
            p.inLoS = true
        end
    end

    -- Single combined sort: inRange > distance (uses pre-created comparators, no closure alloc)
    table_sort(selectedTier, preferClosest and SortClosest or SortFurthest)

    return selectedTier[1]
end

--[[
    Full targeting pipeline - returns best targets for salts and spell
    Uses pooled tables to avoid GC
]]
function Szcz.GetTargetingResults()
    -- Step 1: Get all dead players into deadPool
    local deadCount = GetDeadPlayers(deadPool)
    if deadCount == 0 then
        return nil, nil, "No dead players"
    end

    -- Step 2: Filter invalid targets (ghosts, FD, recently ressed)
    local validCount = FilterValidTargets(deadPool, deadCount, validPool)
    if validCount == 0 then
        ReturnAllPlayersToPool(deadPool)
        return nil, nil, "All released/FD/ressed"
    end

    -- Step 3: Filter out pending resurrections -> filteredPool
    local filteredCount = FilterPendingRes(validPool, validCount, filteredPool)

    -- Step 4: Filter out skipped targets -> validPool (reused as output buffer)
    local finalCount, skippedCount = FilterSkippedTargets(filteredPool, filteredCount, validPool)

    -- Step 5: Smart reset - if all targets were skipped, reset and use unfiltered list
    if finalCount == 0 and skippedCount > 0 then
        Szcz.ResetSkippedTargets()
        finalCount = filteredCount
        for i = 1, filteredCount do
            validPool[i] = filteredPool[i]
        end
    end

    -- Step 6: Calculate distances for all valid targets
    for i = 1, finalCount do
        validPool[i].distance = Szcz.GetDistance(validPool[i].unitId)
    end

    -- Step 7: Select for salts (closest)
    local saltsTarget = nil
    if finalCount > 0 then
        saltsTarget = SelectFromList(validPool, finalCount, "salts")
    end

    -- Step 8: Select for spell (configurable)
    local spellTarget = nil
    if finalCount > 0 then
        spellTarget = SelectFromList(validPool, finalCount, "spell")
    end

    -- Note: We don't return players to pool here because the caller may need them
    -- They get recycled on next GetTargetingResults call

    return saltsTarget, spellTarget, nil
end

--[[
    SelectTarget for slash commands
]]
function Szcz.SelectTarget(useSalts)
    local saltsTarget, spellTarget, err = Szcz.GetTargetingResults()

    if err then
        return nil, err
    end

    local target = useSalts and saltsTarget or spellTarget
    if not target then
        return nil, "No valid target"
    end

    return target.unitId, target.name
end
