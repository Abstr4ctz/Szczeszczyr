--[[
    Szczeszczyr - Smart Resurrection Addon
    Settings.lua - SavedVariables management
]]

local Szcz = Szczeszczyr

--[[
    Default settings (simplified)
]]
local DEFAULTS = {
    locked = true,  -- UI position locked by default
    -- Button position
    buttonPoint = nil,
    buttonRelPoint = nil,
    buttonX = nil,
    buttonY = nil,
    -- Feedback frame position
    feedbackPoint = nil,
    feedbackRelPoint = nil,
    feedbackX = nil,
    feedbackY = nil,
}

--[[
    Initialize settings from SavedVariables
]]
function Szcz.InitSettings()
    if not SzczeszczyrDB then
        SzczeszczyrDB = {}
    end

    -- Fill in missing defaults
    for key, defaultValue in pairs(DEFAULTS) do
        if SzczeszczyrDB[key] == nil then
            SzczeszczyrDB[key] = defaultValue
        end
    end

    -- Migration: Remove deprecated settings from earlier versions
    SzczeszczyrDB.forceResEnabled = nil
    SzczeszczyrDB.forceResThreshold = nil
    SzczeszczyrDB.buttonVisibility = nil
    SzczeszczyrDB.preferSalts = nil
    SzczeszczyrDB.announceToChat = nil
    SzczeszczyrDB.minimapPos = nil
    SzczeszczyrDB.debug = nil
end

--[[
    Get a setting value
    Note: SzczeszczyrDB always exists after InitSettings() is called
]]
function Szcz.GetSetting(key)
    return SzczeszczyrDB[key]
end

--[[
    Set a setting value
]]
function Szcz.SetSetting(key, value)
    if SzczeszczyrDB then
        SzczeszczyrDB[key] = value
    end
end

