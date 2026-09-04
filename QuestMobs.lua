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

QuestBeacon.QuestMobIndex = QuestBeacon.QuestMobIndex or {}
local Index = QuestBeacon.QuestMobIndex

Index.questRevision = -1
Index.indexRevision = 0
Index.creatures = {}
Index.pendingItems = {}
Index.pendingHead = 1
Index.itemOwners = {}
Index.listeners = {}
Index.stats = {rebuilds=0, itemsExpanded=0}

-- Killing a vendor never advances a collect objective, and an item-use target is
-- something the quest item is used on rather than looted from, so neither belongs
-- in a "this mob is worth killing" index.
local KILLABLE_SOURCES = {drop=true, container=true, reference_loot=true}

local function addEntry(creatures, creatureID, entry)
    local id = tonumber(creatureID)
    if not id or id <= 0 then return end
    local list = creatures[id]
    if not list then list = {} creatures[id] = list end
    table.insert(list, entry)
end

function Index:RegisterListener(owner, callback)
    if owner and type(callback) == "function" then table.insert(self.listeners, {owner=owner, callback=callback}) end
end

function Index:Notify()
    local index
    for index = 1, table.getn(self.listeners) do
        pcall(self.listeners[index].callback, self.listeners[index].owner, self.indexRevision)
    end
end

function Index:Advance()
    self.indexRevision = self.indexRevision + 1
    self:Notify()
end

function Index:GetIndexRevision()
    return self.indexRevision
end

function Index:GetEntries(creatureID)
    local id = tonumber(creatureID)
    if not id then return nil end
    return self.creatures[id]
end

function Index:IsQuestMob(creatureID)
    local entries = self:GetEntries(creatureID)
    return entries ~= nil and table.getn(entries) > 0
end

function Index:QueueItem(itemID, owner)
    local id = tonumber(itemID)
    if not id or id <= 0 then return end
    local owners = self.itemOwners[id]
    if not owners then
        owners = {}
        self.itemOwners[id] = owners
        table.insert(self.pendingItems, id)
    end
    table.insert(owners, owner)
end

function Index:AddQuest(quest)
    local objectives = quest.objectives or {}
    local objectiveIndex
    for objectiveIndex = 1, table.getn(objectives) do
        local objective = objectives[objectiveIndex]
        if objective and not objective.complete and objective.entryID then
            local owner = {questID=quest.id, title=quest.title,
                objectiveIndex=objective.index or objectiveIndex,
                text=objective.text, kind=objective.kind}
            if objective.kind == "monster" then
                owner.via = "kill"
                addEntry(self.creatures, objective.entryID, owner)
            elseif objective.kind == "item" then
                owner.via = "drop"
                owner.itemID = objective.entryID
                self:QueueItem(objective.entryID, owner)
            end
        end
    end
end

function Index:Rebuild(revision)
    self.creatures = {}
    self.pendingItems = {}
    self.pendingHead = 1
    self.itemOwners = {}
    self.questRevision = revision
    self.stats.rebuilds = self.stats.rebuilds + 1
    local quests = {}
    if QuestBeacon.QuestService and QuestBeacon.QuestService.GetActiveQuests then
        quests = QuestBeacon.QuestService:GetActiveQuests() or {}
    end
    local questIndex
    for questIndex = 1, table.getn(quests) do
        local quest = quests[questIndex]
        if quest and not quest.complete and not quest.pendingData then
            self:AddQuest(quest)
        end
    end
    self:Advance()
    self:ScheduleExpansion()
end

function Index:EnsureCurrent()
    local revision = 0
    if QuestBeacon.QuestService and QuestBeacon.QuestService.GetRevision then
        revision = QuestBeacon.QuestService:GetRevision() or 0
    end
    if revision == self.questRevision then return false end
    self:Rebuild(revision)
    return true
end

function Index:HasPendingItems()
    return self.pendingHead <= table.getn(self.pendingItems)
end

function Index:ScheduleExpansion()
    if not self:HasPendingItems() then return end
    if not QuestBeacon.Scheduler or type(QuestBeacon.Scheduler.Enqueue) ~= "function" then return end
    QuestBeacon.Scheduler:Enqueue(function() QuestBeacon.QuestMobIndex:ExpandNextItem() end,
        "quest mob item sources", "questmob-item-sources")
end

-- Monster objectives resolve with no database work at all; only the collect-item
-- objectives need the source walk, so they are drained one item per scheduler slice
-- instead of stalling the frame that the quest log changed on.
function Index:ExpandNextItem()
    if not self:HasPendingItems() then return false end
    local itemID = self.pendingItems[self.pendingHead]
    self.pendingHead = self.pendingHead + 1
    local owners = self.itemOwners[itemID] or {}
    local sources = {}
    if QuestBeacon.Navigation and type(QuestBeacon.Navigation.CollectItemSources) == "function" then
        sources = QuestBeacon.Navigation:CollectItemSources(itemID, {}) or {}
    end
    local monsterKind = QuestBeacon.DB and QuestBeacon.DB.KIND_MONSTER or 1
    local sourceIndex
    for sourceIndex = 1, table.getn(sources) do
        local source = sources[sourceIndex]
        if source and source.kind == monsterKind and KILLABLE_SOURCES[source.sourceType] then
            local ownerIndex
            for ownerIndex = 1, table.getn(owners) do
                addEntry(self.creatures, source.entryID, owners[ownerIndex])
            end
        end
    end
    self.stats.itemsExpanded = self.stats.itemsExpanded + 1
    self:Advance()
    self:ScheduleExpansion()
    return true
end

function Index:GetStats()
    return self.stats
end

QuestBeacon.QuestMobMarkers = QuestBeacon.QuestMobMarkers or {}
local Markers = QuestBeacon.QuestMobMarkers

Markers.plates = {}
Markers.initialized = false

local ICON_TEXTURE = "Interface\\AddOns\\QuestBeacon\\img\\complete"
local TARGET_ICON_SIZE = 16
local TOOLTIP_ICON_SIZE = 14
local PLATE_ICON_SIZE = 16

-- UnitGUID raises on a token the client does not know, unlike modern clients that
-- return nil, so every lookup goes through pcall.
local function safeUnitGUID(unitToken)
    if type(UnitGUID) ~= "function" then return nil end
    local ok, guid = pcall(UnitGUID, unitToken)
    if not ok then return nil end
    return guid
end

function Markers:CreatureIDForGUID(guid)
    if not guid then return nil end
    if type(C_CreatureInfo) ~= "table" or type(C_CreatureInfo.GetCreatureID) ~= "function" then return nil end
    local raw = C_CreatureInfo.GetCreatureID(guid)
    local creatureID = tonumber(raw)
    if not creatureID or creatureID <= 0 then return nil end
    return creatureID
end

function Markers:CreatureIDForUnit(unitToken)
    return self:CreatureIDForGUID(safeUnitGUID(unitToken))
end

function Markers:Enabled(key)
    if not QuestBeacon.Config then return false end
    return QuestBeacon.Config:Get("questMobs." .. key) and true or false
end

function Markers:StyleIcon(texture, size)
    texture:SetTexture(ICON_TEXTURE)
    texture:SetVertexColor(1, 0.8, 0, 1)
    texture:SetWidth(size)
    texture:SetHeight(size)
end

function Markers:ResolveTargetNameRegion()
    if self.targetNameRegion then return self.targetNameRegion end
    local region
    if type(TargetFrame) == "table" and TargetFrame.name then
        region = TargetFrame.name
    elseif type(getglobal) == "function" then
        region = getglobal("TargetName")
    end
    self.targetNameRegion = region
    return region
end

function Markers:EnsureTooltipIcon()
    if self.tooltipIcon then return self.tooltipIcon end
    if type(GameTooltip) ~= "table" or type(GameTooltip.CreateTexture) ~= "function" then return nil end
    local icon = GameTooltip:CreateTexture(nil, "OVERLAY")
    self:StyleIcon(icon, TOOLTIP_ICON_SIZE)
    icon:Hide()
    self.tooltipIcon = icon
    return icon
end

function Markers:ClearTooltipMarker()
    self.tooltipCreatureID = nil
    if self.tooltipIcon then self.tooltipIcon:Hide() end
end

function Markers:EnsureTargetIcon()
    if self.targetIcon then return self.targetIcon end
    if type(TargetFrame) ~= "table" or type(TargetFrame.CreateTexture) ~= "function" then return nil end
    local icon = TargetFrame:CreateTexture(nil, "OVERLAY")
    self:StyleIcon(icon, TARGET_ICON_SIZE)
    icon:Hide()
    self.targetIcon = icon
    return icon
end

-- Anchors beside the last glyph of a name. A centered FontString spans its whole
-- frame, so its right edge sits nowhere near the text; step out from the center by
-- half the rendered width instead. The width changes with every name, so callers
-- re-anchor on each update rather than once at creation.
function Markers:AnchorIconToText(icon, region, gap)
    if not region then return false end
    if type(icon.ClearAllPoints) == "function" then icon:ClearAllPoints() end
    if type(region.GetJustifyH) == "function" and region:GetJustifyH() == "CENTER"
        and type(region.GetStringWidth) == "function" then
        local width = tonumber(region:GetStringWidth()) or 0
        icon:SetPoint("LEFT", region, "CENTER", (width / 2) + gap, 0)
    else
        icon:SetPoint("LEFT", region, "RIGHT", gap, 0)
    end
    return true
end

function Markers:AnchorTargetIcon(icon)
    if self:AnchorIconToText(icon, self:ResolveTargetNameRegion(), 3) then return end
    if type(icon.ClearAllPoints) == "function" then icon:ClearAllPoints() end
    if type(TargetFrame) == "table" then
        icon:SetPoint("TOPRIGHT", TargetFrame, "TOPRIGHT", -10, -18)
    end
end

function Markers:UpdateTargetFrame()
    local icon = self.targetIcon
    if not self:Enabled("target") then
        if icon then icon:Hide() end
        return
    end
    local exists = type(UnitExists) == "function" and UnitExists("target")
    local creatureID = exists and self:CreatureIDForUnit("target") or nil
    if not creatureID or not QuestBeacon.QuestMobIndex:IsQuestMob(creatureID) then
        if icon then icon:Hide() end
        return
    end
    icon = self:EnsureTargetIcon()
    if not icon then return end
    self:AnchorTargetIcon(icon)
    icon:Show()
end

function Markers:OnTooltipSetUnit()
    if not self:Enabled("tooltip") then self:ClearTooltipMarker() return end
    if type(GameTooltip) ~= "table" or type(GameTooltip.GetUnitGUID) ~= "function" then
        self:ClearTooltipMarker()
        return
    end
    local unitName, guid = GameTooltip:GetUnitGUID()
    local creatureID = self:CreatureIDForGUID(guid)
    if not creatureID then self:ClearTooltipMarker() return end
    local entries = QuestBeacon.QuestMobIndex:GetEntries(creatureID)
    if not entries or table.getn(entries) == 0 then self:ClearTooltipMarker() return end
    if self.tooltipCreatureID == creatureID then return end
    local line = type(getglobal) == "function" and getglobal("GameTooltipTextLeft1") or nil
    local icon = self:EnsureTooltipIcon()
    if icon and self:AnchorIconToText(icon, line, 3) then icon:Show() end
    self.tooltipCreatureID = creatureID
    local index
    for index = 1, table.getn(entries) do
        local entry = entries[index]
        GameTooltip:AddLine(tostring(entry.title or "Quest"), 1, 0.82, 0)
        if entry.text and entry.text ~= "" then
            GameTooltip:AddLine(tostring(entry.text), 0.85, 0.85, 0.85)
        end
    end
end

function Markers:InstallTooltipHook()
    if self.tooltipHooked then return true end
    if type(GameTooltip) ~= "table" then return false end
    local handler = function() QuestBeacon.QuestMobMarkers:OnTooltipSetUnit() end
    -- OnTooltipSetUnit is a ClassicAPI backport that covers world mouseover as well as
    -- SetUnit. A client without it rejects the unknown script type, so the install is
    -- probed and falls back to chaining OnShow.
    if type(GameTooltip.HookScript) == "function" then
        if pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", handler) then
            local clearHandler = function() QuestBeacon.QuestMobMarkers:ClearTooltipMarker() end
            pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipCleared", clearHandler)
            pcall(GameTooltip.HookScript, GameTooltip, "OnHide", clearHandler)
            self.tooltipHooked = true
            return true
        end
    end
    if type(GameTooltip.SetScript) ~= "function" then return false end
    local previous = type(GameTooltip.GetScript) == "function" and GameTooltip:GetScript("OnShow") or nil
    GameTooltip:SetScript("OnShow", function()
        if previous then previous() end
        handler()
    end)
    self.tooltipHooked = true
    return true
end

function Markers:HasNamePlateAPI()
    if type(C_NamePlate) ~= "table" then return false end
    if type(C_NamePlate.GetNamePlateForUnit) ~= "function" then return false end
    if type(UnitGUID) ~= "function" then return false end
    if type(C_CreatureInfo) ~= "table" then return false end
    return self.namePlateEvents and true or false
end

-- Vanilla plates lay their regions out as border, glow, name, level, level icon and
-- raid icon. Taking the first FontString rather than trusting index three keeps this
-- working when a reskin inserts a texture ahead of the name.
function Markers:PlateNameRegion(plate)
    if plate.questBeaconNameRegion then return plate.questBeaconNameRegion end
    local region = plate.name
    if not region and type(plate.GetRegions) == "function" then
        local regions = {plate:GetRegions()}
        local index
        for index = 1, table.getn(regions) do
            local candidate = regions[index]
            if candidate and type(candidate.GetObjectType) == "function"
                and candidate:GetObjectType() == "FontString" then
                region = candidate
                break
            end
        end
    end
    plate.questBeaconNameRegion = region
    return region
end

function Markers:PlateIcon(plate)
    if plate.questBeaconMobIcon then return plate.questBeaconMobIcon end
    if type(plate.CreateTexture) ~= "function" then return nil end
    local icon = plate:CreateTexture(nil, "OVERLAY")
    self:StyleIcon(icon, PLATE_ICON_SIZE)
    icon:Hide()
    plate.questBeaconMobIcon = icon
    return icon
end

function Markers:UpdatePlateIcon(token, visible)
    if type(C_NamePlate) ~= "table" or type(C_NamePlate.GetNamePlateForUnit) ~= "function" then return end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, token)
    if not ok or not plate then return end
    local icon = self:PlateIcon(plate)
    if not icon then return end
    if not visible then icon:Hide() return end
    if not self:AnchorIconToText(icon, self:PlateNameRegion(plate), 3) then
        if type(icon.ClearAllPoints) == "function" then icon:ClearAllPoints() end
        icon:SetPoint("LEFT", plate, "RIGHT", 4, 0)
    end
    icon:Show()
end

function Markers:UpdatePlate(token)
    local record = self.plates[token]
    if not record then return end
    local wanted = self:Enabled("nameplates") and record.creatureID
        and QuestBeacon.QuestMobIndex:IsQuestMob(record.creatureID)
    self:UpdatePlateIcon(token, wanted and true or false)
end

-- The texture is built while the plate is still being created, so a plate that is
-- about to show already carries its icon instead of gaining one a frame later.
function Markers:OnNamePlateCreated(plate)
    if type(plate) ~= "table" then return end
    self:PlateIcon(plate)
end

function Markers:OnNamePlateAdded(token)
    if not token then return end
    local guid = safeUnitGUID(token)
    self.plates[token] = {guid=guid, creatureID=self:CreatureIDForGUID(guid)}
    self:UpdatePlate(token)
end

function Markers:OnNamePlateRemoved(token)
    if not token then return end
    self:UpdatePlateIcon(token, false)
    self.plates[token] = nil
end

function Markers:RefreshPlates()
    local token
    for token in pairs(self.plates) do
        self:UpdatePlate(token)
    end
end

function Markers:RefreshAll()
    self:UpdateTargetFrame()
    self:RefreshPlates()
end

function Markers:Refresh()
    QuestBeacon.QuestMobIndex:EnsureCurrent()
    self:RefreshAll()
end

function Markers:OnEvent(eventName, first)
    if eventName == "PLAYER_TARGET_CHANGED" then
        self:UpdateTargetFrame()
    elseif eventName == "NAME_PLATE_CREATED" then
        self:OnNamePlateCreated(first)
    elseif eventName == "PLAYER_ENTERING_WORLD" then
        self:RefreshAll()
    elseif eventName == "NAME_PLATE_UNIT_ADDED" then
        self:OnNamePlateAdded(first)
    elseif eventName == "NAME_PLATE_UNIT_REMOVED" then
        self:OnNamePlateRemoved(first)
    end
end

function Markers:RegisterEvents(frame)
    if type(frame.RegisterEvent) ~= "function" then return end
    frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    -- 1.12 raises on an unrecognised event name and the nameplate events exist only
    -- while ClassicAPI reserves them, so registering doubles as the capability probe.
    pcall(frame.RegisterEvent, frame, "NAME_PLATE_CREATED")
    local added = pcall(frame.RegisterEvent, frame, "NAME_PLATE_UNIT_ADDED")
    local removed = pcall(frame.RegisterEvent, frame, "NAME_PLATE_UNIT_REMOVED")
    self.namePlateEvents = added and removed
end

function Markers:Initialize()
    if self.initialized then return end
    self.initialized = true
    self:InstallTooltipHook()
    local frame = CreateFrame("Frame", "QuestBeaconQuestMobFrame")
    self.frame = frame
    self:RegisterEvents(frame)
    if type(frame.SetScript) == "function" then
        frame:SetScript("OnEvent", function()
            QuestBeacon.QuestMobMarkers:OnEvent(event, arg1)
        end)
    end
    QuestBeacon.QuestMobIndex:RegisterListener(self, function(owner) owner:RefreshAll() end)
    if QuestBeacon.Config then
        QuestBeacon.Config:RegisterListener(self, function(owner, path)
            if path == "reset" or string.find(path or "", "^questMobs") then owner:RefreshAll() end
        end)
    end
    QuestBeacon.QuestMobIndex:EnsureCurrent()
    self:RefreshAll()
end
