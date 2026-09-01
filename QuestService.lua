QuestBeacon.QuestService = QuestBeacon.QuestService or {}
local QuestService = QuestBeacon.QuestService

QuestService.activeQuests = {}
QuestService.questsByID = {}
QuestService.pendingRequests = {}
QuestService.failedRequests = {}
QuestService.collapsedMembership = {}
QuestService.refreshing = false
QuestService.refreshAgain = false
QuestService.membershipSignature = nil
QuestService.primeAttempts = 0
QuestService.recoveredEntries = nil
QuestService.recoveryScanned = 0
QuestService.logGeneration = 0
QuestService.recoveryState = nil
QuestService.stateRevision = 0
QuestService.stateSignature = nil
QuestService.diagnostics = {
    visibleEntries=0, expandedEntries=0, collapsedHeaders=0, resolvedQuestIDs=0,
    primeAttempts=0, reportedQuests=0, source="native_log", titleRows=0,
    recoveryScanned=0, recoveryActive=0, recoveryRunning=false, hookStatus="not_initialized",
}

local function positiveInteger(value)
    local number = tonumber(value)
    if not number or number <= 0 or math.floor(number) ~= number then return nil end
    return number
end

local function completed(value)
    return value == true or tonumber(value) == 1
end

local function itemCount(itemID)
    if not C_Item or type(C_Item.GetItemCount) ~= "function" or not itemID then return nil end
    local rawCount = C_Item.GetItemCount(itemID)
    return tonumber(rawCount)
end

local function questLogCounts()
    local entries, quests = GetNumQuestLogEntries()
    return tonumber(entries) or 0, tonumber(quests) or 0
end

local function entrySignature(entries)
    local parts = {}
    local index
    for index = 1, table.getn(entries) do
        local entry = entries[index]
        parts[index] = (entry.recovered and "slot:" or "log:") .. tostring(entry.id) .. ":" ..
            tostring(entry.logIndex or 0)
    end
    return table.concat(parts, ",")
end

function QuestService:HeaderKeyAt(logIndex)
    local occurrences = {}
    local index
    for index = 1, logIndex do
        local title, level, questTag, isHeader = GetQuestLogTitle(index)
        if isHeader and title then
            occurrences[title] = (occurrences[title] or 0) + 1
            if index == logIndex then return title .. "\001" .. tostring(occurrences[title]) end
        end
    end
    return nil
end

function QuestService:CaptureHeader(logIndex)
    local key = self:HeaderKeyAt(logIndex)
    if not key then return end
    local entries = {}
    local entryCount = questLogCounts()
    local index
    for index = logIndex + 1, entryCount do
        local title, level, questTag, isHeader = GetQuestLogTitle(index)
        if isHeader then break end
        local rawQuestID = C_QuestLog.GetQuestIDForLogIndex(index)
        local questID = tonumber(rawQuestID)
        if title and questID and questID > 0 then
            table.insert(entries, {id=questID, recovered=true, collapsed=true, headerKey=key})
        end
    end
    self.collapsedMembership[key] = entries
end

function QuestService:OnHeaderVisibilityChanged()
    if QuestBeacon.EventCoordinator then QuestBeacon.EventCoordinator:MarkQuestDirty(true) end
end

function QuestService:Initialize()
    if self.initialized then return end
    self.initialized = true
    self.originalCollapseQuestHeader = CollapseQuestHeader
    self.originalExpandQuestHeader = ExpandQuestHeader
    if type(self.originalCollapseQuestHeader) == "function" then
        self.collapseWrapper = function(logIndex)
            QuestService:CaptureHeader(logIndex)
            local first, second, third, fourth = QuestService.originalCollapseQuestHeader(logIndex)
            QuestService:OnHeaderVisibilityChanged()
            return first, second, third, fourth
        end
        CollapseQuestHeader = self.collapseWrapper
    end
    if type(self.originalExpandQuestHeader) == "function" then
        self.expandWrapper = function(logIndex)
            local key = QuestService:HeaderKeyAt(logIndex)
            local first, second, third, fourth = QuestService.originalExpandQuestHeader(logIndex)
            if key then QuestService.collapsedMembership[key] = nil end
            QuestService:OnHeaderVisibilityChanged()
            return first, second, third, fourth
        end
        ExpandQuestHeader = self.expandWrapper
    end
end

function QuestService:HooksIntact()
    local collapseOK = not self.collapseWrapper or CollapseQuestHeader == self.collapseWrapper
    local expandOK = not self.expandWrapper or ExpandQuestHeader == self.expandWrapper
    return collapseOK and expandOK
end

function QuestService:GetHookStatus()
    if not self.initialized then return "not_initialized" end
    if not self.collapseWrapper and not self.expandWrapper then return "unavailable" end
    if self:HooksIntact() then return "active" end
    return "displaced"
end

function QuestService:OnQuestLogChanged()
    self.failedRequests = {}
    self.recoveredEntries = nil
    self.recoveryState = nil
    self.logGeneration = self.logGeneration + 1
    if self.refreshing then self.refreshAgain = true end
end

function QuestService:ScanNativeEntries()
    local visibleEntries, reportedQuests = questLogCounts()
    if visibleEntries == 0 then
        self.primeAttempts = self.primeAttempts + 1
        pcall(GetQuestLogTitle, 1)
        pcall(C_QuestLog.GetQuestIDForLogIndex, 1)
        visibleEntries, reportedQuests = questLogCounts()
    end
    local scanLimit = visibleEntries
    if scanLimit < 40 then scanLimit = 40 end
    local entries = {}
    local seen = {}
    local occurrences = {}
    local titleRows = 0
    local visibleQuests = 0
    local collapsedCount = 0
    local missingCollapsed = false
    local logIndex
    for logIndex = 1, scanLimit do
        local title, level, questTag, isHeader, isCollapsed = GetQuestLogTitle(logIndex)
        if title then titleRows = titleRows + 1 end
        if isHeader and title then
            occurrences[title] = (occurrences[title] or 0) + 1
            if isCollapsed then
                collapsedCount = collapsedCount + 1
                local key = title .. "\001" .. tostring(occurrences[title])
                local cached = self.collapsedMembership[key]
                if cached then
                    local cachedIndex
                    for cachedIndex = 1, table.getn(cached) do
                        if not seen[cached[cachedIndex].id] then
                            table.insert(entries, cached[cachedIndex])
                            seen[cached[cachedIndex].id] = true
                        end
                    end
                else
                    missingCollapsed = true
                end
            end
        elseif title then
            local rawQuestID = C_QuestLog.GetQuestIDForLogIndex(logIndex)
            local questID = tonumber(rawQuestID)
            if questID and questID > 0 and not seen[questID] then
                table.insert(entries, {id=questID, logIndex=logIndex})
                seen[questID] = true
                visibleQuests = visibleQuests + 1
            end
        end
    end
    return entries, {visibleEntries=visibleEntries, reportedQuests=reportedQuests,
        expandedEntries=visibleEntries, collapsedHeaders=collapsedCount, titleRows=titleRows,
        visibleQuests=visibleQuests, missingCollapsed=missingCollapsed}
end

function QuestService:NeedsRecovery(entries, scan)
    if table.getn(entries) == 0 then return true end
    if scan.missingCollapsed then return true end
    if scan.reportedQuests > table.getn(entries) then return true end
    return false
end

function QuestService:MergeRecovered(nativeEntries, recoveredEntries)
    local recoveredSet = {}
    local index
    for index = 1, table.getn(recoveredEntries or {}) do recoveredSet[recoveredEntries[index].id] = true end
    local result = {}
    local seen = {}
    for index = 1, table.getn(nativeEntries or {}) do
        local entry = nativeEntries[index]
        if (not entry.recovered or recoveredSet[entry.id]) and not seen[entry.id] then
            table.insert(result, entry)
            seen[entry.id] = true
        end
    end
    for index = 1, table.getn(recoveredEntries or {}) do
        local entry = recoveredEntries[index]
        if not seen[entry.id] then table.insert(result, entry) seen[entry.id] = true end
    end
    return result
end

function QuestService:StartRecovery(nativeEntries, scan)
    if self.recoveryState and self.recoveryState.generation == self.logGeneration then return end
    if not QuestBeacon.DB or type(QuestBeacon.DB.GetQuestIDs) ~= "function" or
       not C_QuestLog or type(C_QuestLog.IsUnitOnQuest) ~= "function" or not QuestBeacon.Scheduler then
        self.diagnostics.recoveryError = "player-slot recovery is unavailable"
        return
    end
    local questIDs, queryError = QuestBeacon.DB:GetQuestIDs()
    if not questIDs then
        self.diagnostics.recoveryError = queryError or "quest ID catalog is unavailable"
        return
    end
    local state = {generation=self.logGeneration, questIDs=questIDs, position=1, recovered={},
        nativeEntries=nativeEntries, scan=scan}
    self.recoveryState = state
    self.diagnostics = {visibleEntries=scan.visibleEntries, expandedEntries=scan.expandedEntries,
        collapsedHeaders=scan.collapsedHeaders, resolvedQuestIDs=table.getn(self.activeQuests),
        primeAttempts=self.primeAttempts, reportedQuests=scan.reportedQuests,
        source="player_slots_pending", titleRows=scan.titleRows, recoveryScanned=0,
        recoveryActive=0, recoveryRunning=true,
        hookStatus=self:GetHookStatus()}
    local function step()
        if QuestService.recoveryState ~= state or state.generation ~= QuestService.logGeneration then return end
        local count = 0
        while state.position <= table.getn(state.questIDs) and count < 60 do
            local questID = state.questIDs[state.position]
            state.position = state.position + 1
            local ok, active = pcall(C_QuestLog.IsUnitOnQuest, "player", questID)
            if ok and active then table.insert(state.recovered, {id=questID,recovered=true,logOrderUnavailable=true}) end
            count = count + 1
        end
        QuestService.diagnostics.recoveryScanned = state.position - 1
        QuestService.diagnostics.recoveryActive = table.getn(state.recovered)
        if state.position <= table.getn(state.questIDs) then
            QuestBeacon.Scheduler:Enqueue(step, "quest slot recovery", "quest-slot-recovery")
            return
        end
        QuestService.recoveredEntries = state.recovered
        QuestService.recoveryScanned = table.getn(state.questIDs)
        QuestService.recoveryState = nil
        -- Publish from the normal event path so every consumer sees the same completed snapshot.
        if QuestBeacon.EventCoordinator then QuestBeacon.EventCoordinator.questDirty = true end
    end
    QuestBeacon.Scheduler:Enqueue(step, "quest slot recovery", "quest-slot-recovery")
end

function QuestService:BuildObjective(logIndex, objectiveIndex)
    local text, objectiveKind, isComplete = GetQuestLogLeaderBoard(objectiveIndex, logIndex)
    local entryID, identityKind = GetQuestLogLeaderBoardID(objectiveIndex, logIndex)
    local kind = identityKind or objectiveKind
    local objective = {index=objectiveIndex, text=text or "", kind=kind,
        entryID=positiveInteger(entryID), complete=completed(isComplete), pendingData=false, unresolvedReason=nil}
    if objective.complete then objective.unresolvedReason = "completed"
    elseif kind ~= "monster" and kind ~= "object" and kind ~= "item" then
        objective.unresolvedReason = "unsupported_objective_kind"
    elseif not objective.entryID then objective.unresolvedReason = "event_text_no_id" end
    return objective
end

function QuestService:BuildQuest(entry)
    if entry.recovered then return self:BuildRecoveredQuest(entry) end
    local title, level, questTag, isHeader, isCollapsed, isComplete = GetQuestLogTitle(entry.logIndex)
    local quest = {id=entry.id, logIndex=entry.logIndex, title=title or ("Quest " .. tostring(entry.id)),
        level=tonumber(level) or 0, complete=completed(isComplete), pendingData=false,
        unresolvedReason=nil, objectives={}}
    if not C_QuestLog.IsQuestDataCachedByID(entry.id) then
        if self.failedRequests[entry.id] then quest.unresolvedReason = "quest_data_unavailable" return quest end
        quest.pendingData = true quest.unresolvedReason = "pending_static_data"
        self.pendingRequests[entry.id] = true
        C_QuestLog.RequestLoadQuestByID(entry.id)
        return quest
    end
    self.pendingRequests[entry.id] = nil self.failedRequests[entry.id] = nil
    local rawObjectiveCount = GetNumQuestLeaderBoards(entry.logIndex)
    local objectiveCount = tonumber(rawObjectiveCount) or 0
    if objectiveCount == 0 then quest.complete = true end
    local objectiveIndex
    for objectiveIndex = 1, objectiveCount do
        table.insert(quest.objectives, self:BuildObjective(entry.logIndex, objectiveIndex))
    end
    return quest
end

function QuestService:BuildRecoveredQuest(entry)
    local quest = {id=entry.id, logIndex=nil, title="Quest " .. tostring(entry.id), level=0,
        complete=false, pendingData=false, unresolvedReason=nil, objectives={},
        progressUnavailable=true, logOrderUnavailable=true}
    if not C_QuestLog.IsQuestDataCachedByID(entry.id) then
        if self.failedRequests[entry.id] then quest.unresolvedReason = "quest_data_unavailable" return quest end
        quest.pendingData = true quest.unresolvedReason = "pending_static_data"
        self.pendingRequests[entry.id] = true
        C_QuestLog.RequestLoadQuestByID(entry.id)
        return quest
    end
    local details = C_QuestLog.GetQuestDetails(entry.id)
    if not details then quest.unresolvedReason = "quest_data_unavailable" return quest end
    quest.title = details.title or quest.title
    quest.level = tonumber(details.level) or 0
    local requirements = details.requirements or {}
    local index
    for index = 1, table.getn(requirements) do
        local requirement = requirements[index]
        local objective = {index=index, text=requirement.text or "", kind=requirement.kind,
            entryID=positiveInteger(requirement.id), complete=false, pendingData=false,
            progressUnavailable=true, requiredCount=positiveInteger(requirement.count),
            currentCount=nil, unresolvedReason=nil}
        if objective.kind == "item" then
            objective.currentCount = itemCount(objective.entryID)
            if objective.currentCount ~= nil and objective.requiredCount then
                objective.progressUnavailable = false
                objective.complete = objective.currentCount >= objective.requiredCount
                if objective.complete then objective.unresolvedReason = "completed" end
            end
        elseif objective.kind ~= "monster" and objective.kind ~= "object" then
            objective.unresolvedReason = "unsupported_objective_kind"
        elseif not objective.entryID then objective.unresolvedReason = "event_text_no_id" end
        table.insert(quest.objectives, objective)
    end
    return quest
end

function QuestService:UpdateStateRevision(activeQuests)
    local parts = {}
    local index
    for index = 1, table.getn(activeQuests) do
        local quest = activeQuests[index]
        table.insert(parts, table.concat({tostring(quest.id), tostring(quest.title or ""),
            quest.complete and "1" or "0", quest.pendingData and "1" or "0"}, ":"))
        local objectiveIndex
        for objectiveIndex = 1, table.getn(quest.objectives) do
            local objective = quest.objectives[objectiveIndex]
            table.insert(parts, table.concat({tostring(objective.index), tostring(objective.kind or ""),
                tostring(objective.entryID or 0), objective.complete and "1" or "0",
                tostring(objective.currentCount or ""), tostring(objective.requiredCount or ""),
                tostring(objective.unresolvedReason or "")}, ":"))
        end
    end
    local signature = table.concat(parts, "|")
    if self.stateSignature ~= signature then
        self.stateSignature = signature
        self.stateRevision = self.stateRevision + 1
    end
end

function QuestService:PublishEntries(entries, source, scan)
    local signature = entrySignature(entries)
    if self.membershipSignature and self.membershipSignature ~= signature then self.failedRequests = {} end
    self.membershipSignature = signature
    local activeQuests = {}
    local questsByID = {}
    local seen = {}
    local index
    for index = 1, table.getn(entries) do
        local quest = self:BuildQuest(entries[index])
        table.insert(activeQuests, quest) questsByID[quest.id] = quest seen[quest.id] = true
    end
    local questID
    for questID in pairs(self.pendingRequests) do if not seen[questID] then self.pendingRequests[questID] = nil end end
    for questID in pairs(self.failedRequests) do if not seen[questID] then self.failedRequests[questID] = nil end end
    self.activeQuests = activeQuests
    self.questsByID = questsByID
    self:UpdateStateRevision(activeQuests)
    self.diagnostics = {visibleEntries=scan.visibleEntries, expandedEntries=scan.expandedEntries,
        collapsedHeaders=scan.collapsedHeaders, resolvedQuestIDs=table.getn(entries),
        primeAttempts=self.primeAttempts, reportedQuests=scan.reportedQuests, source=source,
        titleRows=scan.titleRows, recoveryScanned=source == "player_slots" and self.recoveryScanned or 0,
        recoveryActive=source == "player_slots" and table.getn(self.recoveredEntries or {}) or 0,
        recoveryRunning=false, hookStatus=self:GetHookStatus()}
end

function QuestService:RefreshOnce()
    local nativeEntries, scan = self:ScanNativeEntries()
    if self:NeedsRecovery(nativeEntries, scan) then
        if self.recoveredEntries then
            self:PublishEntries(self:MergeRecovered(nativeEntries, self.recoveredEntries), "player_slots", scan)
            return true
        end
        self:StartRecovery(nativeEntries, scan)
        return false
    end
    self.recoveryState = nil
    self.recoveredEntries = nil
    self:PublishEntries(nativeEntries, "native_log", scan)
    return true
end

function QuestService:Refresh()
    if self.refreshing then self.refreshAgain = true return self.activeQuests, false end
    self.refreshing = true
    local published = false
    repeat
        self.refreshAgain = false
        if self:RefreshOnce() then published = true end
    until not self.refreshAgain
    self.refreshing = false
    return self.activeQuests, published
end

function QuestService:GetActiveQuests() return self.activeQuests end
function QuestService:GetRevision() return self.stateRevision end
function QuestService:GetDiagnostics() return self.diagnostics end

function QuestService:GetQuest(questID)
    local id = positiveInteger(questID)
    return id and self.questsByID[id] or nil
end

function QuestService:OnQuestDataLoaded(questID, success)
    local id = positiveInteger(questID)
    if not id or not self.pendingRequests[id] then return end
    self.pendingRequests[id] = nil
    if success then self.failedRequests[id] = nil else self.failedRequests[id] = true end
    self:Refresh()
end
