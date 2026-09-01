--[[
QuestBeacon uses the pfQuest quest-pin textures in img/ under the MIT License.

Copyright (c) 2017-2021 Eric Mauser (Shagu)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

QuestBeacon.PinService = QuestBeacon.PinService or {}
local Pins = QuestBeacon.PinService

Pins.plans = {}
Pins.running = {}
Pins.listeners = {}
Pins.revision = 1
Pins.nextIdentity = 0
Pins.worldAreaID = nil
Pins.minimapAreaID = nil
Pins.stats = {requests=0, publishes=0, cancelled=0, lastAreaID=0, lastPinCount=0}

local function positiveInteger(value)
    local number = tonumber(value)
    if not number or number <= 0 or math.floor(number) ~= number then return nil end
    return number
end

local function areaMatches(cluster, areaID)
    return tonumber(cluster.mappedAreaID or cluster.areaID) == areaID
end

local function addPin(result, seen, pin)
    if not pin.x or not pin.y or pin.mapID == nil then return end
    local key = pin.role .. ":" .. tostring(pin.mapID) .. ":" .. string.format("%.2f:%.2f", pin.x, pin.y)
    local existing = seen[key]
    if existing then
        table.insert(existing.associations, pin.associations[1])
        return
    end
    seen[key] = pin
    table.insert(result, pin)
end

local function clusterPin(quest, objective, cluster, role, texture, sourceType)
    return {available=true, role=role, texture=texture, kind=cluster.kind, entryID=cluster.entryID,
        clusterID=cluster.clusterID, areaID=cluster.areaID, mappedAreaID=cluster.mappedAreaID,
        mapID=cluster.mapID, x=cluster.x, y=cluster.y, pointCount=cluster.pointCount,
        radius=cluster.radius, isNoise=cluster.isNoise, conversionStatus=cluster.conversionStatus,
        quest=quest, objective=objective, sourceType=sourceType,
        associations={{questID=quest.id, title=quest.title, text=objective and objective.text or role}}}
end

function Pins:RegisterListener(owner, callback)
    if owner and type(callback) == "function" then table.insert(self.listeners, {owner=owner,callback=callback}) end
end

function Pins:Notify(areaID, plan)
    local index
    for index = 1, table.getn(self.listeners) do
        local listener = self.listeners[index]
        pcall(listener.callback, listener.owner, areaID, plan)
    end
end

function Pins:GetRevision() return self.revision end
function Pins:GetStats() return self.stats end

function Pins:Invalidate(reason)
    self.revision = self.revision + 1
    local areaID, state
    for areaID, state in pairs(self.running) do
        state.cancelled = true
        self.stats.cancelled = self.stats.cancelled + 1
    end
    self.running = {}
    self.stats.lastInvalidation = reason or "unknown"
end

function Pins:PlanKey(areaID, availability)
    local questRevision = QuestBeacon.QuestService.GetRevision and QuestBeacon.QuestService:GetRevision() or 0
    local historyRevision = QuestBeacon.QuestHistory.GetRevision and QuestBeacon.QuestHistory:GetRevision() or 0
    local availabilityRevision = availability and availability.revision or 0
    return table.concat({tostring(areaID), tostring(self.revision), tostring(questRevision),
        tostring(historyRevision), tostring(availabilityRevision)}, ":")
end

function Pins:AddObjectivePins(result, seen, areaID, quest, objective)
    if objective.complete or not objective.entryID then return end
    local sources = {}
    if objective.kind == "monster" or objective.kind == "object" then
        table.insert(sources, {kind=objective.kind == "object" and 2 or 1,
            entryID=objective.entryID, sourceType="entity"})
    elseif objective.kind == "item" then
        sources = QuestBeacon.Navigation:CollectItemSources(objective.entryID, {})
    end
    local sourceIndex
    for sourceIndex = 1, table.getn(sources) do
        local source = sources[sourceIndex]
        local clusters = QuestBeacon.DB:GetEntityClusters(source.kind, source.entryID)
        if clusters then
            local clusterIndex
            for clusterIndex = 1, table.getn(clusters) do
                local cluster = clusters[clusterIndex]
                if areaMatches(cluster, areaID) then
                    local role = objective.kind == "item" and "itemSources" or "objectives"
                    local texture = objective.kind == "monster" and "cluster_mob" or "cluster_item"
                    addPin(result, seen, clusterPin(quest, objective, cluster, role, texture, source.sourceType))
                end
            end
        end
    end
end

function Pins:AddEnderPins(result, seen, areaID, quest)
    if not quest.complete then return end
    local relations = QuestBeacon.DB:GetQuestEnders(quest.id)
    if not relations then return end
    local index
    for index = 1, table.getn(relations) do
        local relation = relations[index]
        if relation.sourceKind == 1 or relation.sourceKind == 2 then
            local clusters = QuestBeacon.DB:GetEntityClusters(relation.sourceKind, relation.sourceID)
            if clusters then
                local clusterIndex
                for clusterIndex = 1, table.getn(clusters) do
                    local cluster = clusters[clusterIndex]
                    if areaMatches(cluster, areaID) then
                        local objective = {index=9999, kind="turnin", entryID=relation.sourceID,
                            text="Quest turn-in"}
                        addPin(result, seen, clusterPin(quest, objective, cluster, "turnIns", "complete", "turnin"))
                    end
                end
            end
        end
    end
end

function Pins:AddAvailablePin(result, seen, row)
    local quest = {id=row.questID, title=row.title or ("Quest " .. row.questID), level=row.level}
    local objective = {index=9999, kind="available", entryID=row.entryID, text="Available quest"}
    addPin(result, seen, clusterPin(quest, objective, row, "available", "available", "available"))
end

function Pins:Publish(state)
    if self.running[state.areaID] ~= state or state.cancelled then return end
    table.sort(state.pins, function(a,b)
        if a.quest.id ~= b.quest.id then return a.quest.id < b.quest.id end
        if a.role ~= b.role then return a.role < b.role end
        if a.entryID ~= b.entryID then return a.entryID < b.entryID end
        return (a.clusterID or 0) < (b.clusterID or 0)
    end)
    self.nextIdentity = self.nextIdentity + 1
    local plan = {areaID=state.areaID, key=state.key, identity=self.nextIdentity,
        revision=self.revision, pins=state.pins}
    self.plans[state.areaID] = plan
    self.running[state.areaID] = nil
    self.stats.publishes = self.stats.publishes + 1
    self.stats.lastAreaID = state.areaID
    self.stats.lastPinCount = table.getn(plan.pins)
    self:Notify(state.areaID, plan)
end

function Pins:RequestPlan(areaID)
    local id = positiveInteger(areaID)
    if not id then return false, "invalid area ID" end
    QuestBeacon.AvailabilityService:RequestArea(id)
    local availability = QuestBeacon.AvailabilityService:GetSnapshot(id)
    local key = self:PlanKey(id, availability)
    if self.plans[id] and self.plans[id].key == key then return true, nil end
    if self.running[id] and self.running[id].key == key then return true, nil end
    if self.running[id] then
        self.running[id].cancelled = true
        self.stats.cancelled = self.stats.cancelled + 1
    end
    local tasks = {}
    local quests = QuestBeacon.QuestService:GetActiveQuests()
    local activeQuestIDs = {}
    local questIndex, objectiveIndex
    for questIndex = 1, table.getn(quests) do
        local quest = quests[questIndex]
        activeQuestIDs[quest.id] = true
        for objectiveIndex = 1, table.getn(quest.objectives) do
            table.insert(tasks, {kind="objective", quest=quest, objective=quest.objectives[objectiveIndex]})
        end
        table.insert(tasks, {kind="ender", quest=quest})
    end
    if availability then
        local rows = QuestBeacon.DB:GetQuestStarterClustersForArea(id)
        local rowIndex
        for rowIndex = 1, table.getn(rows or {}) do
            if availability.available[rows[rowIndex].questID] and not activeQuestIDs[rows[rowIndex].questID] then
                table.insert(tasks, {kind="available", row=rows[rowIndex]})
            end
        end
    end
    local state = {areaID=id, key=key, tasks=tasks, position=1, pins={}, seen={}, cancelled=false}
    self.running[id] = state
    self.stats.requests = self.stats.requests + 1
    local function step()
        if Pins.running[id] ~= state or state.cancelled then return end
        local count = 0
        while state.position <= table.getn(state.tasks) and count < 12 do
            local task = state.tasks[state.position]
            state.position = state.position + 1
            if task.kind == "objective" then
                Pins:AddObjectivePins(state.pins, state.seen, id, task.quest, task.objective)
            elseif task.kind == "ender" then
                Pins:AddEnderPins(state.pins, state.seen, id, task.quest)
            else
                Pins:AddAvailablePin(state.pins, state.seen, task.row)
            end
            count = count + 1
        end
        if state.position <= table.getn(state.tasks) then
            QuestBeacon.Scheduler:Enqueue(step, "pin plan", "pin-plan:" .. tostring(id))
        else
            Pins:Publish(state)
        end
    end
    QuestBeacon.Scheduler:Enqueue(step, "pin plan", "pin-plan:" .. tostring(id))
    return true, nil
end

function Pins:GetPlan(areaID)
    local id = positiveInteger(areaID)
    return id and self.plans[id] or nil
end

function Pins:Rebuild(areaID, destination)
    local id = positiveInteger(areaID)
    if not id then return {} end
    if destination == "world" then self.worldAreaID = id
    elseif destination == "minimap" then self.minimapAreaID = id end
    self:RequestPlan(id)
    local plan = self:GetPlan(id)
    return plan and plan.pins or {}
end

function Pins:GetWorldMapPins()
    local plan = self.worldAreaID and self:GetPlan(self.worldAreaID) or nil
    return plan and plan.pins or {}
end

function Pins:GetMinimapPins()
    local plan = self.minimapAreaID and self:GetPlan(self.minimapAreaID) or nil
    return plan and plan.pins or {}
end

function Pins:SelectPin(pin)
    return QuestBeacon.Navigation:SelectPinTarget(pin)
end

QuestBeacon.AvailabilityService:RegisterListener(Pins, function(owner, areaID)
    owner:Invalidate("availability")
    owner:RequestPlan(areaID)
end)
