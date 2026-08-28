QuestBeacon.Navigation = QuestBeacon.Navigation or {}
local Navigation = QuestBeacon.Navigation

Navigation.state = { available = false, player = nil, target = nil, reasons = {} }
Navigation.lastAutomaticSignature = nil
Navigation.lastAreaID = nil
Navigation.lastMapID = nil

local reasonOrder = {
    "no_active_quests", "quest_filter_not_active", "quest_complete", "quest_pending",
    "objective_completed", "unsupported_item", "event_text_no_id",
    "unsupported_objective_kind", "invalid_entity_id", "no_clusters",
    "unusable_coordinates", "map_mismatch", "database_error", "no_fallback",
    "player_position_unavailable",
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
    local keys = { "areaRank", "noiseRank", "distanceSquared", "questLogIndex", "objectiveIndex", "clusterID", "entryID" }
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
    return first.y < second.y
end

function Navigation:BuildCandidate(quest, objective, cluster, player)
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
        areaRank = areaRank(player, cluster),
        noiseRank = cluster.isNoise and 1 or 0,
        distanceSquared = distanceSquared(player, cluster),
        questLogIndex = quest.logIndex,
        objectiveIndex = (objective and objective.index) or cluster.objectiveIndex or 9999,
    }
end

function Navigation:ResolveEntityObjectives(activeQuests, player, questFilter, reasons)
    local best = nil
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
                    if objective.complete then
                        increment(reasons, "objective_completed")
                    elseif objective.kind == "item" then
                        increment(reasons, "unsupported_item")
                    elseif objective.kind ~= "monster" and objective.kind ~= "object" then
                        increment(reasons, objective.unresolvedReason or "unsupported_objective_kind")
                    elseif not positiveInteger(objective.entryID) then
                        increment(reasons, objective.unresolvedReason or "invalid_entity_id")
                    else
                        local kind = QuestBeacon.DB.KIND_MONSTER
                        if objective.kind == "object" then
                            kind = QuestBeacon.DB.KIND_OBJECT
                        end
                        local clusters, unusableCount, queryError = QuestBeacon.DB:GetEntityClusters(kind, objective.entryID)
                        if queryError then
                            increment(reasons, "database_error")
                        elseif table.getn(clusters) == 0 then
                            increment(reasons, "no_clusters")
                            if unusableCount and unusableCount > 0 then
                                increment(reasons, "unusable_coordinates", unusableCount)
                            end
                        else
                            local clusterIndex
                            for clusterIndex = 1, table.getn(clusters) do
                                local cluster = clusters[clusterIndex]
                                if cluster.mapID ~= player.mapID then
                                    increment(reasons, "map_mismatch")
                                else
                                    local candidate = self:BuildCandidate(quest, objective, cluster, player)
                                    if candidateBefore(candidate, best) then
                                        best = candidate
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return best
end

function Navigation:ResolveFallbacks(activeQuests, player, questFilter, reasons)
    local best = nil
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
                            index = target.objectiveIndex,
                            text = "Authored fallback target",
                            kind = "fallback",
                            entryID = target.entryID,
                            complete = false,
                        }
                        local candidate = self:BuildCandidate(quest, objective, target, player)
                        if candidateBefore(candidate, best) then
                            best = candidate
                        end
                    end
                end
            end
        end
    end
    if fallbackCount == 0 then
        increment(reasons, "no_fallback")
    end
    return best
end

function Navigation:Resolve(activeQuests, playerPosition, questFilter)
    local reasons = {}
    local validatedFilter = nil
    if questFilter ~= nil then
        validatedFilter = positiveInteger(questFilter)
        if not validatedFilter then
            increment(reasons, "quest_filter_not_active")
            self.state = { available = false, player = playerPosition, target = nil, reasons = reasons }
            return self.state
        end
    end
    if not playerPosition or not playerPosition.available then
        increment(reasons, "player_position_unavailable")
        self.state = { available = false, player = playerPosition, target = nil, reasons = reasons }
        return self.state
    end
    if not activeQuests or table.getn(activeQuests) == 0 then
        increment(reasons, "no_active_quests")
        self.state = { available = false, player = playerPosition, target = nil, reasons = reasons }
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
        self.state = { available = false, player = playerPosition, target = nil, reasons = reasons }
        return self.state
    end

    local target = self:ResolveEntityObjectives(activeQuests, playerPosition, validatedFilter, reasons)
    if not target then
        target = self:ResolveFallbacks(activeQuests, playerPosition, validatedFilter, reasons)
    end
    self.state = {
        available = target ~= nil,
        player = playerPosition,
        target = target,
        reasons = reasons,
    }
    return self.state
end

function Navigation:GetState()
    return self.state
end

function Navigation:Clear()
    self.state = { available = false, player = nil, target = nil, reasons = {} }
    self.lastAutomaticSignature = nil
    self.lastAreaID = nil
    self.lastMapID = nil
end

function Navigation:TargetSignature(state)
    if not state or not state.target then
        return "none"
    end
    local target = state.target
    return table.concat({
        tostring(target.quest.id), tostring(target.objectiveIndex), tostring(target.kind),
        tostring(target.entryID), tostring(target.clusterID), tostring(target.mapID),
    }, ":")
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
                QuestBeacon:Print(string.format("visible x=%.2f y=%.2f distance=%.1f yards",
                    visible.x, visible.y, visibleDistance))
            end
        end
    end
end

function Navigation:AutoResolve(initial)
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    if player.available then
        self.lastAreaID = player.areaID
        self.lastMapID = player.mapID
    end
    local state = self:Resolve(QuestBeacon.QuestService:GetActiveQuests(), player, nil)
    local signature = self:TargetSignature(state)
    if initial or signature ~= self.lastAutomaticSignature then
        self:PrintProof(state, true)
        self.lastAutomaticSignature = signature
    end
    return state
end

function Navigation:CheckAreaChange()
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    if not player.available then
        return
    end
    if self.lastAreaID == nil then
        self:AutoResolve(false)
    elseif self.lastAreaID ~= player.areaID or self.lastMapID ~= player.mapID then
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
    QuestBeacon:Print("status: ClassicAPI=" .. (ready and "ready" or ("missing (" .. tostring(reason) .. ")")) ..
        " HearthDB=" .. hearthVersion)
    if metadata then
        QuestBeacon:Print("database schema=" .. tostring(metadata.schema_version) ..
            " pfQuest=" .. tostring(metadata.pfquest_commit) ..
            " octo=" .. tostring(metadata.pfquest_octo_commit))
    else
        QuestBeacon:Print("database unavailable: " .. tostring(QuestBeacon.disabledReason))
    end
    QuestBeacon:Print("active quests=" .. table.getn(activeQuests) ..
        " entity cache=" .. QuestBeacon.DB:GetCacheSize())
    QuestBeacon:Print("quest log visible=" .. tostring(questDiagnostics.visibleEntries) ..
        " expanded=" .. tostring(questDiagnostics.expandedEntries) ..
        " collapsed=" .. tostring(questDiagnostics.collapsedHeaders) ..
        " ids=" .. tostring(questDiagnostics.resolvedQuestIDs) ..
        " primes=" .. tostring(questDiagnostics.primeAttempts or 0) ..
        " titles=" .. tostring(questDiagnostics.titleRows or 0) ..
        " source=" .. tostring(questDiagnostics.source or "unknown"))
    QuestBeacon:Print("quest recovery scanned=" .. tostring(questDiagnostics.recoveryScanned or 0) ..
        " active=" .. tostring(questDiagnostics.recoveryActive or 0) ..
        " reportedQuests=" .. tostring(questDiagnostics.reportedQuests or 0))
    if questDiagnostics.expansionError then
        QuestBeacon:Print("quest header scan failed: " .. tostring(questDiagnostics.expansionError))
    end
    if player.available then
        QuestBeacon:Print(string.format("player x=%.2f y=%.2f area=%d map=%d",
            player.x, player.y, player.areaID, player.mapID))
    else
        QuestBeacon:Print("player unavailable: " .. tostring(player.reason))
    end
end

local function trim(value)
    return string.gsub(string.gsub(value or "", "^%s+", ""), "%s+$", "")
end

SLASH_QUESTBEACON1 = "/qbeacon"
SlashCmdList["QUESTBEACON"] = function(message)
    local command = string.lower(trim(message))
    if command == "status" then
        Navigation:PrintStatus()
        return
    end
    local questFilter = nil
    if command ~= "proof" and command ~= "" then
        local startPosition, endPosition, capturedID = string.find(command, "^proof%s+(%d+)$")
        if capturedID then
            questFilter = tonumber(capturedID)
        else
            QuestBeacon:Print("usage: /qbeacon status | proof [activeQuestID]")
            return
        end
    end
    if QuestBeacon.EventCoordinator then
        QuestBeacon.EventCoordinator:StartQuestSettlement()
    end
    QuestBeacon.QuestService:Refresh()
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    local state = Navigation:Resolve(QuestBeacon.QuestService:GetActiveQuests(), player, questFilter)
    Navigation:PrintProof(state, false)
end
