QuestBeacon.Config = QuestBeacon.Config or {}
local Config = QuestBeacon.Config

Config.listeners = {}
Config.defaults = {
    configVersion = 4,
    point = "CENTER", x = 0, y = -100, scale = 1, shown = true,
    trackingMode = "auto", arrowFontSize = 12,
    trackerShown = true, trackerLocked = false, trackerFontSize = 12,
    trackerPoint = "TOPRIGHT", trackerX = -30, trackerY = -180,
    trackerWidth = 320, trackerHeight = 300,
    trackerOpacity = 68,
    questSort = "distance", watchedQuests = {}, watchOverrides = {},
    trackerView = "all", replaceNativeTracker = true,
    trackerShowLevels = true, trackerExpandObjectives = false,
    trackerFolds = {},
    worldMap = { objectives=true, itemSources=true, turnIns=true, available=true,
        spawnPoints=true, objectiveClusters=true },
    minimap = { objectives=true, itemSources=true, turnIns=true, available=true,
        spawnPoints=true, objectiveClusters=false },
    worldMapServices = { auctioneer=false, banker=false, battlemaster=false, flight=false,
        innkeeper=false, mailbox=false, meetingstone=false, repair=false, spirithealer=false,
        stablemaster=false, vendor=false },
    minimapServices = { auctioneer=false, banker=false, battlemaster=false, flight=false,
        innkeeper=false, mailbox=false, meetingstone=false, repair=false, spirithealer=false,
        stablemaster=false, vendor=false },
    questMobs = { target=true, tooltip=true, nameplates=true },
    availability = { lowLevel=false, event=false },
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
    if (tonumber(QuestBeaconSettings.configVersion) or 0) < 2 then
        local migrated = {}
        local pending = {}
        local questID, enabled
        if type(QuestBeaconSettings.starredQuests) == "table" then
            for questID, enabled in pairs(QuestBeaconSettings.starredQuests) do
                if enabled then migrated[tonumber(questID) or questID] = true pending[tonumber(questID) or questID] = true end
            end
        end
        if type(QuestBeaconSettings.hiddenQuests) == "table" then
            for questID, enabled in pairs(QuestBeaconSettings.hiddenQuests) do
                if enabled then migrated[tonumber(questID) or questID] = false pending[tonumber(questID) or questID] = true end
            end
        end
        QuestBeaconSettings.watchedQuests = migrated
        QuestBeaconSettings.watchOverrides = pending
        QuestBeaconSettings.starredQuests = nil
        QuestBeaconSettings.hiddenQuests = nil
        QuestBeaconSettings.configVersion = 2
    end
    if (tonumber(QuestBeaconSettings.configVersion) or 0) < 3 then
        if type(QuestBeaconSettings.worldMap) ~= "table" then QuestBeaconSettings.worldMap = {} end
        if type(QuestBeaconSettings.minimap) ~= "table" then QuestBeaconSettings.minimap = {} end
        if QuestBeaconSettings.worldMap.spawnPoints == nil then QuestBeaconSettings.worldMap.spawnPoints = true end
        if QuestBeaconSettings.worldMap.objectiveClusters == nil then QuestBeaconSettings.worldMap.objectiveClusters = true end
        if QuestBeaconSettings.minimap.spawnPoints == nil then QuestBeaconSettings.minimap.spawnPoints = true end
        if QuestBeaconSettings.minimap.objectiveClusters == nil then QuestBeaconSettings.minimap.objectiveClusters = false end
        QuestBeaconSettings.configVersion = 3
    end
    if (tonumber(QuestBeaconSettings.configVersion) or 0) < 4 then
        if type(QuestBeaconSettings.availability) ~= "table" then QuestBeaconSettings.availability = {} end
        QuestBeaconSettings.availability.highLevel = nil
        QuestBeaconSettings.configVersion = 4
    end
    fill(QuestBeaconSettings, self.defaults)
    QuestBeaconSettings.arrowFontSize = math.max(8, math.min(24, tonumber(QuestBeaconSettings.arrowFontSize) or 12))
    QuestBeaconSettings.trackerFontSize = math.max(8, math.min(20, tonumber(QuestBeaconSettings.trackerFontSize) or 12))
    QuestBeaconSettings.trackerWidth = math.max(240, math.min(600, tonumber(QuestBeaconSettings.trackerWidth) or 320))
    QuestBeaconSettings.trackerHeight = math.max(100, math.min(800, tonumber(QuestBeaconSettings.trackerHeight) or 300))
    QuestBeaconSettings.trackerOpacity = math.max(0, math.min(100, tonumber(QuestBeaconSettings.trackerOpacity) or 68))
    if QuestBeaconSettings.questSort ~= "level" then QuestBeaconSettings.questSort = "distance" end
    if QuestBeaconSettings.trackerView ~= "watched" and QuestBeaconSettings.trackerView ~= "zone" then
        QuestBeaconSettings.trackerView = "all"
    end
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

function Config:SetAll(path, value)
    local settings = self:Initialize()
    local defaults = self.defaults[path]
    if type(settings[path]) ~= "table" or type(defaults) ~= "table" then return false end
    local key
    for key in pairs(defaults) do settings[path][key] = value and true or false end
    self:Notify(path, value and true or false)
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
    local watchedQuests = QuestBeaconSettings and QuestBeaconSettings.watchedQuests or {}
    local watchOverrides = QuestBeaconSettings and QuestBeaconSettings.watchOverrides or {}
    QuestBeaconSettings = copy(self.defaults)
    QuestBeaconSettings.trackingMode = trackingMode == "quest" and "quest" or "auto"
    QuestBeaconSettings.watchedQuests = watchedQuests
    QuestBeaconSettings.watchOverrides = watchOverrides
    self:Notify("reset", true)
end

Config:Initialize()
