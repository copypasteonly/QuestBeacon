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

Pins.worldPins = {}
Pins.minimapPins = {}
Pins.lastAreaID = nil

local RACE_MASKS = {HUMAN=1, ORC=2, DWARF=4, NIGHTELF=8, SCOURGE=16, TAUREN=32, GNOME=64, TROLL=128}
local CLASS_MASKS = {WARRIOR=1, PALADIN=2, HUNTER=4, ROGUE=8, PRIEST=16, SHAMAN=64, MAGE=128, WARLOCK=256, DRUID=1024}

local function hasMask(mask, bit)
    if not mask or mask == 0 or not bit then return true end
    return math.mod(math.floor(mask / bit), 2) == 1
end

local function activeSet()
    local result = {}
    local quests = QuestBeacon.QuestService:GetActiveQuests()
    local index
    for index = 1, table.getn(quests) do result[quests[index].id] = true end
    return result
end

function Pins:IsAvailable(row, active)
    if active[row.questID] or QuestBeacon.QuestHistory:IsComplete(row.questID) then return false end
    local level = tonumber(UnitLevel("player")) or 0
    if row.minLevel > level and (not QuestBeacon.Config:Get("availability.highLevel") or row.minLevel > level + 3) then return false end
    if row.level < level - 4 and not QuestBeacon.Config:Get("availability.lowLevel") then return false end
    if row.eventID and not QuestBeacon.Config:Get("availability.event") then return false end
    local localizedRace, raceToken = UnitRace("player")
    local localizedClass, classToken = UnitClass("player")
    if not hasMask(row.raceMask, RACE_MASKS[raceToken]) or not hasMask(row.classMask, CLASS_MASKS[classToken]) then return false end
    if row.skillID then
        if not C_SpellBook or type(C_SpellBook.GetSkillLineRank) ~= "function" then return false end
        local rank = C_SpellBook.GetSkillLineRank(row.skillID)
        if not tonumber(rank) or tonumber(rank) <= 0 then return false end
    end
    local prerequisites = QuestBeacon.DB:GetQuestPrerequisites(row.questID)
    if prerequisites and table.getn(prerequisites) > 0 then
        local satisfied = false
        local index
        for index = 1, table.getn(prerequisites) do
            if QuestBeacon.QuestHistory:IsComplete(prerequisites[index]) then satisfied = true end
        end
        if not satisfied then return false end
    end
    return true
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
    return {role=role, texture=texture, kind=cluster.kind, entryID=cluster.entryID,
        clusterID=cluster.clusterID, areaID=cluster.areaID, mappedAreaID=cluster.mappedAreaID,
        mapID=cluster.mapID, x=cluster.x, y=cluster.y, pointCount=cluster.pointCount,
        radius=cluster.radius, isNoise=cluster.isNoise, conversionStatus=cluster.conversionStatus,
        quest=quest, objective=objective, sourceType=sourceType,
        associations={{questID=quest.id, title=quest.title, text=objective and objective.text or role}}}
end

function Pins:AddObjectivePins(result, seen, quest, objective)
    if objective.complete or not objective.entryID then return end
    local sources = {}
    if objective.kind == "monster" or objective.kind == "object" then
        table.insert(sources, {kind=objective.kind == "object" and 2 or 1, entryID=objective.entryID, sourceType="entity"})
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
                local role = objective.kind == "item" and "itemSources" or "objectives"
                local texture = objective.kind == "monster" and "cluster_mob" or "cluster_item"
                addPin(result, seen, clusterPin(quest, objective, clusters[clusterIndex], role, texture, source.sourceType))
            end
        end
    end
end

function Pins:AddEnderPins(result, seen, quest)
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
                    local objective = {index=9999, kind="turnin", entryID=relation.sourceID,
                        text=quest.complete and "Quest turn-in" or "Possible turn-in"}
                    addPin(result, seen, clusterPin(quest, objective, clusters[clusterIndex], "turnIns", "complete", "turnin"))
                end
            end
        end
    end
end

function Pins:AddAvailablePins(result, seen, mapID, active)
    local rows = QuestBeacon.DB:GetQuestStarterClustersForMap(mapID)
    if not rows then return end
    local index
    for index = 1, table.getn(rows) do
        local row = rows[index]
        if self:IsAvailable(row, active) then
            local quest = {id=row.questID, title=row.title or ("Quest " .. row.questID), level=row.level}
            local objective = {index=9999, kind="available", entryID=row.entryID, text="Available quest"}
            addPin(result, seen, clusterPin(quest, objective, row, "available", "available", "available"))
        end
    end
end

function Pins:Rebuild(areaID, destination)
    local result, seen = {}, {}
    local active = activeSet()
    local quests = QuestBeacon.QuestService:GetActiveQuests()
    local index
    for index = 1, table.getn(quests) do
        local quest = quests[index]
        local objectiveIndex
        for objectiveIndex = 1, table.getn(quest.objectives) do self:AddObjectivePins(result, seen, quest, quest.objectives[objectiveIndex]) end
        self:AddEnderPins(result, seen, quest)
    end
    local area = areaID and QuestBeacon.DB:GetArea(areaID) or nil
    if area then self:AddAvailablePins(result, seen, area.mapID, active) end
    table.sort(result, function(a,b)
        if a.quest.id ~= b.quest.id then return a.quest.id < b.quest.id end
        if a.role ~= b.role then return a.role < b.role end
        if a.entryID ~= b.entryID then return a.entryID < b.entryID end
        return (a.clusterID or 0) < (b.clusterID or 0)
    end)
    if destination == "world" then self.worldPins = result
    elseif destination == "minimap" then self.minimapPins = result
    else self.worldPins = result self.minimapPins = result end
    self.lastAreaID = areaID
    return result
end

function Pins:GetWorldMapPins() return self.worldPins end
function Pins:GetMinimapPins() return self.minimapPins end

function Pins:SelectPin(pin)
    return QuestBeacon.Navigation:SelectPinTarget(pin)
end
