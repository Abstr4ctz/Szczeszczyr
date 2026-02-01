--[[
    Szczeszczyr - Smart Resurrection Addon
    Data/Spells.lua - All spell/item IDs, class mappings
]]

local Szcz = Szczeszczyr
Szcz.Data = {}

--[[
    Resurrection spell IDs -> "res" or "salts"
    Single O(1) lookup table for UNIT_CASTEVENT filtering
]]
Szcz.Data.RES_SPELL_IDS = {
    -- Priest: Resurrection
    [2006]  = "res",   -- Rank 1
    [2010]  = "res",   -- Rank 2
    [10880] = "res",   -- Rank 3
    [10881] = "res",   -- Rank 4
    [20770] = "res",   -- Rank 5

    -- Shaman: Ancestral Spirit
    [2008]  = "res",   -- Rank 1
    [20609] = "res",   -- Rank 2
    [20610] = "res",   -- Rank 3
    [20776] = "res",   -- Rank 4
    [20777] = "res",   -- Rank 5

    -- Paladin: Redemption
    [7328]  = "res",   -- Rank 1
    [10322] = "res",   -- Rank 2
    [10324] = "res",   -- Rank 3
    [20772] = "res",   -- Rank 4
    [20773] = "res",   -- Rank 5

    -- Druid: Rebirth (combat res)
    [20484] = "res",   -- Rank 1
    [20739] = "res",   -- Rank 2
    [20742] = "res",   -- Rank 3
    [20747] = "res",   -- Rank 4
    [20748] = "res",   -- Rank 5

    -- Smelling Salts
    [10850] = "salts",

}

--[[
    Classes that can resurrect (out of combat)
]]
Szcz.Data.RES_CLASSES = {
    PRIEST = true,
    PALADIN = true,
    SHAMAN = true,
}

--[[
    Resurrection spell names by class (for CastSpellByName)
]]
Szcz.Data.CLASS_RES_SPELL_NAME = {
    PRIEST  = "Resurrection",
    SHAMAN  = "Ancestral Spirit",
    PALADIN = "Redemption",
}

--[[
    Class res icons
]]
Szcz.Data.CLASS_RES_ICONS = {
    PRIEST  = "Interface\\Icons\\Spell_Holy_Resurrection",
    SHAMAN  = "Interface\\Icons\\Spell_Nature_Regenerate",
    PALADIN = "Interface\\Icons\\Spell_Holy_Resurrection",
}

--[[
    Smelling Salts config
]]
Szcz.Data.SALTS_ITEM_ID = 8546
Szcz.Data.SALTS_SPELL_ID = 10850
Szcz.Data.SALTS_RANGE = 5
Szcz.Data.SALTS_COOLDOWN = 5 * 60 * 60  -- 5 hours
Szcz.Data.SALTS_ICON = "Interface\\Icons\\inv_misc_ammo_gunpowder_01"

--[[
    Class tier groupings (for target selection priority)
    Lower tier = higher priority (healers first, then casters, then melee)
    Performance: Flat table for O(1) lookups in hot path
]]
Szcz.Data.CLASS_TIER = {
    PRIEST  = 1,
    SHAMAN  = 1,
    PALADIN = 1,
    DRUID   = 2,
    MAGE    = 2,
    WARLOCK = 2,
    HUNTER  = 2,
    WARRIOR = 3,
    ROGUE   = 3,
}

--[[
    Feign Death texture for hunter detection
]]
Szcz.Data.FEIGN_DEATH_TEXTURE = "Interface\\Icons\\Ability_Rogue_FeignDeath"

--[[
    Resurrection range (standard res spells)
]]
Szcz.Data.RES_RANGE = 30

--[[
    Recently ressed timeout (seconds)
]]
Szcz.Data.RECENTLY_TIMEOUT = 30

--[[
    Pre-generated unit ID strings (shared across modules)
]]
Szcz.Data.RAID_UNITS = {}
Szcz.Data.PARTY_UNITS = {}
for i = 1, 40 do Szcz.Data.RAID_UNITS[i] = "raid" .. i end
for i = 1, 4 do Szcz.Data.PARTY_UNITS[i] = "party" .. i end

--[[
    Targeting Configuration
]]
Szcz.Data.TARGETING = {
    -- Range cap: targets beyond this are deprioritized (not filtered)
    -- They still show if nothing closer, but never beat closer targets
    RANGE_CAP = 100,

    -- Spell distance mode: "furthest" (spread out) or "closest"
    SPELL_DISTANCE_MODE = "furthest",

    -- Skip system timeout (seconds) - reset skipped after this time
    SKIP_TIMEOUT = 20,
}
