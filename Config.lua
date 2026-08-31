QuestBeacon.Config = QuestBeacon.Config or {}
local Config = QuestBeacon.Config

Config.listeners = {}
Config.defaults = {
    point = "CENTER", x = 0, y = -100, scale = 1, shown = true,
    trackingMode = "auto", arrowFontSize = 12,
    trackerShown = true, trackerLocked = false, trackerFontSize = 12,
    trackerPoint = "TOPRIGHT", trackerX = -30, trackerY = -180,
    questSort = "distance", starredQuests = {},
    worldMap = { objectives=true, itemSources=true, turnIns=true, available=true },
    minimap = { objectives=true, itemSources=true, turnIns=true, available=true },
    availability = { lowLevel=false, highLevel=false, event=false },
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    local key, child
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function fill(target, defaults)
    local key, value
    for key, value in pairs(defaults) do
        if target[key] == nil then
            target[key] = copy(value)
        elseif type(value) == "table" and type(target[key]) == "table" then
            fill(target[key], value)
        end
    end
end

local function split(path)
    local startPosition, endPosition, first, second = string.find(path or "", "^([^.]+)%.?([^.]*)$")
    return first, second ~= "" and second or nil
end

function Config:Initialize()
    if type(QuestBeaconSettings) ~= "table" then QuestBeaconSettings = {} end
    fill(QuestBeaconSettings, self.defaults)
    QuestBeaconSettings.arrowFontSize = math.max(8, math.min(24, tonumber(QuestBeaconSettings.arrowFontSize) or 12))
    QuestBeaconSettings.trackerFontSize = math.max(8, math.min(20, tonumber(QuestBeaconSettings.trackerFontSize) or 12))
    if QuestBeaconSettings.questSort ~= "level" then QuestBeaconSettings.questSort = "distance" end
    return QuestBeaconSettings
end

function Config:Get(path)
    local settings = self:Initialize()
    local first, second = split(path)
    if not first then return nil end
    if second then return type(settings[first]) == "table" and settings[first][second] or nil end
    return settings[first]
end

function Config:Set(path, value)
    local settings = self:Initialize()
    local first, second = split(path)
    if not first then return false end
    if second then
        if type(settings[first]) ~= "table" then settings[first] = {} end
        settings[first][second] = value
    else
        settings[first] = value
    end
    self:Notify(path, value)
    return true
end

function Config:RegisterListener(owner, callback)
    if owner and type(callback) == "function" then table.insert(self.listeners, {owner=owner, callback=callback}) end
end

function Config:Notify(path, value)
    local index
    for index = 1, table.getn(self.listeners) do
        pcall(self.listeners[index].callback, self.listeners[index].owner, path, value)
    end
end

function Config:ResetUI()
    local trackingMode = QuestBeaconSettings and QuestBeaconSettings.trackingMode
    QuestBeaconSettings = copy(self.defaults)
    QuestBeaconSettings.trackingMode = trackingMode == "quest" and "quest" or "auto"
    self:Notify("reset", true)
end

Config:Initialize()
