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
QuestService.recoveredEntries = nil
QuestService.recoveryScanned = 0
QuestService.diagnostics = {
    visibleEntries = 0,
    expandedEntries = 0,
    collapsedHeaders = 0,
    resolvedQuestIDs = 0,
    expansionError = nil,
    source = "native_log",
    titleRows = 0,
    recoveryScanned = 0,
    recoveryActive = 0,
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

local function questLogCounts()
    local entries, quests = GetNumQuestLogEntries()
    return tonumber(entries) or 0, tonumber(quests) or 0
end

function QuestService:OnQuestLogChanged()
    self.failedRequests = {}
    if not self.scanningHeaders then
        self.recoveredEntries = nil
    end
    if self.refreshing then
        self.refreshAgain = true
    end
end

function QuestService:ScanVisibleEntries()
    local entries = {}
    local signatureParts = {}
    local entryCount = questLogCounts()
    local scanLimit = entryCount
    if scanLimit < 40 then
        scanLimit = 40
    end
    local titleRows = 0
    local logIndex
    for logIndex = 1, scanLimit do
        local title, level, questTag, isHeader = GetQuestLogTitle(logIndex)
        if title then
            titleRows = titleRows + 1
        end
        local rawQuestID = C_QuestLog.GetQuestIDForLogIndex(logIndex)
        local questID = tonumber(rawQuestID)
        if title and not isHeader and questID and questID > 0 then
            table.insert(entries, { id = questID, logIndex = logIndex })
            table.insert(signatureParts, tostring(logIndex) .. ":" .. tostring(questID))
        end
    end
    return entries, table.concat(signatureParts, ","), entryCount, titleRows
end

function QuestService:CollectCollapsedHeaders()
    local collapsed = {}
    local occurrences = {}
    local entryCount = questLogCounts()
    if entryCount < 40 then
        entryCount = 40
    end
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
    local entryCount = questLogCounts()
    if entryCount < 40 then
        entryCount = 40
    end
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

function QuestService:DiscoverPlayerQuestSlots()
    if self.recoveredEntries then
        return self.recoveredEntries, self.recoveryScanned
    end
    if not QuestBeacon.DB or type(QuestBeacon.DB.GetQuestIDs) ~= "function" or
       not C_QuestLog or type(C_QuestLog.IsUnitOnQuest) ~= "function" then
        return {}, 0
    end
    local questIDs = QuestBeacon.DB:GetQuestIDs()
    if not questIDs then
        return {}, 0
    end
    local recovered = {}
    local index
    for index = 1, table.getn(questIDs) do
        local ok, active = pcall(C_QuestLog.IsUnitOnQuest, "player", questIDs[index])
        if ok and active then
            table.insert(recovered, {
                id = questIDs[index],
                logIndex = table.getn(recovered) + 1,
                recovered = true,
            })
        end
    end
    self.recoveredEntries = recovered
    self.recoveryScanned = table.getn(questIDs)
    return recovered, table.getn(questIDs)
end

function QuestService:CollectLogEntries()
    local visibleEntries, reportedQuests = questLogCounts()
    if visibleEntries == 0 then
        self.primeAttempts = self.primeAttempts + 1
        pcall(GetQuestLogTitle, 1)
        pcall(C_QuestLog.GetQuestIDForLogIndex, 1)
        visibleEntries = questLogCounts()
    end
    local collapsed = self:CollectCollapsedHeaders()
    local collapsedCount = 0
    local key
    for key in pairs(collapsed) do
        collapsedCount = collapsedCount + 1
    end

    local entries, signature, expandedEntries, titleRows
    local expansionError = nil
    if collapsedCount > 0 and type(ExpandQuestHeader) == "function" and type(CollapseQuestHeader) == "function" then
        self.scanningHeaders = true
        local expandOK, expandResult = pcall(ExpandQuestHeader, 0)
        local scanOK, scanEntries, scanSignature, scanCount, scanTitleRows = false, nil, nil, nil, nil
        if expandOK then
            scanOK, scanEntries, scanSignature, scanCount, scanTitleRows = pcall(function()
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
            entries, signature, expandedEntries, titleRows = scanEntries, scanSignature, scanCount, scanTitleRows
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
        entries, signature, expandedEntries, titleRows = self:ScanVisibleEntries()
    end
    local source = "native_log"
    local recoveryScanned = 0
    if table.getn(entries) == 0 then
        entries, recoveryScanned = self:DiscoverPlayerQuestSlots()
        if table.getn(entries) > 0 then
            source = "player_slots"
            local signatureParts = {}
            local index
            for index = 1, table.getn(entries) do
                table.insert(signatureParts, "slot:" .. tostring(entries[index].id))
            end
            signature = table.concat(signatureParts, ",")
        end
    else
        self.recoveredEntries = nil
    end
    self.diagnostics = {
        visibleEntries = visibleEntries,
        expandedEntries = expandedEntries,
        collapsedHeaders = collapsedCount,
        resolvedQuestIDs = table.getn(entries),
        expansionError = expansionError,
        primeAttempts = self.primeAttempts,
        reportedQuests = reportedQuests,
        source = source,
        titleRows = titleRows or 0,
        recoveryScanned = recoveryScanned,
        recoveryActive = source == "player_slots" and table.getn(entries) or 0,
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
    if entry.recovered then
        return self:BuildRecoveredQuest(entry)
    end
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
    local rawObjectiveCount = GetNumQuestLeaderBoards(entry.logIndex)
    local objectiveCount = tonumber(rawObjectiveCount) or 0
    local objectiveIndex
    for objectiveIndex = 1, objectiveCount do
        table.insert(quest.objectives, self:BuildObjective(entry.logIndex, objectiveIndex))
    end
    return quest
end

function QuestService:BuildRecoveredQuest(entry)
    local quest = {
        id = entry.id,
        logIndex = entry.logIndex,
        title = "Quest " .. tostring(entry.id),
        level = 0,
        complete = false,
        pendingData = false,
        unresolvedReason = nil,
        objectives = {},
        progressUnavailable = true,
        logOrderUnavailable = true,
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
    local details = C_QuestLog.GetQuestDetails(entry.id)
    if not details then
        quest.unresolvedReason = "quest_data_unavailable"
        return quest
    end
    quest.title = details.title or quest.title
    quest.level = tonumber(details.level) or 0
    local requirements = details.requirements or {}
    local index
    for index = 1, table.getn(requirements) do
        local requirement = requirements[index]
        local objective = {
            index = index,
            text = requirement.text or "",
            kind = requirement.kind,
            entryID = positiveInteger(requirement.id),
            complete = false,
            pendingData = false,
            progressUnavailable = true,
            unresolvedReason = nil,
        }
        if objective.kind == "item" then
            objective.unresolvedReason = "unsupported_item"
        elseif objective.kind ~= "monster" and objective.kind ~= "object" then
            objective.unresolvedReason = "unsupported_objective_kind"
        elseif not objective.entryID then
            objective.unresolvedReason = "event_text_no_id"
        end
        table.insert(quest.objectives, objective)
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
