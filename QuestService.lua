QuestBeacon.QuestService = QuestBeacon.QuestService or {}
local QuestService = QuestBeacon.QuestService

QuestService.activeQuests = {}
QuestService.questsByID = {}
QuestService.pendingRequests = {}
QuestService.failedRequests = {}
QuestService.refreshing = false
QuestService.refreshAgain = false
QuestService.membershipSignature = nil

local function positiveInteger(value)
    local number = tonumber(value)
    if not number or number <= 0 or math.floor(number) ~= number then
        return nil
    end
    return number
end

local function completed(value)
    return value == true or tonumber(value) == 1
end

function QuestService:OnQuestLogChanged()
    self.failedRequests = {}
    if self.refreshing then
        self.refreshAgain = true
    end
end

function QuestService:CollectLogEntries()
    local entries = {}
    local signatureParts = {}
    local entryCount = tonumber(GetNumQuestLogEntries()) or 0
    local logIndex
    for logIndex = 1, entryCount do
        local questID = tonumber(C_QuestLog.GetQuestIDForLogIndex(logIndex))
        if questID and questID > 0 then
            table.insert(entries, { id = questID, logIndex = logIndex })
            table.insert(signatureParts, tostring(logIndex) .. ":" .. tostring(questID))
        end
    end
    return entries, table.concat(signatureParts, ",")
end

function QuestService:BuildObjective(logIndex, objectiveIndex)
    local text, objectiveKind, isComplete = GetQuestLogLeaderBoard(objectiveIndex, logIndex)
    local entryID, identityKind = GetQuestLogLeaderBoardID(objectiveIndex, logIndex)
    local kind = identityKind or objectiveKind
    local objective = {
        index = objectiveIndex,
        text = text or "",
        kind = kind,
        entryID = positiveInteger(entryID),
        complete = completed(isComplete),
        pendingData = false,
        unresolvedReason = nil,
    }
    if objective.complete then
        objective.unresolvedReason = "completed"
    elseif kind == "item" then
        objective.unresolvedReason = "unsupported_item"
    elseif kind ~= "monster" and kind ~= "object" then
        objective.unresolvedReason = "unsupported_objective_kind"
    elseif not objective.entryID then
        objective.unresolvedReason = "event_text_no_id"
    end
    return objective
end

function QuestService:BuildQuest(entry)
    local title, level, questTag, isHeader, isCollapsed, isComplete = GetQuestLogTitle(entry.logIndex)
    local quest = {
        id = entry.id,
        logIndex = entry.logIndex,
        title = title or ("Quest " .. tostring(entry.id)),
        level = tonumber(level) or 0,
        complete = completed(isComplete),
        pendingData = false,
        unresolvedReason = nil,
        objectives = {},
    }

    if not C_QuestLog.IsQuestDataCachedByID(entry.id) then
        if self.failedRequests[entry.id] then
            quest.unresolvedReason = "quest_data_unavailable"
            return quest
        end
        quest.pendingData = true
        quest.unresolvedReason = "pending_static_data"
        self.pendingRequests[entry.id] = true
        C_QuestLog.RequestLoadQuestByID(entry.id)
        return quest
    end

    self.pendingRequests[entry.id] = nil
    self.failedRequests[entry.id] = nil
    local objectiveCount = tonumber(GetNumQuestLeaderBoards(entry.logIndex)) or 0
    local objectiveIndex
    for objectiveIndex = 1, objectiveCount do
        table.insert(quest.objectives, self:BuildObjective(entry.logIndex, objectiveIndex))
    end
    return quest
end

function QuestService:Rebuild()
    local entries, signature = self:CollectLogEntries()
    if self.membershipSignature and self.membershipSignature ~= signature then
        self.failedRequests = {}
    end
    self.membershipSignature = signature

    local activeQuests = {}
    local questsByID = {}
    local seen = {}
    local index
    for index = 1, table.getn(entries) do
        local quest = self:BuildQuest(entries[index])
        table.insert(activeQuests, quest)
        questsByID[quest.id] = quest
        seen[quest.id] = true
    end
    for questID in pairs(self.pendingRequests) do
        if not seen[questID] then
            self.pendingRequests[questID] = nil
        end
    end
    for questID in pairs(self.failedRequests) do
        if not seen[questID] then
            self.failedRequests[questID] = nil
        end
    end
    self.activeQuests = activeQuests
    self.questsByID = questsByID
end

function QuestService:Refresh()
    if self.refreshing then
        self.refreshAgain = true
        return self.activeQuests
    end
    self.refreshing = true
    repeat
        self.refreshAgain = false
        self:Rebuild()
    until not self.refreshAgain
    self.refreshing = false
    return self.activeQuests
end

function QuestService:GetActiveQuests()
    return self.activeQuests
end

function QuestService:GetQuest(questID)
    local validatedID = positiveInteger(questID)
    if not validatedID then
        return nil
    end
    return self.questsByID[validatedID]
end

function QuestService:OnQuestDataLoaded(questID, success)
    local validatedID = positiveInteger(questID)
    if not validatedID or not self.pendingRequests[validatedID] then
        return
    end
    self.pendingRequests[validatedID] = nil
    if success then
        self.failedRequests[validatedID] = nil
    else
        self.failedRequests[validatedID] = true
    end
    self:Refresh()
end
