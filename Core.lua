QuestBeacon = QuestBeacon or {}

QuestBeacon.NAME = "QuestBeacon"
QuestBeacon.VERSION = "0.5.0"
QuestBeacon.SCHEMA_VERSION = 6
QuestBeacon.enabled = false
QuestBeacon.disabledReason = nil
QuestBeacon.errorPrinted = false

function QuestBeacon:Print(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuestBeacon:|r " .. tostring(message))
    end
end

function QuestBeacon:Disable(reason)
    self.enabled = false
    self.disabledReason = tostring(reason or "unknown error")
    if not self.errorPrinted then
        self.errorPrinted = true
        self:Print("disabled - " .. self.disabledReason)
    end
end

function QuestBeacon:CheckClassicAPI()
    local missing = {}
    local function requireFunction(value, name)
        if type(value) ~= "function" then
            table.insert(missing, name)
        end
    end

    if type(C_QuestLog) ~= "table" then
        table.insert(missing, "C_QuestLog")
    else
        requireFunction(C_QuestLog.GetQuestIDForLogIndex, "C_QuestLog.GetQuestIDForLogIndex")
        requireFunction(C_QuestLog.RequestLoadQuestByID, "C_QuestLog.RequestLoadQuestByID")
        requireFunction(C_QuestLog.IsQuestDataCachedByID, "C_QuestLog.IsQuestDataCachedByID")
        requireFunction(C_QuestLog.IsUnitOnQuest, "C_QuestLog.IsUnitOnQuest")
        requireFunction(C_QuestLog.GetQuestDetails, "C_QuestLog.GetQuestDetails")
    end
    requireFunction(GetNumQuestLogEntries, "GetNumQuestLogEntries")
    requireFunction(GetQuestLogTitle, "GetQuestLogTitle")
    requireFunction(GetNumQuestLeaderBoards, "GetNumQuestLeaderBoards")
    requireFunction(GetQuestLogLeaderBoard, "GetQuestLogLeaderBoard")
    requireFunction(GetQuestLogLeaderBoardID, "GetQuestLogLeaderBoardID")

    if type(C_PlayerInfo) ~= "table" then
        table.insert(missing, "C_PlayerInfo")
    else
        requireFunction(C_PlayerInfo.UnitPosition, "C_PlayerInfo.UnitPosition")
    end
    if type(C_Map) ~= "table" then
        table.insert(missing, "C_Map")
    else
        requireFunction(C_Map.GetBestMapForUnit, "C_Map.GetBestMapForUnit")
    end
    requireFunction(GetPlayerFacing, "GetPlayerFacing")

    if table.getn(missing) > 0 then
        return false, table.concat(missing, ", ")
    end
    return true, nil
end

function QuestBeacon:CheckHearthDB()
    local missing = {}
    local function requireFunction(value, name)
        if type(value) ~= "function" then
            table.insert(missing, name)
        end
    end
    requireFunction(HDB_OpenAddon, "HDB_OpenAddon")
    requireFunction(HDB_QueryRaw, "HDB_QueryRaw")
    requireFunction(HDB_Close, "HDB_Close")
    requireFunction(HDB_GetVersion, "HDB_GetVersion")
    if table.getn(missing) > 0 then
        return false, table.concat(missing, ", ")
    end
    return true, nil
end

function QuestBeacon:CheckDependencies()
    local classicReady, classicReason = self:CheckClassicAPI()
    local hearthReady, hearthReason = self:CheckHearthDB()
    if not classicReady then
        return false, "missing ClassicAPI functions: " .. tostring(classicReason)
    end
    if not hearthReady then
        return false, "missing HearthDB functions: " .. tostring(hearthReason)
    end
    return true, nil
end

function QuestBeacon:Initialize()
    if self.enabled or self.disabledReason then
        return self.enabled
    end
    local ready, reason = self:CheckDependencies()
    if not ready then
        self:Disable(reason)
        return false
    end
    self.enabled = true
    return true
end
