--[[
    Szczeszczyr - Smart Resurrection Addon
    UI/CorpseTracker.lua - Minimap corpse tracking synced with Buttons targeting
]]

local Szcz = Szczeszczyr

-- Localize globals
local UnitPosition = UnitPosition
local sqrt = math.sqrt

-- Constants
local MINIMAP_RADIUS = 56
local UPDATE_INTERVAL = 0.2
local DOT_SIZE = 6

-- Colors
local SALTS_COLOR = {0.9, 0.7, 0.2}    -- Amber/gold
local SALTS_OOR_COLOR = {1, 0.3, 0.3}  -- Red
local RES_COLOR = {0.3, 0.8, 1.0}      -- Cyan/teal
local RES_OOR_COLOR = {1, 0.3, 0.3}    -- Red

-- Zoom ranges: 0 = most zoomed OUT (largest range), 5 = most zoomed IN (smallest range)
local ZOOM_RANGES = {
    [0] = 121,  -- Most zoomed out
    [1] = 94,
    [2] = 75,
    [3] = 49,
    [4] = 32,
    [5] = 20,   -- Most zoomed in
}

-- State
local trackedSaltsUnit = nil
local trackedResUnit = nil
local showSaltsDot = false
local showResDot = false
local elapsed = 0

-- Create salts marker frame (parented to Minimap)
local saltsFrame = CreateFrame("Frame", "SzczSaltsTracker", Minimap)
saltsFrame:SetWidth(DOT_SIZE)
saltsFrame:SetHeight(DOT_SIZE)
saltsFrame:SetFrameStrata("FULLSCREEN_DIALOG")
saltsFrame:Hide()

local saltsDot = saltsFrame:CreateTexture(nil, "OVERLAY")
saltsDot:SetAllPoints()

-- Create res marker frame (parented to Minimap)
local resFrame = CreateFrame("Frame", "SzczResTracker", Minimap)
resFrame:SetWidth(DOT_SIZE)
resFrame:SetHeight(DOT_SIZE)
resFrame:SetFrameStrata("FULLSCREEN_DIALOG")
resFrame:Hide()

local resDot = resFrame:CreateTexture(nil, "OVERLAY")
resDot:SetAllPoints()

-- Parent frame for OnUpdate (invisible)
local updateFrame = CreateFrame("Frame", "SzczCorpseTrackerUpdate", UIParent)
updateFrame:Hide()

--[[
    Calculate minimap position for a unit
    Returns uiX, uiY (minimap coords) and distance
]]
local function GetMinimapPosition(unitId)
    local tx, ty = UnitPosition(unitId)
    local px, py = UnitPosition("player")

    if not tx or not px then
        return nil, nil, nil
    end

    local dx = tx - px
    local dy = ty - py
    local dist = sqrt(dx*dx + dy*dy)

    -- Minimap position calculation
    local zoom = Minimap:GetZoom() or 5
    local mapRadius = ZOOM_RANGES[zoom] or 100
    local scale = MINIMAP_RADIUS / mapRadius

    -- Coordinate swap: World X+ (North) -> UI Y+ (Up)
    -- World Y+ (West) -> UI X- (Left)
    local uiX = -dy * scale
    local uiY = dx * scale
    local uiDist = sqrt(uiX*uiX + uiY*uiY)

    -- Clamp to edge if outside minimap
    if uiDist > MINIMAP_RADIUS then
        local clamp = MINIMAP_RADIUS / uiDist
        uiX = uiX * clamp
        uiY = uiY * clamp
    end

    return uiX, uiY, dist
end

--[[
    Update positions of visible markers
]]
local function UpdatePositions()
    local RES_RANGE = Szcz.Data.RES_RANGE

    -- Update salts marker
    if showSaltsDot and trackedSaltsUnit then
        local uiX, uiY, dist = GetMinimapPosition(trackedSaltsUnit)
        if uiX then
            -- Color: amber if in range, red otherwise
            if dist <= RES_RANGE then
                saltsDot:SetTexture(SALTS_COLOR[1], SALTS_COLOR[2], SALTS_COLOR[3])
            else
                saltsDot:SetTexture(SALTS_OOR_COLOR[1], SALTS_OOR_COLOR[2], SALTS_OOR_COLOR[3])
            end
            saltsFrame:ClearAllPoints()
            saltsFrame:SetPoint("CENTER", Minimap, "CENTER", uiX, uiY)
            saltsFrame:Show()
        else
            saltsFrame:Hide()
        end
    else
        saltsFrame:Hide()
    end

    -- Update res marker
    if showResDot and trackedResUnit then
        local uiX, uiY, dist = GetMinimapPosition(trackedResUnit)
        if uiX then
            -- Color: cyan if in range, red otherwise
            if dist <= RES_RANGE then
                resDot:SetTexture(RES_COLOR[1], RES_COLOR[2], RES_COLOR[3])
            else
                resDot:SetTexture(RES_OOR_COLOR[1], RES_OOR_COLOR[2], RES_OOR_COLOR[3])
            end
            resFrame:ClearAllPoints()
            resFrame:SetPoint("CENTER", Minimap, "CENTER", uiX, uiY)
            resFrame:Show()
        else
            resFrame:Hide()
        end
    else
        resFrame:Hide()
    end
end

--[[
    OnUpdate handler (0.2s throttle)
]]
local function OnUpdate()
    elapsed = elapsed + arg1
    if elapsed < UPDATE_INTERVAL then return end
    elapsed = 0
    UpdatePositions()
end

--[[
    Main API: Update corpse tracking with targets from Buttons
    Called from Buttons.lua after targeting pipeline runs
]]
function Szcz.UpdateCorpseTracking(saltsTarget, resTarget, showSalts, showRes)
    -- Extract unit IDs
    trackedSaltsUnit = saltsTarget and saltsTarget.unitId or nil
    trackedResUnit = resTarget and resTarget.unitId or nil
    showSaltsDot = showSalts and trackedSaltsUnit ~= nil
    showResDot = showRes and trackedResUnit ~= nil

    -- Handle same-target overlap: show one marker based on distance
    if showSaltsDot and showResDot and saltsTarget and resTarget then
        if saltsTarget.guid and resTarget.guid and saltsTarget.guid == resTarget.guid then
            local RES_RANGE = Szcz.Data.RES_RANGE
            if saltsTarget.distance and saltsTarget.distance <= RES_RANGE then
                -- Close enough for salts - show salts marker only
                showResDot = false
            else
                -- Too far for salts - show res marker only
                showSaltsDot = false
            end
        end
    end

    -- Set tracked GUID for Tracking.lua to detect when someone else resses our target
    -- Prefer salts target (closest/most immediate), fallback to res target
    if saltsTarget and saltsTarget.guid then
        Szcz.state.trackedGUID = saltsTarget.guid
    elseif resTarget and resTarget.guid then
        Szcz.state.trackedGUID = resTarget.guid
    else
        Szcz.state.trackedGUID = nil
    end

    -- Start or stop OnUpdate based on whether anything to track
    local shouldUpdate = showSaltsDot or showResDot
    if shouldUpdate then
        updateFrame:SetScript("OnUpdate", OnUpdate)
        elapsed = 0
        UpdatePositions()
    else
        updateFrame:SetScript("OnUpdate", nil)
        saltsFrame:Hide()
        resFrame:Hide()
    end
end

--[[
    Stop corpse tracking (called on combat enter, group leave)
]]
function Szcz.StopCorpseTracking()
    trackedSaltsUnit = nil
    trackedResUnit = nil
    showSaltsDot = false
    showResDot = false
    Szcz.state.trackedGUID = nil

    updateFrame:SetScript("OnUpdate", nil)
    saltsFrame:Hide()
    resFrame:Hide()
end

--[[
    Check if currently tracking any corpse
]]
function Szcz.IsTrackingCorpse()
    return showSaltsDot or showResDot
end
