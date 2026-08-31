QuestBeacon.QuestHistory = QuestBeacon.QuestHistory or {}
local History = QuestBeacon.QuestHistory

local function positiveInteger(value)
    local number = tonumber(value)
    if not number or number <= 0 or math.floor(number) ~= number then
        return nil
    end
    return number
end

function History:Initialize()
    if type(QuestBeaconHistory) ~= "table" then
        QuestBeaconHistory = {}
    end
    if type(QuestBeaconHistory.completed) ~= "table" then
        QuestBeaconHistory.completed = {}
    end
end

function History:IsComplete(questID)
    self:Initialize()
    local id = positiveInteger(questID)
    return id and QuestBeaconHistory.completed[id] ~= nil or false
end

function History:RecordComplete(questID)
    self:Initialize()
    local id = positiveInteger(questID)
    if not id then
        return false
    end
    QuestBeaconHistory.completed[id] = {
        time = type(time) == "function" and time() or 0,
        level = type(UnitLevel) == "function" and tonumber(UnitLevel("player")) or nil,
    }
    return true
end

function History:Reset()
    QuestBeaconHistory = { completed = {} }
    if QuestBeacon.AvailabilityService then QuestBeacon.AvailabilityService:Invalidate("quest history reset") end
end

History:Initialize()
