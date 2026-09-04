QuestBeacon.QuestHistory = QuestBeacon.QuestHistory or {}
local History = QuestBeacon.QuestHistory
History.revision = History.revision or 0

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
    if self.completedCount == nil then
        self.completedCount = 0
        local questID
        for questID in pairs(QuestBeaconHistory.completed) do self.completedCount = self.completedCount + 1 end
    end
end

function History:IsComplete(questID)
    self:Initialize()
    local id = positiveInteger(questID)
    return id and QuestBeaconHistory.completed[id] ~= nil or false
end

function History:NotifyChanged(reason)
    self.revision = self.revision + 1
    if QuestBeacon.AvailabilityService then
        QuestBeacon.AvailabilityService:Invalidate(reason or "quest history")
    end
    if QuestBeacon.EventCoordinator then QuestBeacon.EventCoordinator:MarkQuestDirty(false) end
end

function History:RecordComplete(questID, source)
    self:Initialize()
    local id = positiveInteger(questID)
    if not id then return false end
    local existed = QuestBeaconHistory.completed[id] ~= nil
    QuestBeaconHistory.completed[id] = {
        time = type(time) == "function" and time() or 0,
        level = type(UnitLevel) == "function" and tonumber(UnitLevel("player")) or nil,
        source = source or "turnin",
    }
    if not existed then self.completedCount = self.completedCount + 1 end
    self:NotifyChanged("quest history " .. tostring(source or "turnin"))
    return true
end

function History:ImportCompleted(completed)
    self:Initialize()
    if type(completed) ~= "table" then return 0 end
    local imported = 0
    local questID
    for questID in pairs(completed) do
        local id = positiveInteger(questID)
        if id and QuestBeaconHistory.completed[id] == nil then
            -- Thousands of server-imported IDs need only set membership; avoiding
            -- a metadata table per quest keeps the SavedVariable compact.
            QuestBeaconHistory.completed[id] = true
            imported = imported + 1
        end
    end
    if imported > 0 then
        self.completedCount = self.completedCount + imported
        self:NotifyChanged("server completion import")
    end
    return imported
end

function History:RemoveComplete(questID)
    self:Initialize()
    local id = positiveInteger(questID)
    if not id or QuestBeaconHistory.completed[id] == nil then return false end
    QuestBeaconHistory.completed[id] = nil
    self.completedCount = math.max(0, self.completedCount - 1)
    self:NotifyChanged("quest history manual correction")
    return true
end

function History:Reset()
    QuestBeaconHistory = { completed = {} }
    self.completedCount = 0
    self:NotifyChanged("quest history reset")
end

function History:GetRevision()
    return self.revision
end

function History:GetCount()
    self:Initialize()
    return self.completedCount
end

function History:GetCompleted()
    self:Initialize()
    return QuestBeaconHistory.completed
end

History:Initialize()
