QuestBeacon.AvailabilityService = QuestBeacon.AvailabilityService or {}
local Availability = QuestBeacon.AvailabilityService

Availability.snapshots = {}
Availability.running = {}
Availability.listeners = {}
Availability.revision = 1
Availability.generation = 0
Availability.questSignature = nil
Availability.initialized = false
Availability.serverCompleted = {}
Availability.completionQueryIssued = false
Availability.serverSync = nil
Availability.starterOffers = {}
Availability.stats = {scanned=0, available=0, publishes=0, lastAreaID=0, lastError=nil,
    completionQueryStatus="not requested", serverCompleted=0, verifiedNPCs=0}

local function positiveInteger(value)
    local number = tonumber(value)
    if not number or number <= 0 or math.floor(number) ~= number then return nil end
    return number
end

local function hasMask(mask, bit)
    if not mask or mask == 0 then return true end
    if not bit then return false end
    return math.mod(math.floor(mask / bit), 2) == 1
end

local function bitForID(value)
    local id = positiveInteger(value)
    if not id then return nil end
    return 2 ^ (id - 1)
end

local function equalSets(first, second)
    local key
    for key in pairs(first or {}) do if not second or not second[key] then return false end end
    for key in pairs(second or {}) do if not first or not first[key] then return false end end
    return true
end

function Availability:RegisterListener(owner, callback)
    if owner and type(callback) == "function" then
        table.insert(self.listeners, {owner=owner, callback=callback})
    end
end

function Availability:Notify(areaID, snapshot, changed)
    local index
    for index = 1, table.getn(self.listeners) do
        local listener = self.listeners[index]
        pcall(listener.callback, listener.owner, areaID, snapshot, changed)
    end
end

function Availability:Initialize()
    if self.initialized then return end
    self.initialized = true
    QuestBeacon.Config:RegisterListener(self, function(owner, path)
        if path == "reset" or string.find(path or "", "^availability") then owner:Invalidate("settings") end
    end)
end

function Availability:GetRevision() return self.revision end
function Availability:GetStats() return self.stats end

function Availability:ScheduleServerSync(status)
    if type(SendChatMessage) ~= "function" then
        self.stats.completionQueryStatus = status or "unsupported"
        return false
    end
    local now = type(GetTime) == "function" and GetTime() or 0
    self.nativeQueryDeadline = nil
    self.serverSync = {sendAt=now + 2, incoming={}, receivedPackets=0}
    self.stats.completionQueryStatus = "server scheduled"
    return true
end

function Availability:Invalidate(reason, preserveStarterOffers)
    self.revision = self.revision + 1
    self.generation = self.generation + 1
    self.running = {}
    if not preserveStarterOffers then
        self.starterOffers = {}
        self.stats.verifiedNPCs = 0
    end
    self.stats.lastInvalidation = reason or "unknown"
end

function Availability:ObserveQuestState(activeQuests)
    local ids = {}
    local index
    for index = 1, table.getn(activeQuests or {}) do table.insert(ids, tonumber(activeQuests[index].id) or 0) end
    table.sort(ids)
    local parts = {}
    for index = 1, table.getn(ids) do parts[index] = tostring(ids[index]) end
    local signature = table.concat(parts, ",")
    if self.questSignature ~= signature then self:Invalidate("active quests") end
    self.questSignature = signature
end

function Availability:CaptureContext(activeQuests)
    local raceToken, raceID = UnitRaceBase("player")
    local classToken, classID = UnitClassBase("player")
    raceID = tonumber(raceID)
    classID = tonumber(classID)
    local active = {}
    local progressionIDs = {}
    local progressionSeen = {}
    local index
    local function addProgressionID(value)
        local id = positiveInteger(value)
        if id and not progressionSeen[id] then
            progressionSeen[id] = true
            table.insert(progressionIDs, id)
        end
    end
    for index = 1, table.getn(activeQuests or {}) do
        active[activeQuests[index].id] = true
        addProgressionID(activeQuests[index].id)
    end
    QuestBeacon.QuestHistory:Initialize()
    -- The history can contain thousands of IDs. Scans are generation-cancelled
    -- when it changes, so sharing the stable set avoids cloning it for each area.
    local completed = QuestBeacon.QuestHistory:GetCompleted()
    local questID
    for questID in pairs(completed) do addProgressionID(questID) end
    local progressedPast = {}
    local progressionError = nil
    if QuestBeacon.DB and type(QuestBeacon.DB.GetProgressedPastQuestIDs) == "function" then
        progressedPast, progressionError = QuestBeacon.DB:GetProgressedPastQuestIDs(progressionIDs)
        if not progressedPast then progressedPast = {} end
    end
    return {level=tonumber(UnitLevel("player")) or 0, raceBit=bitForID(raceID),
        classBit=bitForID(classID), active=active,
        completed=completed,
        serverCompleted=self.serverCompleted,
        progressedPast=progressedPast, progressionError=progressionError,
        lowLevel=QuestBeacon.Config:Get("availability.lowLevel") and true or false,
        event=QuestBeacon.Config:Get("availability.event") and true or false, skillRanks={}}
end

function Availability:GetSkillRank(context, skillID)
    if context.skillRanks[skillID] ~= nil then return context.skillRanks[skillID] or nil end
    local rank = nil
    if C_SpellBook and type(C_SpellBook.GetSkillLineRank) == "function" then
        local rawRank = C_SpellBook.GetSkillLineRank(skillID)
        rank = tonumber(rawRank)
    end
    context.skillRanks[skillID] = rank or false
    return rank
end

function Availability:IsCandidateAvailable(candidate, context)
    if context.active[candidate.id] or context.completed[candidate.id] or
       context.serverCompleted[candidate.id] or context.progressedPast[candidate.id] then return false end
    if candidate.minLevel > context.level then return false end
    if candidate.level < context.level - 4 and not context.lowLevel then return false end
    if candidate.eventID and not context.event then return false end
    if not hasMask(candidate.raceMask, context.raceBit) or not hasMask(candidate.classMask, context.classBit) then return false end
    if candidate.skillID then
        local rank = self:GetSkillRank(context, candidate.skillID)
        if not rank or rank <= 0 then return false end
    end
    if table.getn(candidate.prerequisites or {}) > 0 then
        local satisfied = false
        local index
        for index = 1, table.getn(candidate.prerequisites) do
            local prerequisiteID = candidate.prerequisites[index]
            if context.completed[prerequisiteID] or context.serverCompleted[prerequisiteID] or
               context.progressedPast[prerequisiteID] then satisfied = true end
        end
        if not satisfied then return false end
    end
    return true
end

function Availability:RequestCompletedQuestSync()
    if self.completionQueryIssued then return false end
    -- Record first because compatible servers may dispatch the result synchronously.
    self.completionQueryIssued = true
    if type(QueryQuestsCompleted) ~= "function" or type(GetQuestsCompleted) ~= "function" then
        return self:ScheduleServerSync("unsupported")
    end
    self.stats.completionQueryStatus = "pending"
    self.nativeQueryDeadline = (type(GetTime) == "function" and GetTime() or 0) + 3
    local ok, queryError = pcall(QueryQuestsCompleted)
    if not ok then
        return self:ScheduleServerSync("failed: " .. tostring(queryError))
    end
    return true
end

function Availability:RestartCompletedQuestSync()
    self.completionQueryIssued = false
    self.nativeQueryDeadline = nil
    self.serverSync = nil
    return self:RequestCompletedQuestSync()
end

function Availability:OnCompletedQuestQuery()
    if not self.completionQueryIssued or type(GetQuestsCompleted) ~= "function" then return false end
    self.nativeQueryDeadline = nil
    local ok, completed = pcall(GetQuestsCompleted)
    if not ok or type(completed) ~= "table" then
        self:ScheduleServerSync("invalid result")
        return false
    end
    local nextCompleted = {}
    local questID
    for questID in pairs(completed) do
        local id = positiveInteger(questID)
        if id then nextCompleted[id] = true end
    end
    local changed = not equalSets(self.serverCompleted, nextCompleted)
    self.serverCompleted = nextCompleted
    local imported = QuestBeacon.QuestHistory and QuestBeacon.QuestHistory:ImportCompleted(nextCompleted) or 0
    local count = 0
    for questID in pairs(nextCompleted) do count = count + 1 end
    self.stats.serverCompleted = count
    self.stats.completionQueryStatus = "complete"
    if changed and imported == 0 then self:Invalidate("server completion") end
    return changed
end

function Availability:OnServerQuestData(prefix, payload)
    local state = self.serverSync
    if not state or not state.deadline or prefix ~= "TWQUEST" or type(payload) ~= "string" then return false end
    local received = false
    local position = 1
    while position <= string.len(payload) do
        local wordStart, wordEnd, word = string.find(payload, "(%S+)", position)
        if not wordStart then break end
        local id = positiveInteger(word)
        if id then state.incoming[id] = true received = true end
        position = wordEnd + 1
    end
    if received then
        state.receivedPackets = state.receivedPackets + 1
        state.deadline = (type(GetTime) == "function" and GetTime() or 0) + 1
    end
    return received
end

function Availability:ProcessCompletionSync()
    if self.nativeQueryDeadline then
        local nativeNow = type(GetTime) == "function" and GetTime() or 0
        if nativeNow >= self.nativeQueryDeadline then self:ScheduleServerSync("native timeout") end
    end
    local state = self.serverSync
    if not state then return false end
    local now = type(GetTime) == "function" and GetTime() or 0
    if state.sendAt and now >= state.sendAt then
        state.sendAt = nil
        state.deadline = now + 3
        self.stats.completionQueryStatus = "server pending"
        local ok, sendError = pcall(SendChatMessage, ".queststatus", "GUILD")
        if not ok then
            self.stats.completionQueryStatus = "failed: " .. tostring(sendError)
            self.serverSync = nil
            return false
        end
    end
    if not state.deadline or now < state.deadline then return false end
    self.serverSync = nil
    if state.receivedPackets == 0 then
        self.stats.completionQueryStatus = "server no response"
        return false
    end
    local changed = not equalSets(self.serverCompleted, state.incoming)
    self.serverCompleted = state.incoming
    local imported = QuestBeacon.QuestHistory and QuestBeacon.QuestHistory:ImportCompleted(state.incoming) or 0
    local count = 0
    local questID
    for questID in pairs(state.incoming) do count = count + 1 end
    self.stats.serverCompleted = count
    self.stats.completionQueryStatus = "server complete"
    if changed and imported == 0 then self:Invalidate("server completion") end
    return changed or imported > 0
end

function Availability:ObserveQuestgiver()
    if type(UnitCreatureID) ~= "function" or type(C_GossipInfo) ~= "table" or
       type(C_GossipInfo.GetAvailableQuests) ~= "function" then return false end
    local creatureValue = UnitCreatureID("target")
    local creatureID = positiveInteger(creatureValue)
    if not creatureID then return false end
    local ok, offers = pcall(C_GossipInfo.GetAvailableQuests)
    if not ok or type(offers) ~= "table" then return false end
    local offered = {}
    local index
    for index = 1, table.getn(offers) do
        local row = offers[index]
        local id = type(row) == "table" and positiveInteger(row.questID) or nil
        if id then offered[id] = true end
    end
    local previous = self.starterOffers[creatureID]
    if previous and equalSets(previous, offered) then return false end
    self.starterOffers[creatureID] = offered
    local count = 0
    local entryID
    for entryID in pairs(self.starterOffers) do count = count + 1 end
    self.stats.verifiedNPCs = count
    self:Invalidate("server questgiver", true)
    return true
end

function Availability:IsStarterAvailable(snapshot, questID, sourceKind, sourceID)
    local id = positiveInteger(questID)
    if not id then return false, "invalid" end
    if tonumber(sourceKind) == 1 then
        local offers = self.starterOffers[positiveInteger(sourceID)]
        if offers then
            if offers[id] then return true, "server offered" end
            return false, "server suppressed"
        end
    end
    return snapshot and snapshot.available[id] and true or false, "predicted"
end

function Availability:Publish(areaID, generation, available, scanned)
    local running = self.running[areaID]
    if not running or running.generation ~= generation or generation ~= self.generation then return end
    local previous = self.snapshots[areaID]
    local changed = {}
    local questID
    for questID in pairs(previous and previous.available or {}) do
        if not available[questID] then changed[questID] = true end
    end
    for questID in pairs(available) do
        if not previous or not previous.available[questID] then changed[questID] = true end
    end
    local snapshot = {areaID=areaID, revision=self.revision, available=available,
        changed=changed, scanned=scanned, generation=generation}
    self.snapshots[areaID] = snapshot
    self.running[areaID] = nil
    self.stats.scanned = scanned
    local availableCount = 0
    for questID in pairs(available) do availableCount = availableCount + 1 end
    self.stats.available = availableCount
    self.stats.publishes = self.stats.publishes + 1
    self.stats.lastAreaID = areaID
    self.stats.lastError = nil
    self:Notify(areaID, snapshot, changed)
end

function Availability:RequestArea(areaID)
    local id = positiveInteger(areaID)
    if not id then return false, "invalid area ID" end
    local snapshot = self.snapshots[id]
    if snapshot and snapshot.revision == self.revision then return true, nil end
    local running = self.running[id]
    if running and running.revision == self.revision then return true, nil end
    local candidates, queryError = QuestBeacon.DB:GetQuestCandidatesForArea(id)
    if not candidates then
        self.stats.lastError = queryError or "candidate query failed"
        return false, self.stats.lastError
    end
    local generation = self.generation
    local state = {areaID=id, revision=self.revision, generation=generation, candidates=candidates,
        position=1, available={}, context=self:CaptureContext(QuestBeacon.QuestService:GetActiveQuests())}
    local candidateIndex
    for candidateIndex = 1, table.getn(candidates) do
        if candidates[candidateIndex].skillID then
            self:GetSkillRank(state.context, candidates[candidateIndex].skillID)
        end
    end
    self.running[id] = state
    local function step()
        if Availability.running[id] ~= state or state.generation ~= Availability.generation then return end
        local count = 0
        while state.position <= table.getn(state.candidates) and count < 60 do
            local candidate = state.candidates[state.position]
            state.position = state.position + 1
            if Availability:IsCandidateAvailable(candidate, state.context) then state.available[candidate.id] = true end
            count = count + 1
        end
        if state.position <= table.getn(state.candidates) then
            QuestBeacon.Scheduler:Enqueue(step, "availability scan", "availability:" .. tostring(id))
        else
            Availability:Publish(id, generation, state.available, table.getn(state.candidates))
        end
    end
    QuestBeacon.Scheduler:Enqueue(step, "availability scan", "availability:" .. tostring(id))
    return true, nil
end

function Availability:GetSnapshot(areaID)
    local id = positiveInteger(areaID)
    return id and self.snapshots[id] or nil
end
