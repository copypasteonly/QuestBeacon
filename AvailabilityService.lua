QuestBeacon.AvailabilityService = QuestBeacon.AvailabilityService or {}
local Availability = QuestBeacon.AvailabilityService

Availability.snapshots = {}
Availability.running = {}
Availability.listeners = {}
Availability.revision = 1
Availability.generation = 0
Availability.questSignature = nil
Availability.initialized = false
Availability.stats = {scanned=0, available=0, publishes=0, lastAreaID=0, lastError=nil}

local RACE_MASKS = {HUMAN=1, ORC=2, DWARF=4, NIGHTELF=8, SCOURGE=16, TAUREN=32, GNOME=64, TROLL=128}
local CLASS_MASKS = {WARRIOR=1, PALADIN=2, HUNTER=4, ROGUE=8, PRIEST=16, SHAMAN=64, MAGE=128, WARLOCK=256, DRUID=1024}

local function positiveInteger(value)
    local number = tonumber(value)
    if not number or number <= 0 or math.floor(number) ~= number then return nil end
    return number
end

local function hasMask(mask, bit)
    if not mask or mask == 0 or not bit then return true end
    return math.mod(math.floor(mask / bit), 2) == 1
end

local function copySet(source)
    local result = {}
    local key, value
    for key, value in pairs(source or {}) do
        if value then result[tonumber(key) or key] = true end
    end
    return result
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

function Availability:Invalidate(reason)
    self.revision = self.revision + 1
    self.generation = self.generation + 1
    self.running = {}
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
    local _, raceToken = UnitRace("player")
    local _, classToken = UnitClass("player")
    local active = {}
    local activeIDs = {}
    local index
    for index = 1, table.getn(activeQuests or {}) do
        active[activeQuests[index].id] = true
        table.insert(activeIDs, activeQuests[index].id)
    end
    local progressedPast = {}
    local progressionError = nil
    if QuestBeacon.DB and type(QuestBeacon.DB.GetProgressedPastQuestIDs) == "function" then
        progressedPast, progressionError = QuestBeacon.DB:GetProgressedPastQuestIDs(activeIDs)
        if not progressedPast then progressedPast = {} end
    end
    QuestBeacon.QuestHistory:Initialize()
    return {level=tonumber(UnitLevel("player")) or 0, raceBit=RACE_MASKS[raceToken],
        classBit=CLASS_MASKS[classToken], active=active,
        completed=copySet(QuestBeaconHistory and QuestBeaconHistory.completed),
        progressedPast=progressedPast, progressionError=progressionError,
        lowLevel=QuestBeacon.Config:Get("availability.lowLevel") and true or false,
        highLevel=QuestBeacon.Config:Get("availability.highLevel") and true or false,
        event=QuestBeacon.Config:Get("availability.event") and true or false, skillRanks={}}
end

function Availability:GetSkillRank(context, skillID)
    if context.skillRanks[skillID] ~= nil then return context.skillRanks[skillID] or nil end
    local rank = nil
    if C_SpellBook and type(C_SpellBook.GetSkillLineRank) == "function" then
        rank = tonumber(C_SpellBook.GetSkillLineRank(skillID))
    end
    context.skillRanks[skillID] = rank or false
    return rank
end

function Availability:IsCandidateAvailable(candidate, context)
    if context.active[candidate.id] or context.completed[candidate.id] or
       context.progressedPast[candidate.id] then return false end
    if candidate.minLevel > context.level and
       (not context.highLevel or candidate.minLevel > context.level + 3) then return false end
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
            if context.completed[candidate.prerequisites[index]] then satisfied = true end
        end
        if not satisfied then return false end
    end
    return true
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
