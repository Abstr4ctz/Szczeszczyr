--[[
    Szczeszczyr - Smart Resurrection Addon
    Core.lua - Initialization, event routing, slash commands
]]

-- Main addon table
Szczeszczyr = {}
local Szcz = Szczeszczyr

-- Localize
local time = time

-- Mod detection flags
Szcz.hasSuperWow = false
Szcz.hasUnitXP = false

-- Player info cache
Szcz.playerClass = nil
Szcz.playerGUID = nil

-- Main event frame
local eventFrame = CreateFrame("Frame", "SzczeszczyrEventFrame")

--[[
    Mod Detection
]]
local function DetectMods()
    Szcz.hasSuperWow = (SUPERWOW_VERSION ~= nil)

    local success = pcall(UnitXP, "nop", "nop")
    Szcz.hasUnitXP = success
end

--[[
    Cache player info
]]
local function CachePlayerInfo()
    local _, classFile = UnitClass("player")
    Szcz.playerClass = classFile

    if Szcz.hasSuperWow then
        local _, guid = UnitExists("player")
        Szcz.playerGUID = guid
    end
end

--[[
    Event Handler
]]
local function OnEvent()
    if event == "ADDON_LOADED" and arg1 == "Szczeszczyr" then
        DetectMods()

        if not Szcz.hasSuperWow then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Szczeszczyr|r requires |cff00ffffSuperWoW|r to function!")
            return
        end

        Szcz.InitSettings()

        -- Register remaining events
        eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
        eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
        eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
        eventFrame:RegisterEvent("BAG_UPDATE")
        eventFrame:RegisterEvent("CHARACTER_POINTS_CHANGED")

        local modStatus = "SuperWoW"
        if Szcz.hasUnitXP then
            modStatus = modStatus .. " + UnitXP"
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff9acd32Szczeszczyr|r loaded. " .. modStatus)

    elseif event == "PLAYER_LOGIN" then
        CachePlayerInfo()

        -- Cache res spell slot for cooldown/range checking
        Szcz.CacheResSpellSlot()

        -- Restore button position
        Szcz.RestoreButtonPosition()

        -- Restore feedback frame position
        Szcz.RestoreFeedbackPosition()

        -- Check initial group state (this will show buttons if in group)
        Szcz.UpdateGroupState()

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Check BG state on zone changes
        Szcz.CheckBattleground()

        -- Mark dead cache stale on zone-in (ensures fresh data when entering instances)
        Szcz.InvalidateDeadCache()

        -- Refresh salts state (loads from DB, syncs on zone/login)
        Szcz.RefreshSaltsState()

        -- Refresh group state
        Szcz.UpdateGroupState()

    elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
        Szcz.InvalidateDeadCache()
        Szcz.UpdateGroupState()

    elseif event == "PLAYER_REGEN_DISABLED" then
        Szcz.UpdateCombatState(true)

    elseif event == "PLAYER_REGEN_ENABLED" then
        Szcz.ResetSkippedTargets()
        Szcz.UpdateCombatState(false)

    elseif event == "BAG_UPDATE" then
        -- Refresh salts state out of combat (throttled internally)
        if not Szcz.state.inCombat then
            Szcz.RefreshSaltsState()
        end

    elseif event == "CHARACTER_POINTS_CHANGED" then
        -- Talent respec moves spell slots - re-cache for cooldown display
        Szcz.CacheResSpellSlot()
    end
end

eventFrame:SetScript("OnEvent", OnEvent)
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")

--[[
    Keybinding labels (for Key Bindings UI)
]]
BINDING_HEADER_SZCZESZCZYR = "Szczeszczyr"
BINDING_NAME_SZCZESZCZYR_SALTS = "Use Smelling Salts"
BINDING_NAME_SZCZESZCZYR_RES = "Resurrect (spell)"

--[[
    Keybinding functions (global for Bindings.xml)
]]
function Szczeszczyr_DoSalts()
    Szczeszczyr.DoResurrection(true)
end

function Szczeszczyr_DoRes()
    if not Szczeszczyr.CanPlayerRes() then
        return  -- Silent fail for non-healers
    end
    Szczeszczyr.DoResurrection(false)
end

--[[
    Slash Command Handler (simplified)
]]
local function SlashHandler(msg)
    msg = string.lower(msg or "")

    if msg == "" or msg == "status" then
        Szcz.PrintStatus()

    elseif msg == "res" then
        Szcz.DoResurrection(false)

    elseif msg == "salts" then
        Szcz.DoResurrection(true)

    elseif msg == "lock" then
        Szcz.LockFrames()

    elseif msg == "unlock" then
        Szcz.UnlockFrames()

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff9acd32Szczeszczyr|r commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /szcz - Show status")
        DEFAULT_CHAT_FRAME:AddMessage("  /szcz lock - Lock frame positions")
        DEFAULT_CHAT_FRAME:AddMessage("  /szcz unlock - Unlock frames for repositioning")
        DEFAULT_CHAT_FRAME:AddMessage("  /szcz res - Resurrect (spell)")
        DEFAULT_CHAT_FRAME:AddMessage("  /szcz salts - Resurrect (salts)")
    end
end

SLASH_SZCZESZCZYR1 = "/szcz"
SLASH_SZCZESZCZYR2 = "/szczeszczyr"
SlashCmdList["SZCZESZCZYR"] = SlashHandler

--[[
    Status Display
]]
function Szcz.PrintStatus()
    DEFAULT_CHAT_FRAME:AddMessage("|cff9acd32=== Szczeszczyr Status ===|r")
    DEFAULT_CHAT_FRAME:AddMessage("SuperWoW: " .. (Szcz.hasSuperWow and "|cff00ff00Yes|r" or "|cffff0000No (REQUIRED)|r"))
    DEFAULT_CHAT_FRAME:AddMessage("UnitXP: " .. (Szcz.hasUnitXP and "|cff00ff00Yes|r" or "|cffaaaaaa(optional)|r"))
    DEFAULT_CHAT_FRAME:AddMessage("Player Class: " .. (Szcz.playerClass or "Unknown"))
    DEFAULT_CHAT_FRAME:AddMessage("Can Res: " .. (Szcz.CanPlayerRes and Szcz.CanPlayerRes() and "|cff00ff00Yes|r" or "|cffaaaaaa(salts only)|r"))

    if Szcz.state then
        DEFAULT_CHAT_FRAME:AddMessage("In Group: " .. (Szcz.state.inGroup and "|cff00ff00Yes|r" or "|cffff0000No|r"))
        DEFAULT_CHAT_FRAME:AddMessage("In Combat: " .. (Szcz.state.inCombat and "|cffff0000Yes|r" or "|cff00ff00No|r"))
        DEFAULT_CHAT_FRAME:AddMessage("In BG: " .. (Szcz.state.inBattleground and "|cffff0000Yes|r" or "|cff00ff00No|r"))
        DEFAULT_CHAT_FRAME:AddMessage("Can Use Salts: " .. (Szcz.CanUseSalts() and "|cff00ff00Yes|r" or "|cffff0000No|r"))
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Szcz.state is NIL!|r")
    end

    if Szcz.saltsState then
        DEFAULT_CHAT_FRAME:AddMessage("Salts In Bags: " .. (Szcz.saltsState.hasSalts and "|cff00ff00Yes|r" or "|cffff0000No|r"))
        local onCD = Szcz.saltsState.cdEndUnix and time() < Szcz.saltsState.cdEndUnix
        DEFAULT_CHAT_FRAME:AddMessage("Salts CD: " .. (onCD and "|cffff0000Yes|r" or "|cff00ff00No|r"))
    end

    local pendingCount = 0
    if Szcz.pendingRes then
        for _ in pairs(Szcz.pendingRes) do
            pendingCount = pendingCount + 1
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage("Pending Res: " .. pendingCount)

    -- Button state
    if Szcz.AreButtonsVisible then
        DEFAULT_CHAT_FRAME:AddMessage("Buttons Visible: " .. (Szcz.AreButtonsVisible() and "|cff00ff00Yes|r" or "|cffff0000No|r"))
    end
    if Szcz.IsButtonPolling then
        DEFAULT_CHAT_FRAME:AddMessage("Button Polling: " .. (Szcz.IsButtonPolling() and "|cff00ff00Yes|r" or "|cffff0000No|r"))
    end
end
