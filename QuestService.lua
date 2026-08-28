QuestBeacon.QuestService = QuestBeacon.QuestService or {}
local QuestService = QuestBeacon.QuestService

QuestService.activeQuests = {}
QuestService.questsByID = {}
QuestService.pendingRequests = {}
QuestService.failedRequests = {}
QuestService.refreshing = false
QuestService.refreshAgain = false
QuestService.membershipSignature = nil
QuestService.scanningHeaders = false
QuestService.primeAttempts = 0
QuestService.diagnostics = {
    visibleEntries = 0,
    expandedEntries = 0,
    collapsedHeaders = 0,
    resolvedQuestIDs = 0,
    expansionError = nil,
}

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

function QuestService:ScanVisibleEntries()
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
    return entries, table.concat(signatureParts, ","), entryCount
end

function QuestService:CollectCollapsedHeaders()
    local collapsed = {}
    local occurrences = {}
    local entryCount = tonumber(GetNumQuestLogEntries()) or 0
    local logIndex
    for logIndex = 1, entryCount do
        local title, level, questTag, isHeader, isCollapsed = GetQuestLogTitle(logIndex)
        if isHeader and title then
            occurrences[title] = (occurrences[title] or 0) + 1
            if isCollapsed then
                local key = title .. "\001" .. tostring(occurrences[title])
                collapsed[key] = true
            end
        end
    end
    return collapsed
end

function QuestService:RestoreCollapsedHeaders(collapsed)
    local restoreIndexes = {}
    local occurrences = {}
    local entryCount = tonumber(GetNumQuestLogEntries()) or 0
    local logIndex
    for logIndex = 1, entryCount do
        local title, level, questTag, isHeader = GetQuestLogTitle(logIndex)
        if isHeader and title then
            occurrences[title] = (occurrences[title] or 0) + 1
            local key = title .. "\001" .. tostring(occurrences[title])
            if collapsed[key] then
                table.insert(restoreIndexes, logIndex)
            end
        end
    end
    local index
    for index = table.getn(restoreIndexes), 1, -1 do
        CollapseQuestHeader(restoreIndexes[index])
    end
end

function QuestService:CollectLogEntries()
    local visibleEntries = tonumber(GetNumQuestLogEntries()) or 0
    if visibleEntries == 0 then
        self.primeAttempts = self.primeAttempts + 1
        pcall(GetQuestLogTitle, 1)
        pcall(C_QuestLog.GetQuestIDForLogIndex, 1)
        visibleEntries = tonumber(GetNumQuestLogEntries()) or 0
    end
    local collapsed = self:CollectCollapsedHeaders()
    local collapsedCount = 0
    local key
    for key in pairs(collapsed) do
        collapsedCount = collapsedCount + 1
    end

    local entries, signature, expandedEntries
    local expansionError = nil
    if collapsedCount > 0 and type(ExpandQuestHeader) == "function" and type(CollapseQuestHeader) == "function" then
        self.scanningHeaders = true
        local expandOK, expandResult = pcall(ExpandQuestHeader, 0)
        local scanOK, scanEntries, scanSignature, scanCount = false, nil, nil, nil
        if expandOK then
            scanOK, scanEntries, scanSignature, scanCount = pcall(function()
                return self:ScanVisibleEntries()
            end)
        end
        local restoreOK, restoreResult = true, nil
        if expandOK then
            restoreOK, restoreResult = pcall(function()
                self:RestoreCollapsedHeaders(collapsed)
            end)
        end
        self.scanningHeaders = false
        if expandOK and scanOK and restoreOK then
            entries, signature, expandedEntries = scanEntries, scanSignature, scanCount
        else
            if not expandOK then
                expansionError = "expand: " .. tostring(expandResult)
            elseif not scanOK then
                expansionError = "scan: " .. tostring(scanEntries)
            else
                expansionError = "restore: " .. tostring(restoreResult)
            end
        end
    end
    if not entries then
        entries, signature, expandedEntries = self:ScanVisibleEntries()
    end
    self.diagnostics = {
        visibleEntries = visibleEntries,
        expandedEntries = expandedEntries,
        collapsedHeaders = collapsedCount,
        resolvedQuestIDs = table.getn(entries),
        expansionError = expansionError,
        primeAttempts = self.primeAttempts,
    }
    return entries, signature
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

function QuestService:GetDiagnostics()
    return self.diagnostics
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
