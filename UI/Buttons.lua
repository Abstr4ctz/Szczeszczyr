--[[
    Szczeszczyr - Smart Resurrection Addon
    UI/Buttons.lua - Two-button resurrection UI
]]

local Szcz = Szczeszczyr

-- Localize globals
local GetTime = GetTime
local GetNumRaidMembers = GetNumRaidMembers
local GetNumPartyMembers = GetNumPartyMembers
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitExists = UnitExists
local GetSpellCooldown = GetSpellCooldown
local floor = math.floor

-- Constants
local BUTTON_SIZE = 40
local TEXT_HEIGHT = 12
local BUTTON_GAP = 2  -- Small gap between buttons
local POLL_INTERVAL = 0.5
local CLEANUP_INTERVAL = 5
local ICON_CROP = 0.07  -- Crop 7% from each edge to remove ugly borders
local MAX_NAME_LEN = 7  -- Truncate names longer than this

-- State
local polling = false
local elapsed = 0
local cleanupElapsed = 0
local currentSaltsTarget = nil
local currentSpellTarget = nil
local currentSaltsTargetGuid = nil  -- Cached GUID (immutable, survives pool recycling)
local currentSpellTargetGuid = nil

-- Forward declaration for SetFrameVisible (buttonFrame defined below)
local SetFrameVisible

-- Use shared unit ID strings from Data.lua
local RAID_UNITS = Szcz.Data.RAID_UNITS
local PARTY_UNITS = Szcz.Data.PARTY_UNITS

--[[
    Create the button container frame
]]
local buttonFrame = CreateFrame("Frame", "SzczeszczyrButtonFrame", UIParent)
buttonFrame:SetWidth(BUTTON_SIZE + 30)  -- Room for distance text
buttonFrame:SetHeight((BUTTON_SIZE + TEXT_HEIGHT) * 2 + BUTTON_GAP)  -- Vertical stack
buttonFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
buttonFrame:SetMovable(true)

--[[
    Centralized visibility control
    buttonFrame itself is NOT mouse-enabled - only child buttons catch clicks
]]
SetFrameVisible = function(visible)
    if visible then
        buttonFrame:Show()
    else
        buttonFrame:Hide()
    end
end
-- buttonFrame doesn't handle mouse - buttons do. Drag handled by overlay in unlock mode.
buttonFrame:EnableMouse(false)
SetFrameVisible(false)

--[[
    Feedback frame - displays icon at screen center when clicking disabled button
    Fades from 100% to 0% opacity over 3 seconds
]]
local FEEDBACK_DURATION = 3
local feedbackElapsed = 0

local feedbackFrame = CreateFrame("Frame", "SzczFeedback", UIParent)
feedbackFrame:SetWidth(128)
feedbackFrame:SetHeight(128)
feedbackFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
feedbackFrame:SetFrameStrata("DIALOG")
feedbackFrame:SetMovable(true)
-- Click-through by default - only enabled during unlock mode
feedbackFrame:EnableMouse(false)
feedbackFrame:Hide()

local feedbackIcon = feedbackFrame:CreateTexture(nil, "ARTWORK")
feedbackIcon:SetAllPoints()
feedbackIcon:SetTexture("Interface\\AddOns\\Szczeszczyr\\icon")
feedbackIcon:SetBlendMode("ADD")

--[[
    Feedback OnUpdate - attached only while fading, detaches itself when done
]]
local function FeedbackOnUpdate()
    feedbackElapsed = feedbackElapsed + arg1
    if feedbackElapsed >= FEEDBACK_DURATION then
        feedbackFrame:SetScript("OnUpdate", nil)
        feedbackFrame:Hide()
        feedbackIcon:SetAlpha(1)
    else
        feedbackIcon:SetAlpha(1 - (feedbackElapsed / FEEDBACK_DURATION))
    end
end

local function ShowFeedback()
    feedbackElapsed = 0
    feedbackIcon:SetAlpha(1)
    feedbackFrame:EnableMouse(false)
    feedbackFrame:SetScript("OnUpdate", FeedbackOnUpdate)
    feedbackFrame:Show()
end

--[[
    Helper: Create a resurrection button (vertical layout - text above button)
]]
local function CreateResButton(name, parent)
    local btn = CreateFrame("Button", name, parent)
    btn:SetWidth(BUTTON_SIZE)
    btn:SetHeight(BUTTON_SIZE)

    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
    btn.bg:SetAllPoints()
    btn.bg:SetTexture(0, 0, 0, 0.5)

    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
    btn.icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

    -- Text above button
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.text:SetPoint("BOTTOM", btn, "TOP", 0, 1)
    btn.text:SetWidth(BUTTON_SIZE + 30)
    btn.text:SetJustifyH("CENTER")

    btn.disabled = btn:CreateTexture(nil, "OVERLAY")
    btn.disabled:SetAllPoints()
    btn.disabled:SetTexture(0, 0, 0, 0.6)
    btn.disabled:Hide()

    btn.isEnabled = false
    return btn
end

--[[
    Optimized SetButtonEnabled (no-op if unchanged)
]]
local function SetButtonEnabled(btn, enabled)
    if btn.isEnabled == enabled then return end
    btn.isEnabled = enabled
    if enabled then
        btn.disabled:Hide()
    else
        btn.disabled:Show()
    end
end

--[[
    Truncate name if too long
]]
local function TruncateName(name, maxLen)
    if not name then return "?" end
    if string.len(name) > maxLen then
        return string.sub(name, 1, maxLen - 1) .. "."
    end
    return name
end

--[[
    Create buttons (vertical layout - salts on top, res below)
]]
local saltsButton = CreateResButton("SzczeszczyrSaltsButton", buttonFrame)
saltsButton:SetPoint("TOP", buttonFrame, "TOP", 0, -TEXT_HEIGHT)
saltsButton.icon:SetTexture("Interface\\Icons\\inv_misc_ammo_gunpowder_01")
saltsButton.icon:SetTexCoord(ICON_CROP, 1 - ICON_CROP, ICON_CROP, 1 - ICON_CROP)

-- Add out-of-range overlay to salts button
saltsButton.oor = saltsButton:CreateTexture(nil, "OVERLAY")
saltsButton.oor:SetAllPoints()
saltsButton.oor:SetTexture(1, 0.1, 0.1, 0.4)  -- Red tint (same as res button)
saltsButton.oor:Hide()

saltsButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
saltsButton:SetScript("OnClick", function()
    if arg1 == "RightButton" then
        -- Skip current target, cycle to next (use cached GUID, not object field)
        if currentSaltsTargetGuid then
            Szcz.SkipTarget(currentSaltsTargetGuid)
            Szcz.ForceButtonUpdate()
        end
    elseif this.isEnabled then
        Szcz.DoResurrection(true)
    else
        ShowFeedback()
    end
end)

local resButton = CreateResButton("SzczeszczyrResButton", buttonFrame)
resButton:SetPoint("TOP", saltsButton, "BOTTOM", 0, -BUTTON_GAP - TEXT_HEIGHT)

-- Add cooldown frame to res button (Model type for vanilla compatibility)
resButton.cooldown = CreateFrame("Model", "SzczeszczyrResButtonCD", resButton, "CooldownFrameTemplate")
resButton.cooldown:SetAllPoints(resButton.icon)

-- Add out-of-range overlay to res button
resButton.oor = resButton:CreateTexture(nil, "OVERLAY")
resButton.oor:SetAllPoints()
resButton.oor:SetTexture(1, 0.1, 0.1, 0.4)  -- Red tint
resButton.oor:Hide()

resButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
resButton:SetScript("OnClick", function()
    if arg1 == "RightButton" then
        -- Skip current target, cycle to next (use cached GUID, not object field)
        if currentSpellTargetGuid then
            Szcz.SkipTarget(currentSpellTargetGuid)
            Szcz.ForceButtonUpdate()
        end
    elseif this.isEnabled then
        Szcz.DoResurrection(false)
    else
        ShowFeedback()
    end
end)

--[[
    Format distance
]]
local function FormatDistance(dist)
    if not dist then return "?" end
    return floor(dist + 0.5) .. "yd"
end

--[[
    Clean up recentlyRessed players who accepted
]]
local function CleanupAcceptedRes()
    if not Szcz.recentlyRessed then return end

    local numRaid = GetNumRaidMembers()
    local numParty = GetNumPartyMembers()

    if numRaid > 0 then
        for i = 1, numRaid do
            local unitId = RAID_UNITS[i]
            local _, guid = UnitExists(unitId)
            if guid and Szcz.recentlyRessed[guid] and not UnitIsDeadOrGhost(unitId) then
                Szcz.recentlyRessed[guid] = nil
            end
        end
    elseif numParty > 0 then
        for i = 1, numParty do
            local unitId = PARTY_UNITS[i]
            local _, guid = UnitExists(unitId)
            if guid and Szcz.recentlyRessed[guid] and not UnitIsDeadOrGhost(unitId) then
                Szcz.recentlyRessed[guid] = nil
            end
        end
    end
end

--[[
    Update button states
]]
local function UpdateButtonState()
    local state = Szcz.state

    -- Safety check
    if not state then
        SetFrameVisible(false)
        return
    end

    -- Don't update during unlock mode (user is positioning)
    if state.unlocked then
        return
    end

    -- Hide in BG
    if state.inBattleground then
        SetFrameVisible(false)
        return
    end

    -- Hide in combat
    if state.inCombat then
        SetFrameVisible(false)
        return
    end

    -- Hide if not in group
    if not state.inGroup then
        SetFrameVisible(false)
        return
    end

    -- Show frame
    SetFrameVisible(true)

    -- Clean up accepted resurrections
    CleanupAcceptedRes()

    -- Run targeting pipeline
    local saltsTarget, spellTarget, err = Szcz.GetTargetingResults()
    currentSaltsTarget = saltsTarget  -- Cache for right-click
    currentSpellTarget = spellTarget
    -- Cache GUIDs separately (immutable strings survive pool recycling)
    currentSaltsTargetGuid = saltsTarget and saltsTarget.guid
    currentSpellTargetGuid = spellTarget and spellTarget.guid

    -- Update salts button
    local canUseSalts = Szcz.CanUseSalts()

    if canUseSalts and saltsTarget then
        local losIndicator = (saltsTarget.inLoS == false) and " !" or ""
        saltsButton.text:SetText(TruncateName(saltsTarget.name, MAX_NAME_LEN) .. losIndicator .. " " .. FormatDistance(saltsTarget.distance))
        SetButtonEnabled(saltsButton, true)
        saltsButton:EnableMouse(true)
        saltsButton:Show()

        -- Update salts out-of-range indicator
        local Data = Szcz.Data
        local SALTS_RANGE = Data and Data.SALTS_RANGE or 5
        local inSaltsRange = saltsTarget.distance and saltsTarget.distance <= SALTS_RANGE
        if inSaltsRange then
            saltsButton.oor:Hide()
        else
            saltsButton.oor:Show()
        end
    elseif canUseSalts then
        if err == "No dead players" then
            saltsButton.text:SetText("All Alive")
        else
            saltsButton.text:SetText("All Ressed")
        end
        SetButtonEnabled(saltsButton, false)
        saltsButton:EnableMouse(true)
        saltsButton:Show()
        saltsButton.oor:Hide()
    else
        -- No salts or on cooldown - hide the button entirely (no mouse)
        saltsButton:EnableMouse(false)
        saltsButton:Hide()
        saltsButton.oor:Hide()
    end

    -- Update res button (healers only)
    if Szcz.CanPlayerRes() then
        local Data = Szcz.Data
        local icon = Data and Data.CLASS_RES_ICONS and Data.CLASS_RES_ICONS[Szcz.playerClass]
        if icon then
            resButton.icon:SetTexture(icon)
            resButton.icon:SetTexCoord(ICON_CROP, 1 - ICON_CROP, ICON_CROP, 1 - ICON_CROP)
        end

        if spellTarget then
            local losIndicator = (spellTarget.inLoS == false) and " !" or ""
            resButton.text:SetText(TruncateName(spellTarget.name, MAX_NAME_LEN) .. losIndicator .. " " .. FormatDistance(spellTarget.distance))
            SetButtonEnabled(resButton, true)
        else
            if err == "No dead players" then
                resButton.text:SetText("All Alive")
            else
                resButton.text:SetText("All Ressed")
            end
            SetButtonEnabled(resButton, false)
        end

        -- Update cooldown spiral
        local resSpellSlot = Szcz.GetResSpellSlot()
        if resSpellSlot then
            local start, duration = GetSpellCooldown(resSpellSlot, BOOKTYPE_SPELL)
            if start and start > 0 and duration and duration > 0 then
                CooldownFrame_SetTimer(resButton.cooldown, start, duration, 1)
            end
        end

        -- Update out-of-range indicator
        if spellTarget then
            local RES_RANGE = Data and Data.RES_RANGE or 30
            local inRange = spellTarget.distance and spellTarget.distance <= RES_RANGE
            if inRange then
                resButton.oor:Hide()
            else
                resButton.oor:Show()
            end
        else
            resButton.oor:Hide()
        end

        resButton:EnableMouse(true)
        resButton:Show()
    else
        -- Not a healer - hide the button (no mouse)
        resButton:EnableMouse(false)
        resButton:Hide()
    end

    -- Update minimap corpse tracking (synced with button targets)
    local showSalts = canUseSalts and saltsTarget ~= nil
    local showRes = Szcz.CanPlayerRes() and spellTarget ~= nil
    Szcz.UpdateCorpseTracking(saltsTarget, spellTarget, showSalts, showRes)
end

--[[
    OnUpdate handler for polling
]]
local function OnUpdateTick()
    elapsed = elapsed + arg1
    if elapsed < POLL_INTERVAL then return end
    elapsed = 0

    -- Check if salts cooldown has ended (efficient timestamp comparison, no API call)
    if Szcz.saltsState and Szcz.saltsState.onCooldown and Szcz.saltsState.cdEndTime then
        if GetTime() >= Szcz.saltsState.cdEndTime then
            Szcz.ScanForSalts()  -- ONE API call to verify and update state
        end
    end

    -- Periodic cleanup (every 5s)
    cleanupElapsed = cleanupElapsed + POLL_INTERVAL
    if cleanupElapsed >= CLEANUP_INTERVAL then
        cleanupElapsed = 0
        Szcz.CleanStalePending()
    end

    UpdateButtonState()
end

--[[
    Show buttons and start polling
    Called when: entering group (OOC), leaving combat (in group)
]]
function Szcz.ShowButtons()
    local state = Szcz.state

    if not state then
        return
    end

    if not state.inGroup then
        return
    end

    if state.inBattleground then
        return
    end

    if state.inCombat then
        return
    end

    if not polling then
        buttonFrame:SetScript("OnUpdate", OnUpdateTick)
        polling = true
        elapsed = 0
        cleanupElapsed = 0
    end

    SetFrameVisible(true)
    UpdateButtonState()
end

--[[
    Hide buttons and stop polling
    Called when: leaving group, entering combat, entering BG
]]
function Szcz.HideButtons()
    SetFrameVisible(false)
    if polling then
        buttonFrame:SetScript("OnUpdate", nil)
        polling = false
    end
end

--[[
    Force immediate update (called from Tracking.lua on CAST/FAIL)
]]
function Szcz.ForceButtonUpdate()
    if polling then
        UpdateButtonState()
    end
end

--[[
    Get cached salts target (for right-click skip)
]]
function Szcz.GetCurrentSaltsTarget()
    return currentSaltsTarget
end

--[[
    Get cached spell target (for right-click skip)
]]
function Szcz.GetCurrentSpellTarget()
    return currentSpellTarget
end

--[[
    Restore button position
]]
function Szcz.RestoreButtonPosition()
    local point = Szcz.GetSetting("buttonPoint")
    local relPoint = Szcz.GetSetting("buttonRelPoint")
    local x = Szcz.GetSetting("buttonX")
    local y = Szcz.GetSetting("buttonY")

    if point and relPoint and x and y then
        buttonFrame:ClearAllPoints()
        buttonFrame:SetPoint(point, UIParent, relPoint, x, y)
    end
end

--[[
    Restore feedback frame position
]]
function Szcz.RestoreFeedbackPosition()
    local point = Szcz.GetSetting("feedbackPoint")
    local relPoint = Szcz.GetSetting("feedbackRelPoint")
    local x = Szcz.GetSetting("feedbackX")
    local y = Szcz.GetSetting("feedbackY")

    if point and relPoint and x and y then
        feedbackFrame:ClearAllPoints()
        feedbackFrame:SetPoint(point, UIParent, relPoint, x, y)
    end
end

--[[
    Create unlock overlay for a frame - handles dragging to move parent
]]
local function CreateUnlockOverlay(parent, labelText)
    local overlay = CreateFrame("Frame", nil, parent)
    overlay:SetAllPoints()
    overlay:SetFrameLevel(parent:GetFrameLevel() + 100)  -- Well above any children
    overlay:EnableMouse(true)  -- Catch clicks when shown
    overlay:RegisterForDrag("LeftButton")

    -- Drag moves the parent frame
    overlay:SetScript("OnDragStart", function()
        parent:StartMoving()
    end)
    overlay:SetScript("OnDragStop", function()
        parent:StopMovingOrSizing()
    end)

    local bg = overlay:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(0, 0.5, 0, 0.4)  -- Green tint

    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", overlay, "CENTER", 0, 0)
    label:SetText(labelText)
    label:SetTextColor(1, 1, 1)

    overlay:Hide()
    return overlay
end

-- Create overlays for both frames
local buttonOverlay = CreateUnlockOverlay(buttonFrame, "DRAG TO MOVE")
buttonOverlay:SetScript("OnDragStop", function()
    buttonFrame:StopMovingOrSizing()
    local point, _, relPoint, x, y = buttonFrame:GetPoint()
    Szcz.SetSetting("buttonPoint", point)
    Szcz.SetSetting("buttonRelPoint", relPoint)
    Szcz.SetSetting("buttonX", x)
    Szcz.SetSetting("buttonY", y)
end)

local feedbackOverlay = CreateUnlockOverlay(feedbackFrame, "DRAG TO MOVE")
feedbackOverlay:SetScript("OnDragStop", function()
    feedbackFrame:StopMovingOrSizing()
    local point, _, relPoint, x, y = feedbackFrame:GetPoint()
    Szcz.SetSetting("feedbackPoint", point)
    Szcz.SetSetting("feedbackRelPoint", relPoint)
    Szcz.SetSetting("feedbackX", x)
    Szcz.SetSetting("feedbackY", y)
end)

--[[
    Unlock frames for positioning
]]
function Szcz.UnlockFrames()
    Szcz.state.unlocked = true
    Szcz.SetSetting("locked", false)

    -- Force show button frame with overlay
    buttonFrame:ClearAllPoints()
    local point = Szcz.GetSetting("buttonPoint")
    local relPoint = Szcz.GetSetting("buttonRelPoint")
    local x = Szcz.GetSetting("buttonX")
    local y = Szcz.GetSetting("buttonY")
    if point and relPoint and x and y then
        buttonFrame:SetPoint(point, UIParent, relPoint, x, y)
    else
        buttonFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
    end
    SetFrameVisible(true)
    buttonOverlay:Show()

    -- Show salts button (disabled, no mouse - overlay catches clicks)
    saltsButton:Show()
    saltsButton:EnableMouse(false)
    saltsButton.text:SetText("Salts")
    SetButtonEnabled(saltsButton, false)
    saltsButton.oor:Hide()

    -- Show res button only if healer (disabled, no mouse)
    if Szcz.CanPlayerRes() then
        resButton:Show()
        resButton:EnableMouse(false)
        resButton.text:SetText("Resurrect")
        SetButtonEnabled(resButton, false)
        resButton.oor:Hide()
    else
        resButton:Hide()
    end

    -- Force show feedback frame with overlay (static display, mouse enabled for drag)
    feedbackFrame:SetScript("OnUpdate", nil)
    feedbackIcon:SetAlpha(1)
    feedbackFrame:EnableMouse(true)
    feedbackFrame:Show()
    feedbackOverlay:Show()

    DEFAULT_CHAT_FRAME:AddMessage("|cff9acd32Szczeszczyr|r: Frames unlocked. Drag to reposition, then /szcz lock")
end

--[[
    Lock frames (return to normal behavior)
]]
function Szcz.LockFrames()
    Szcz.state.unlocked = false
    Szcz.SetSetting("locked", true)

    -- Hide overlays
    buttonOverlay:Hide()
    feedbackOverlay:Hide()

    -- Re-enable button mouse for normal operation
    saltsButton:EnableMouse(true)
    resButton:EnableMouse(true)

    -- Hide feedback frame and reset (click-through, no OnUpdate)
    feedbackFrame:SetScript("OnUpdate", nil)
    feedbackIcon:SetAlpha(1)
    feedbackFrame:EnableMouse(false)
    feedbackFrame:Hide()

    -- Return button frame to normal visibility rules
    if Szcz.state.inGroup and not Szcz.state.inCombat and not Szcz.state.inBattleground then
        UpdateButtonState()
    else
        SetFrameVisible(false)
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cff9acd32Szczeszczyr|r: Frames locked")
end

function Szcz.AreButtonsVisible()
    return buttonFrame:IsVisible()
end

function Szcz.IsButtonPolling()
    return polling
end
