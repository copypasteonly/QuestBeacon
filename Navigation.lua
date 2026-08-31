QuestBeacon.Navigation = QuestBeacon.Navigation or {}
local Navigation = QuestBeacon.Navigation

Navigation.state = { available = false, player = nil, target = nil, candidates = {}, reasons = {} }
Navigation.trackingMode = "auto"
Navigation.trackedQuestID = nil
Navigation.trackedObjectiveIndex = nil
Navigation.manualSignature = nil
Navigation.lastAutomaticSignature = nil
Navigation.lastAreaID = nil
Navigation.lastMapID = nil
Navigation.lastPlayerX = nil
Navigation.lastPlayerY = nil
Navigation.lastResolveTime = 0

local SOURCE_UNIT = 1
local SOURCE_OBJECT = 2
local SOURCE_ITEM = 3
local SOURCE_VENDOR = 4
local SOURCE_REFERENCE = 5
local MAX_CONTAINER_DEPTH = 4
local MOVE_REFRESH_DISTANCE_SQUARED = 625

local reasonOrder = {
    "no_active_quests", "quest_filter_not_active", "quest_complete", "quest_pending",
    "objective_completed", "event_text_no_id", "unsupported_objective_kind",
    "invalid_entity_id", "no_item_sources", "item_source_cycle", "item_source_depth",
    "no_clusters", "unusable_coordinates", "map_mismatch", "database_error",
    "no_fallback", "player_position_unavailable",
}

local function increment(reasons, name, amount)
    reasons[name] = (reasons[name] or 0) + (amount or 1)
end

local function positiveInteger(value)
    local number = tonumber(value)
    if not number or number <= 0 or math.floor(number) ~= number then
        return nil
    end
    return number
end

local function distanceSquared(player, target)
    local deltaX = player.x - target.x
    local deltaY = player.y - target.y
    return deltaX * deltaX + deltaY * deltaY
end

local function areaRank(player, target)
    if target.areaID == player.areaID or target.mappedAreaID == player.areaID then
        return 0
    end
    return 1
end

local function candidateBefore(first, second)
    if not second then
        return true
    end
    local keys = {
        "areaRank", "useRank", "noiseRank", "vendorRank", "rateRank", "sourceRank",
        "distanceSquared", "questLogIndex", "objectiveIndex", "questID", "entryID", "clusterID",
    }
    local index
    for index = 1, table.getn(keys) do
        local key = keys[index]
        if first[key] < second[key] then
            return true
        elseif first[key] > second[key] then
            return false
        end
    end
    if first.x ~= second.x then
        return first.x < second.x
    end
    if first.y ~= second.y then
        return first.y < second.y
    end
    return tostring(first.sourceType or "") < tostring(second.sourceType or "")
end

local function sourceBefore(first, second)
    if not second then
        return true
    end
    local firstKeys = { first.useRank, first.vendorRank, -(first.effectiveRate or 0), first.sourceRank }
    local secondKeys = { second.useRank, second.vendorRank, -(second.effectiveRate or 0), second.sourceRank }
    local index
    for index = 1, table.getn(firstKeys) do
        if firstKeys[index] < secondKeys[index] then
            return true
        elseif firstKeys[index] > secondKeys[index] then
            return false
        end
    end
    return tostring(first.provenance or "") < tostring(second.provenance or "")
end

local function addSource(sources, source)
    local key = tostring(source.kind) .. ":" .. tostring(source.entryID)
    if sourceBefore(source, sources[key]) then
        sources[key] = source
    end
end

function Navigation:BuildCandidate(quest, objective, cluster, player, source)
    source = source or {}
    return {
        available = true,
        quest = quest,
        objective = objective,
        kind = cluster.kind,
        entryID = cluster.entryID,
        clusterID = cluster.clusterID or 0,
        areaID = cluster.areaID,
        mappedAreaID = cluster.mappedAreaID,
        mapID = cluster.mapID,
        x = cluster.x,
        y = cluster.y,
        mapX = cluster.mapX,
        mapY = cluster.mapY,
        pointCount = cluster.pointCount or 1,
        radius = cluster.radius or 0,
        isNoise = cluster.isNoise and true or false,
        conversionStatus = cluster.conversionStatus,
        isFallback = cluster.isFallback and true or false,
        sourceType = source.sourceType or "entity",
        provenance = source.provenance,
        effectiveRate = source.effectiveRate or 100,
        areaRank = areaRank(player, cluster),
        useRank = source.useRank or 1,
        noiseRank = cluster.isNoise and 1 or 0,
        vendorRank = source.vendorRank or 1,
        rateRank = -(source.effectiveRate or 100),
        sourceRank = source.sourceRank or 0,
        distanceSquared = distanceSquared(player, cluster),
        questLogIndex = quest.logOrderUnavailable and 9999 or quest.logIndex,
        objectiveIndex = (objective and objective.index) or cluster.objectiveIndex or 9999,
        questID = quest.id,
    }
end

function Navigation:AddEntityClusters(candidates, quest, objective, source, player, reasons)
    local clusters, unusableCount, queryError = QuestBeacon.DB:GetEntityClusters(source.kind, source.entryID)
    if queryError then
        increment(reasons, "database_error")
        return
    end
    if table.getn(clusters) == 0 then
        increment(reasons, "no_clusters")
        if unusableCount and unusableCount > 0 then
            increment(reasons, "unusable_coordinates", unusableCount)
        end
        return
    end
    local clusterIndex
    for clusterIndex = 1, table.getn(clusters) do
        local cluster = clusters[clusterIndex]
        if cluster.mapID ~= player.mapID then
            increment(reasons, "map_mismatch")
        else
            table.insert(candidates, self:BuildCandidate(quest, objective, cluster, player, source))
        end
    end
end

function Navigation:CollectItemSources(itemID, reasons)
    local sources = {}
    local useTargets, useError = QuestBeacon.DB:GetItemUseTargets(itemID)
    if useError then
        increment(reasons, "database_error")
    else
        local useIndex
        for useIndex = 1, table.getn(useTargets) do
            local target = useTargets[useIndex]
            addSource(sources, {
                kind = target.kind, entryID = target.entryID, sourceType = "item_use",
                provenance = "item_use", effectiveRate = 100,
                useRank = 0, vendorRank = 1, sourceRank = 0,
            })
        end
    end

    local visiting = {}
    local function visit(currentItemID, depth, inheritedRate, chain)
        if visiting[currentItemID] then
            increment(reasons, "item_source_cycle")
            return
        end
        if depth > MAX_CONTAINER_DEPTH then
            increment(reasons, "item_source_depth")
            return
        end
        visiting[currentItemID] = true
        local rows, sourceError = QuestBeacon.DB:GetItemSources(currentItemID)
        if sourceError then
            increment(reasons, "database_error")
            visiting[currentItemID] = nil
            return
        end
        local rowIndex
        for rowIndex = 1, table.getn(rows) do
            local row = rows[rowIndex]
            local rate = tonumber(row.ratePct) or 0
            local effectiveRate = inheritedRate * rate / 100
            local provenance = chain .. ">" .. tostring(row.provenance or row.sourceKind)
            if row.sourceKind == SOURCE_UNIT or row.sourceKind == SOURCE_OBJECT then
                addSource(sources, {
                    kind = row.sourceKind, entryID = row.sourceID,
                    sourceType = depth == 0 and "drop" or "container", provenance = provenance,
                    effectiveRate = effectiveRate, useRank = 1, vendorRank = 1,
                    sourceRank = depth == 0 and 2 or 4,
                })
            elseif row.sourceKind == SOURCE_VENDOR then
                addSource(sources, {
                    kind = QuestBeacon.DB.KIND_MONSTER, entryID = row.sourceID,
                    sourceType = "vendor", provenance = provenance, effectiveRate = 100,
                    useRank = 1, vendorRank = 0, sourceRank = 1,
                })
            elseif row.sourceKind == SOURCE_REFERENCE then
                local references, referenceError = QuestBeacon.DB:GetReferenceLootSources(row.sourceID)
                if referenceError then
                    increment(reasons, "database_error")
                else
                    local referenceIndex
                    for referenceIndex = 1, table.getn(references) do
                        local reference = references[referenceIndex]
                        addSource(sources, {
                            kind = reference.kind, entryID = reference.entryID,
                            sourceType = depth == 0 and "reference_loot" or "container",
                            provenance = provenance .. ">reference", effectiveRate = effectiveRate,
                            useRank = 1, vendorRank = 1, sourceRank = depth == 0 and 3 or 4,
                        })
                    end
                end
            elseif row.sourceKind == SOURCE_ITEM then
                if depth >= MAX_CONTAINER_DEPTH then
                    increment(reasons, "item_source_depth")
                else
                    visit(row.sourceID, depth + 1, effectiveRate, provenance)
                end
            end
        end
        visiting[currentItemID] = nil
    end
    visit(itemID, 0, 100, "item:" .. tostring(itemID))

    local ordered = {}
    local key
    for key in pairs(sources) do
        table.insert(ordered, sources[key])
    end
    table.sort(ordered, sourceBefore)
    return ordered
end

function Navigation:CollectObjectiveCandidates(candidates, quest, objective, player, reasons)
    if objective.complete then
        increment(reasons, "objective_completed")
        return
    end
    if not positiveInteger(objective.entryID) then
        increment(reasons, objective.unresolvedReason or "invalid_entity_id")
        return
    end
    if objective.kind == "monster" or objective.kind == "object" then
        local kind = objective.kind == "object" and QuestBeacon.DB.KIND_OBJECT or QuestBeacon.DB.KIND_MONSTER
        self:AddEntityClusters(candidates, quest, objective, {
            kind = kind, entryID = objective.entryID, sourceType = "entity",
            effectiveRate = 100, useRank = 1, vendorRank = 1, sourceRank = 0,
        }, player, reasons)
    elseif objective.kind == "item" then
        local sources = self:CollectItemSources(objective.entryID, reasons)
        if table.getn(sources) == 0 then
            increment(reasons, "no_item_sources")
            return
        end
        local sourceIndex
        for sourceIndex = 1, table.getn(sources) do
            self:AddEntityClusters(candidates, quest, objective, sources[sourceIndex], player, reasons)
        end
    else
        increment(reasons, objective.unresolvedReason or "unsupported_objective_kind")
    end
end

function Navigation:CollectCandidates(activeQuests, player, questFilter, objectiveFilter, reasons)
    local candidates = {}
    local questIndex
    for questIndex = 1, table.getn(activeQuests) do
        local quest = activeQuests[questIndex]
        if not questFilter or quest.id == questFilter then
            if quest.complete then
                increment(reasons, "quest_complete")
            elseif quest.pendingData then
                increment(reasons, "quest_pending")
            else
                local objectiveIndex
                for objectiveIndex = 1, table.getn(quest.objectives) do
                    local objective = quest.objectives[objectiveIndex]
                    if not objectiveFilter or objective.index == objectiveFilter then
                        self:CollectObjectiveCandidates(candidates, quest, objective, player, reasons)
                    end
                end
            end
        end
    end
    table.sort(candidates, candidateBefore)
    return candidates
end

function Navigation:CollectFallbacks(activeQuests, player, questFilter, reasons)
    local candidates = {}
    local fallbackCount = 0
    local questIndex
    for questIndex = 1, table.getn(activeQuests) do
        local quest = activeQuests[questIndex]
        if (not questFilter or quest.id == questFilter) and not quest.complete and not quest.pendingData then
            local targets, queryError = QuestBeacon.DB:GetQuestFallbackTargets(quest.id, nil)
            if queryError then
                increment(reasons, "database_error")
            else
                local targetIndex
                for targetIndex = 1, table.getn(targets) do
                    local target = targets[targetIndex]
                    fallbackCount = fallbackCount + 1
                    if target.mapID ~= player.mapID then
                        increment(reasons, "map_mismatch")
                    else
                        local objective = {
                            index = target.objectiveIndex, text = "Authored fallback target",
                            kind = "fallback", entryID = target.entryID, complete = false,
                        }
                        table.insert(candidates, self:BuildCandidate(quest, objective, target, player, {
                            sourceType = "fallback", effectiveRate = 100,
                            useRank = 1, vendorRank = 1, sourceRank = 5,
                        }))
                    end
                end
            end
        end
    end
    if fallbackCount == 0 then
        increment(reasons, "no_fallback")
    end
    table.sort(candidates, candidateBefore)
    return candidates
end

function Navigation:CandidateSignature(target)
    if not target then
        return "none"
    end
    return table.concat({
        tostring(target.quest.id), tostring(target.objectiveIndex), tostring(target.kind),
        tostring(target.entryID), tostring(target.clusterID), tostring(target.mapID),
    }, ":")
end

function Navigation:Resolve(activeQuests, playerPosition, questFilter)
    local reasons = {}
    local validatedFilter = nil
    local objectiveFilter = nil
    if questFilter ~= nil then
        validatedFilter = positiveInteger(questFilter)
        if not validatedFilter then
            increment(reasons, "quest_filter_not_active")
            self.state = { available = false, player = playerPosition, target = nil, candidates = {}, reasons = reasons }
            return self.state
        end
    elseif self.trackingMode == "quest" then
        validatedFilter = self.trackedQuestID
        objectiveFilter = self.trackedObjectiveIndex
    end
    if not playerPosition or not playerPosition.available then
        increment(reasons, "player_position_unavailable")
        self.state = { available = false, player = playerPosition, target = nil, candidates = {}, reasons = reasons }
        return self.state
    end
    if not activeQuests or table.getn(activeQuests) == 0 then
        increment(reasons, "no_active_quests")
        self.state = { available = false, player = playerPosition, target = nil, candidates = {}, reasons = reasons }
        return self.state
    end

    local filterFound = not validatedFilter
    if validatedFilter then
        local index
        for index = 1, table.getn(activeQuests) do
            if activeQuests[index].id == validatedFilter then
                filterFound = true
            end
        end
    end
    if not filterFound then
        increment(reasons, "quest_filter_not_active")
        self.state = { available = false, player = playerPosition, target = nil, candidates = {}, reasons = reasons }
        return self.state
    end

    local candidates = self:CollectCandidates(activeQuests, playerPosition, validatedFilter, objectiveFilter, reasons)
    if table.getn(candidates) == 0 then
        candidates = self:CollectFallbacks(activeQuests, playerPosition, validatedFilter, reasons)
    end
    local target = candidates[1]
    if self.trackingMode == "manual" and questFilter == nil and self.manualSignature then
        local index
        for index = 1, table.getn(candidates) do
            if self:CandidateSignature(candidates[index]) == self.manualSignature then
                target = candidates[index]
            end
        end
    end
    if self.trackingMode == "manual" and target and questFilter == nil then
        self.manualSignature = self:CandidateSignature(target)
    end
    self.state = {
        available = target ~= nil, player = playerPosition, target = target,
        candidates = candidates, reasons = reasons,
    }
    return self.state
end

function Navigation:GetState()
    return self.state
end

function Navigation:GetCandidates()
    return self.state.candidates or {}
end

function Navigation:SetTrackingMode(mode, questID, objectiveIndex)
    if mode == "auto" then
        self.trackingMode = "auto"
        self.trackedQuestID = nil
        self.trackedObjectiveIndex = nil
        self.manualSignature = nil
        self.pinnedTarget = nil
        if QuestBeacon.Arrow then
            QuestBeacon.Arrow:SaveTracking()
        end
        return true, nil
    elseif mode == "manual" then
        self.trackingMode = "manual"
        self.trackedQuestID = nil
        self.trackedObjectiveIndex = nil
        if QuestBeacon.Arrow then
            QuestBeacon.Arrow:SaveTracking()
        end
        return true, nil
    elseif mode ~= "quest" then
        return false, "invalid tracking mode"
    end
    local validatedQuestID = positiveInteger(questID)
    local validatedObjectiveIndex = nil
    if objectiveIndex ~= nil then
        validatedObjectiveIndex = positiveInteger(objectiveIndex)
    end
    if not validatedQuestID or (objectiveIndex ~= nil and not validatedObjectiveIndex) then
        return false, "invalid quest or objective ID"
    end
    self.trackingMode = "quest"
    self.trackedQuestID = validatedQuestID
    self.trackedObjectiveIndex = validatedObjectiveIndex
    self.manualSignature = nil
    if QuestBeacon.Arrow then
        QuestBeacon.Arrow:SaveTracking()
    end
    return true, nil
end

function Navigation:SelectPinTarget(pin)
    if not pin or not pin.quest or pin.mapID == nil or pin.x == nil or pin.y == nil then return false end
    self.trackingMode = "pin"
    self.pinnedTarget = pin
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    self.state = {available=true, player=player, target=pin, candidates={pin}, reasons={}}
    if QuestBeacon.Arrow then QuestBeacon.Arrow:Refresh(self.state) end
    return true
end

function Navigation:ClearPinnedTarget()
    self:SetTrackingMode("auto")
    return self:AutoResolve(false)
end

function Navigation:CycleTarget(direction)
    local candidates = self:GetCandidates()
    local count = table.getn(candidates)
    if count == 0 then
        return nil, "no eligible target"
    end
    local step = tonumber(direction) or 1
    step = step < 0 and -1 or 1
    local currentSignature = self:CandidateSignature(self.state.target)
    local currentIndex = 0
    local index
    for index = 1, count do
        if self:CandidateSignature(candidates[index]) == currentSignature then
            currentIndex = index
        end
    end
    local nextIndex = currentIndex + step
    if nextIndex > count then
        nextIndex = 1
    elseif nextIndex < 1 then
        nextIndex = count
    end
    self.trackingMode = "manual"
    self.trackedQuestID = nil
    self.trackedObjectiveIndex = nil
    self.state.target = candidates[nextIndex]
    self.state.available = true
    self.manualSignature = self:CandidateSignature(self.state.target)
    if QuestBeacon.Arrow then
        QuestBeacon.Arrow:SaveTracking()
    end
    return self.state.target, nil
end

function Navigation:Clear()
    self.state = { available = false, player = nil, target = nil, candidates = {}, reasons = {} }
    self.lastAutomaticSignature = nil
    self.lastAreaID = nil
    self.lastMapID = nil
    self.lastPlayerX = nil
    self.lastPlayerY = nil
    self.lastResolveTime = 0
end

function Navigation:TargetSignature(state)
    return self:CandidateSignature(state and state.target or nil)
end

function Navigation:ReasonSummary(reasons)
    local parts = {}
    local index
    for index = 1, table.getn(reasonOrder) do
        local name = reasonOrder[index]
        if reasons[name] then
            table.insert(parts, name .. "=" .. tostring(reasons[name]))
        end
    end
    if table.getn(parts) == 0 then
        return "no eligible target"
    end
    return table.concat(parts, ", ")
end

function Navigation:PrintProof(state, automatic)
    if not state or not state.target then
        QuestBeacon:Print((automatic and "auto proof: " or "proof: ") .. self:ReasonSummary(state and state.reasons or {}))
        return
    end
    local target = state.target
    local player = state.player
    local objective = target.objective
    local prefix = automatic and "auto proof" or "proof"
    QuestBeacon:Print(prefix .. ": quest " .. target.quest.id .. " - " .. target.quest.title)
    if target.quest.progressUnavailable then
        QuestBeacon:Print("native quest progress unavailable; using authoritative player-slot and static objective IDs")
    end
    QuestBeacon:Print("objective " .. tostring(objective.index or "-") .. " " .. tostring(objective.kind) ..
        " " .. tostring(objective.entryID or "-") .. " - " .. tostring(objective.text or ""))
    if target.sourceType ~= "entity" then
        QuestBeacon:Print("source " .. tostring(target.sourceType) .. " rate=" ..
            string.format("%.2f", target.effectiveRate or 0) .. "%")
    end
    QuestBeacon:Print(string.format("player x=%.2f y=%.2f area=%d map=%d facing=%.3f",
        player.x, player.y, player.areaID, player.mapID, player.facing))
    QuestBeacon:Print(string.format("target x=%.2f y=%.2f area=%d map=%d points=%d radius=%.1f noise=%s",
        target.x, target.y, target.areaID, target.mapID, target.pointCount, target.radius,
        target.isNoise and "yes" or "no"))
    local distance = QuestBeacon.PositionService:Distance2D(player, target)
    if distance then
        QuestBeacon:Print(string.format("distance %.1f yards", distance))
    end
    if not target.isFallback and (target.kind == QuestBeacon.DB.KIND_MONSTER or target.kind == QuestBeacon.DB.KIND_OBJECT) then
        local visible = QuestBeacon.PositionService:GetVisibleObjectivePosition(target.kind, target.entryID)
        if visible.available then
            local visibleDistance = QuestBeacon.PositionService:Distance2D(player, visible)
            if visibleDistance then
                QuestBeacon:Print(string.format("visible x=%.2f y=%.2f distance=%.1f yards", visible.x, visible.y, visibleDistance))
            end
        end
    end
end

function Navigation:AutoResolve(initial)
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    local state
    if self.trackingMode == "pin" and self.pinnedTarget then
        local pinQuest = QuestBeacon.QuestService:GetQuest(self.pinnedTarget.quest.id)
        local pinInvalid = self.pinnedTarget.role == "available" and
            (pinQuest ~= nil or QuestBeacon.QuestHistory:IsComplete(self.pinnedTarget.quest.id))
        if self.pinnedTarget.role ~= "available" and not pinQuest then pinInvalid = true end
        if pinInvalid then
            self.trackingMode = "auto"
            self.pinnedTarget = nil
            state = self:Resolve(QuestBeacon.QuestService:GetActiveQuests(), player, nil)
        else
            state = {available=true, player=player, target=self.pinnedTarget, candidates={self.pinnedTarget}, reasons={}}
            self.state = state
        end
    else
        state = self:Resolve(QuestBeacon.QuestService:GetActiveQuests(), player, nil)
    end
    if player.available then
        self.lastAreaID = player.areaID
        self.lastMapID = player.mapID
        self.lastPlayerX = player.x
        self.lastPlayerY = player.y
    end
    self.lastResolveTime = type(GetTime) == "function" and GetTime() or 0
    local signature = self:TargetSignature(state)
    if not QuestBeacon.Arrow and (initial or signature ~= self.lastAutomaticSignature) then
        self:PrintProof(state, true)
    end
    if QuestBeacon.Arrow then
        QuestBeacon.Arrow:Refresh(state)
    end
    self.lastAutomaticSignature = signature
    return state
end

function Navigation:CheckAreaChange()
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    if not player.available then
        return
    end
    local now = type(GetTime) == "function" and GetTime() or 0
    local refresh = self.lastAreaID == nil or self.lastAreaID ~= player.areaID or self.lastMapID ~= player.mapID
    if not refresh and self.lastPlayerX and self.lastPlayerY then
        local deltaX = player.x - self.lastPlayerX
        local deltaY = player.y - self.lastPlayerY
        refresh = deltaX * deltaX + deltaY * deltaY >= MOVE_REFRESH_DISTANCE_SQUARED
    end
    if not refresh and now - self.lastResolveTime >= 1 then
        refresh = true
    end
    if refresh then
        self:AutoResolve(false)
    end
end

function Navigation:PrintStatus()
    local ready, reason = QuestBeacon:CheckClassicAPI()
    local hearthVersion = "unavailable"
    if type(HDB_GetVersion) == "function" then
        local ok, major, minor, patch = pcall(HDB_GetVersion)
        if ok then
            hearthVersion = tostring(major) .. "." .. tostring(minor) .. "." .. tostring(patch)
        end
    end
    local metadata = QuestBeacon.DB:GetMetadata()
    local activeQuests = QuestBeacon.QuestService:GetActiveQuests()
    local questDiagnostics = QuestBeacon.QuestService:GetDiagnostics()
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    QuestBeacon:Print("status: ClassicAPI=" .. (ready and "ready" or ("missing (" .. tostring(reason) .. ")")) .. " HearthDB=" .. hearthVersion)
    if metadata then
        QuestBeacon:Print("database schema=" .. tostring(metadata.schema_version) .. " pfQuest=" .. tostring(metadata.pfquest_commit) .. " octo=" .. tostring(metadata.pfquest_octo_commit))
    else
        QuestBeacon:Print("database unavailable: " .. tostring(QuestBeacon.disabledReason))
    end
    QuestBeacon:Print("active quests=" .. table.getn(activeQuests) .. " candidates=" .. table.getn(self:GetCandidates()) .. " mode=" .. tostring(self.trackingMode) .. " cache=" .. QuestBeacon.DB:GetCacheSize())
    QuestBeacon:Print("quest log visible=" .. tostring(questDiagnostics.visibleEntries) .. " expanded=" .. tostring(questDiagnostics.expandedEntries) .. " collapsed=" .. tostring(questDiagnostics.collapsedHeaders) .. " ids=" .. tostring(questDiagnostics.resolvedQuestIDs) .. " primes=" .. tostring(questDiagnostics.primeAttempts or 0) .. " titles=" .. tostring(questDiagnostics.titleRows or 0) .. " source=" .. tostring(questDiagnostics.source or "unknown"))
    QuestBeacon:Print("quest recovery scanned=" .. tostring(questDiagnostics.recoveryScanned or 0) .. " active=" .. tostring(questDiagnostics.recoveryActive or 0) .. " reportedQuests=" .. tostring(questDiagnostics.reportedQuests or 0))
    if questDiagnostics.expansionError then
        QuestBeacon:Print("quest header scan failed: " .. tostring(questDiagnostics.expansionError))
    end
    if player.available then
        QuestBeacon:Print(string.format("player x=%.2f y=%.2f area=%d map=%d", player.x, player.y, player.areaID, player.mapID))
    else
        QuestBeacon:Print("player unavailable: " .. tostring(player.reason))
    end
end

local function trim(value)
    return string.gsub(string.gsub(value or "", "^%s+", ""), "%s+$", "")
end

function Navigation:ResolveCurrent(questFilter)
    if QuestBeacon.EventCoordinator then
        QuestBeacon.EventCoordinator:StartQuestSettlement()
    end
    QuestBeacon.QuestService:Refresh()
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    return self:Resolve(QuestBeacon.QuestService:GetActiveQuests(), player, questFilter)
end

SLASH_QUESTBEACON1 = "/qbeacon"
SlashCmdList["QUESTBEACON"] = function(message)
    local command = string.lower(trim(message))
    if command == "status" then
        Navigation:PrintStatus()
        return
    elseif command == "show" and QuestBeacon.Arrow then
        QuestBeacon.Arrow:Show()
        return
    elseif command == "hide" and QuestBeacon.Arrow then
        QuestBeacon.Arrow:Hide()
        return
    elseif command == "reset" and QuestBeacon.Arrow then
        QuestBeacon.Arrow:Reset()
        return
    elseif command == "settings" and QuestBeacon.Settings then
        QuestBeacon.Settings:Toggle()
        return
    elseif command == "auto" then
        Navigation:SetTrackingMode("auto")
        Navigation:PrintProof(Navigation:ResolveCurrent(nil), false)
        return
    elseif command == "next" or command == "prev" then
        Navigation:ResolveCurrent(nil)
        Navigation:CycleTarget(command == "prev" and -1 or 1)
        Navigation:PrintProof(Navigation:GetState(), false)
        return
    end
    local watchStart, watchEnd, watchAction, watchQuest = string.find(command, "^(unwatch)%s+(%d+)$")
    if not watchQuest then
        watchStart, watchEnd, watchAction, watchQuest = string.find(command, "^(watch)%s+(%d+)$")
    end
    if watchQuest and QuestBeacon.WatchService then
        local watched = watchAction == "watch"
        local ok, reason = QuestBeacon.WatchService:SetWatched(tonumber(watchQuest), watched)
        if ok then
            QuestBeacon:Print((watched and "watching quest " or "stopped watching quest ") .. tostring(watchQuest))
        else
            QuestBeacon:Print("watch failed: " .. tostring(reason))
        end
        return
    end
    if command == "watch all" and QuestBeacon.Tracker then
        local failures = QuestBeacon.Tracker:WatchAll()
        if failures == 0 then QuestBeacon:Print("watching all active quests")
        else QuestBeacon:Print(tostring(failures) .. " quest watch request(s) failed") end
        return
    elseif command == "watched" and QuestBeacon.WatchService then
        local active = QuestBeacon.QuestService:GetActiveQuests()
        local watchedCount = 0
        local hiddenIndex
        for hiddenIndex = 1, table.getn(active) do
            if QuestBeacon.WatchService:IsWatched(active[hiddenIndex]) then
                watchedCount = watchedCount + 1
                QuestBeacon:Print("watched quest " .. tostring(active[hiddenIndex].id) .. " - " .. tostring(active[hiddenIndex].title))
            end
        end
        if watchedCount == 0 then
            QuestBeacon:Print("no watched active quests")
        else
            QuestBeacon:Print(tostring(watchedCount) .. " watched active quest(s)")
        end
        return
    end
    local trackStart, trackEnd, trackedQuest, trackedObjective = string.find(command, "^track%s+(%d+)%s*(%d*)$")
    if trackedQuest then
        local objective = nil
        if trackedObjective and trackedObjective ~= "" then
            objective = tonumber(trackedObjective)
        end
        local ok, reason = Navigation:SetTrackingMode("quest", tonumber(trackedQuest), objective)
        if not ok then
            QuestBeacon:Print("track failed: " .. tostring(reason))
            return
        end
        Navigation:PrintProof(Navigation:ResolveCurrent(nil), false)
        return
    end
    local questFilter = nil
    if command ~= "proof" and command ~= "" then
        local startPosition, endPosition, capturedID = string.find(command, "^proof%s+(%d+)$")
        if capturedID then
            questFilter = tonumber(capturedID)
        else
            QuestBeacon:Print("usage: /qbeacon status | proof [questID] | auto | track questID [objective] | watch [questID|all] | unwatch questID | show | hide | reset | settings")
            return
        end
    end
    Navigation:PrintProof(Navigation:ResolveCurrent(questFilter), false)
end
