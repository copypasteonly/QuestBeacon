--[[
pfQuest tracker artwork license

MIT License

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

QuestBeacon.Tracker = QuestBeacon.Tracker or {}
local Tracker = QuestBeacon.Tracker

Tracker.questRows = {}
Tracker.objectiveRows = {}

local function setFontSize(font, size)
    if font and font.GetFont and font.SetFont then
        local path, oldSize, flags = font:GetFont()
        if path then font:SetFont(path, size, flags) end
    end
end

local function candidateDetails(questID, playerAreaID)
    local candidates = QuestBeacon.Navigation:GetCandidates()
    local distance = 999999999999
    local currentArea = false
    local index
    for index = 1, table.getn(candidates) do
        local candidate = candidates[index]
        if candidate.quest and candidate.quest.id == questID then
            if candidate.distanceSquared and candidate.distanceSquared < distance then distance = candidate.distanceSquared end
            if playerAreaID and (candidate.areaID == playerAreaID or candidate.mappedAreaID == playerAreaID) then currentArea = true end
        end
    end
    return distance, currentArea
end

local function objectiveCounts(objective)
    if objective.complete then return 1, 1 end
    if objective.kind == "item" and objective.currentCount ~= nil and objective.requiredCount then
        return math.min(objective.currentCount, objective.requiredCount), objective.requiredCount
    end
    if not objective.progressUnavailable and objective.text then
        local startPosition, endPosition, current, required = string.find(objective.text, "(%d+)%s*/%s*(%d+)")
        if current and required then return tonumber(current), tonumber(required) end
    end
    return nil, nil
end

function Tracker:GetQuestProgress(quest)
    if quest.complete then return 100 end
    if table.getn(quest.objectives or {}) == 0 then return nil end
    local current, required = 0, 0
    local index
    for index = 1, table.getn(quest.objectives) do
        local objectiveCurrent, objectiveRequired = objectiveCounts(quest.objectives[index])
        if not objectiveCurrent or not objectiveRequired or objectiveRequired <= 0 then return nil end
        current = current + objectiveCurrent
        required = required + objectiveRequired
    end
    if required <= 0 then return nil end
    return math.floor((current * 100 / required) + 0.5)
end

local function before(first, second)
    if first.watched ~= second.watched then return first.watched end
    if first.currentArea ~= second.currentArea then return first.currentArea end
    if QuestBeacon.Config:Get("questSort") == "level" then
        if first.quest.level ~= second.quest.level then return first.quest.level > second.quest.level end
    elseif first.distance ~= second.distance then
        return first.distance < second.distance
    end
    if first.progress ~= second.progress then return first.progress > second.progress end
    local firstTitle = string.lower(tostring(first.quest.title or ""))
    local secondTitle = string.lower(tostring(second.quest.title or ""))
    if firstTitle ~= secondTitle then return firstTitle < secondTitle end
    return first.quest.id < second.quest.id
end

function Tracker:GetSortedQuests()
    local active = QuestBeacon.QuestService:GetActiveQuests()
    local view = QuestBeacon.Config:Get("trackerView")
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    local playerAreaID = player.available and player.areaID or nil
    local rows = {}
    local index
    for index = 1, table.getn(active) do
        local quest = active[index]
        local watched = QuestBeacon.WatchService:IsWatched(quest)
        local distance, currentArea = candidateDetails(quest.id, playerAreaID)
        if view == "all" or (view == "watched" and watched) or (view == "zone" and (watched or currentArea)) then
            table.insert(rows, {quest=quest, watched=watched, distance=distance,
                currentArea=currentArea, progress=self:GetQuestProgress(quest) or -1})
        end
    end
    table.sort(rows, before)
    return rows
end

function Tracker:ObjectiveText(objective)
    if objective.pendingData then return "Loading objective" end
    if objective.kind == "item" and objective.currentCount ~= nil and objective.requiredCount then
        return tostring(objective.currentCount) .. "/" .. tostring(objective.requiredCount) .. "  " .. tostring(objective.text or "")
    end
    if objective.progressUnavailable and (objective.kind == "monster" or objective.kind == "object") then
        return "?/" .. tostring(objective.requiredCount or "?") .. "  " .. tostring(objective.text or "")
    end
    if objective.text and objective.text ~= "" then return objective.text end
    return tostring(objective.kind or "Objective") .. " " .. tostring(objective.entryID or "")
end

function Tracker:ShowControlTooltip(control, title, description)
    if not GameTooltip then return end
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:SetText(title)
    if description then GameTooltip:AddLine(description, 0.8, 0.8, 0.8) end
    GameTooltip:Show()
end

function Tracker:GetQuestRow(index)
    if self.questRows[index] then return self.questRows[index] end
    local row = CreateFrame("Frame", nil, self.content)
    row:SetWidth(300) row:SetHeight(20)
    row.watch = CreateFrame("Button", nil, row)
    row.watch:SetWidth(18) row.watch:SetHeight(18) row.watch:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.watch.texture = row.watch:CreateTexture(nil, "ARTWORK")
    row.watch.texture:SetAllPoints(row.watch)
    row.watch.texture:SetTexture("Interface\\AddOns\\QuestBeacon\\img\\track.tga")
    row.watch:SetScript("OnClick", function() Tracker:ToggleWatch(this.questID) end)
    row.watch:SetScript("OnEnter", function() Tracker:ShowControlTooltip(this, this.watched and "Unwatch quest" or "Watch quest", "Uses the native quest watch when the log index is available.") end)
    row.watch:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    row.title = CreateFrame("Button", nil, row)
    row.title:SetWidth(278) row.title:SetHeight(20) row.title:SetPoint("LEFT", row, "LEFT", 22, 0)
    row.title:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.title.text = row.title:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.title.text:SetAllPoints(row.title) row.title.text:SetJustifyH("LEFT")
    row.title:SetScript("OnClick", function() Tracker:OnQuestClick(this.questID, arg1) end)
    self.questRows[index] = row
    return row
end

function Tracker:GetObjectiveRow(index)
    if self.objectiveRows[index] then return self.objectiveRows[index] end
    local row = CreateFrame("Button", nil, self.content)
    row:SetWidth(278) row:SetHeight(18) row:RegisterForClicks("LeftButtonUp")
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetAllPoints(row) row.text:SetJustifyH("LEFT")
    row:SetScript("OnClick", function() Tracker:Select(this.questID, this.objectiveIndex) end)
    self.objectiveRows[index] = row
    return row
end

function Tracker:Select(questID, objectiveIndex)
    local ok = QuestBeacon.Navigation:SetTrackingMode("quest", questID, objectiveIndex)
    if ok then QuestBeacon.Navigation:AutoResolve(false) end
end

function Tracker:ToggleWatch(questID)
    local quest = QuestBeacon.QuestService:GetQuest(questID)
    if not quest then return end
    local watched = not QuestBeacon.WatchService:IsWatched(quest)
    local ok, reason = QuestBeacon.WatchService:SetWatched(questID, watched)
    if not ok then QuestBeacon:Print("watch failed: " .. tostring(reason)) end
end

function Tracker:WatchAll()
    local active = QuestBeacon.QuestService:GetActiveQuests()
    local failures = 0
    local index
    for index = 1, table.getn(active) do
        local ok, reason = QuestBeacon.WatchService:SetWatched(active[index].id, true)
        if not ok then
            failures = failures + 1
            QuestBeacon:Print("could not watch quest " .. tostring(active[index].id) .. ": " .. tostring(reason))
        end
    end
    return failures
end

function Tracker:IsFolded(questID)
    local folds = QuestBeacon.Config:Get("trackerFolds")
    if folds[questID] == "folded" then return true end
    if folds[questID] == "open" then return false end
    return not QuestBeacon.Config:Get("trackerExpandObjectives")
end

function Tracker:ToggleFold(questID)
    local folds = QuestBeacon.Config:Get("trackerFolds")
    folds[questID] = self:IsFolded(questID) and "open" or "folded"
    QuestBeacon.Config:Set("trackerFolds", folds)
end

function Tracker:OpenQuestLog(questID)
    local quest = QuestBeacon.QuestService:GetQuest(questID)
    if not quest or quest.logOrderUnavailable or not quest.logIndex then return end
    if QuestLogFrame and not QuestLogFrame:IsVisible() then
        if type(ToggleQuestLog) == "function" then ToggleQuestLog() else QuestLogFrame:Show() end
    end
    if type(SelectQuestLogEntry) == "function" then SelectQuestLogEntry(quest.logIndex) end
end

function Tracker:OnQuestClick(questID, button)
    if button == "RightButton" then self:OpenQuestLog(questID) return end
    local control = false
    if type(IsControlKeyDown) == "function" then control = IsControlKeyDown() and true or false end
    if control then
        self:Select(questID, nil)
        local state = QuestBeacon.Navigation:GetState()
        if state and state.target and QuestBeacon.WorldMapPins then
            QuestBeacon.WorldMapPins:OpenArea(state.target.mappedAreaID or state.target.areaID)
        end
    else
        self:ToggleFold(questID)
    end
end

function Tracker:SavePosition()
    local point, relativeTo, relativePoint, x, y = self.frame:GetPoint(1)
    QuestBeacon.Config:Set("trackerPoint", point or "TOPRIGHT")
    QuestBeacon.Config:Set("trackerX", tonumber(x) or -30)
    QuestBeacon.Config:Set("trackerY", tonumber(y) or -180)
end

function Tracker:ApplyPosition()
    local point = QuestBeacon.Config:Get("trackerPoint")
    self.frame:ClearAllPoints()
    self.frame:SetPoint(point, UIParent, point, QuestBeacon.Config:Get("trackerX"), QuestBeacon.Config:Get("trackerY"))
end

function Tracker:QuestTitle(model)
    local quest = model.quest
    local prefix = self:IsFolded(quest.id) and "+ " or "- "
    if QuestBeacon.Config:Get("trackerShowLevels") then prefix = prefix .. "[" .. tostring(quest.level or 0) .. "] " end
    local title = prefix .. tostring(quest.title or ("Quest " .. quest.id))
    if model.progress >= 0 then title = title .. "  " .. tostring(model.progress) .. "%" end
    return title
end

function Tracker:SetDifficultyColor(font, quest)
    if quest.pendingData then font:SetTextColor(0.65, 0.65, 0.65, 1) return end
    if quest.complete then font:SetTextColor(0.2, 1, 0.2, 1) return end
    if type(GetDifficultyColor) == "function" then
        local color = GetDifficultyColor(quest.level or 0)
        if color then font:SetTextColor(color.r or 1, color.g or 0.82, color.b or 0, 1) return end
    end
    font:SetTextColor(1, 0.82, 0, 1)
end

function Tracker:Refresh()
    if not self.frame then return end
    local rows = self:GetSortedQuests()
    local size = QuestBeacon.Config:Get("trackerFontSize")
    local y, questRowIndex, objectiveRowIndex = 0, 0, 0
    local index
    for index = 1, table.getn(rows) do
        local model, quest = rows[index], rows[index].quest
        questRowIndex = questRowIndex + 1
        local row = self:GetQuestRow(questRowIndex)
        row.watch.questID = quest.id row.watch.watched = model.watched
        row:ClearAllPoints() row:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, y)
        row.title.questID = quest.id row.title.text:SetText(self:QuestTitle(model))
        setFontSize(row.title.text, size + 1)
        row.watch.texture:SetVertexColor(model.watched and 0.3 or 0.6, model.watched and 1 or 0.6, model.watched and 0.3 or 0.6)
        row.watch:SetAlpha(model.watched and 1 or 0.35)
        self:SetDifficultyColor(row.title.text, quest)
        row:Show() y = y - (size + 9)
        if not self:IsFolded(quest.id) then
            local objectiveIndex
            for objectiveIndex = 1, table.getn(quest.objectives) do
                local objective = quest.objectives[objectiveIndex]
                objectiveRowIndex = objectiveRowIndex + 1
                local objectiveRow = self:GetObjectiveRow(objectiveRowIndex)
                objectiveRow.questID = quest.id objectiveRow.objectiveIndex = objective.index
                objectiveRow:ClearAllPoints() objectiveRow:SetPoint("TOPLEFT", self.content, "TOPLEFT", 22, y)
                objectiveRow.text:SetText(self:ObjectiveText(objective)) setFontSize(objectiveRow.text, size)
                if objective.complete then objectiveRow.text:SetTextColor(0.35, 0.8, 0.35, 1)
                elseif objective.unresolvedReason then objectiveRow.text:SetTextColor(0.6, 0.6, 0.6, 1)
                elseif objective.progressUnavailable then objectiveRow.text:SetTextColor(0.9, 0.72, 0.4, 1)
                else objectiveRow.text:SetTextColor(0.9, 0.9, 0.9, 1) end
                objectiveRow:Show() y = y - (size + 7)
            end
        end
        y = y - 4
    end
    for index = questRowIndex + 1, table.getn(self.questRows) do self.questRows[index]:Hide() end
    for index = objectiveRowIndex + 1, table.getn(self.objectiveRows) do self.objectiveRows[index]:Hide() end
    self.content:SetHeight(math.max(20, -y)) self.frame:SetHeight(math.max(45, -y + 34))
    self.viewButton:SetAlpha(QuestBeacon.Config:Get("trackerView") == "all" and 1 or 0.55)
    self.sortButton.text:SetText(QuestBeacon.Config:Get("questSort") == "level" and "L" or "N")
    if QuestBeacon.Config:Get("trackerShown") then
        self.frame:Show()
        QuestBeacon.WatchService:HideNativeTracker()
    else
        self.frame:Hide()
        QuestBeacon.WatchService:RestoreNativeTracker()
    end
end

function Tracker:CycleView()
    local view = QuestBeacon.Config:Get("trackerView")
    if view == "all" then view = "watched" elseif view == "watched" then view = "zone" else view = "all" end
    QuestBeacon.Config:Set("trackerView", view)
    QuestBeacon:Print("tracker view: " .. (view == "zone" and "current zone" or view))
end

function Tracker:OnConfigChanged(path)
    if path == "trackerPoint" or path == "trackerX" or path == "trackerY" or path == "reset" then self:ApplyPosition() end
    self:Refresh()
end

local function textureButton(parent, texture, x, callback)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(20) button:SetHeight(20) button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -3)
    button.texture = button:CreateTexture(nil, "ARTWORK") button.texture:SetAllPoints(button)
    button.texture:SetTexture("Interface\\AddOns\\QuestBeacon\\img\\" .. texture)
    button:SetScript("OnClick", callback)
    return button
end

function Tracker:Initialize()
    if self.frame then return end
    local frame = CreateFrame("Frame", "QuestBeaconTrackerFrame", UIParent)
    self.frame = frame
    frame:SetWidth(320) frame:SetHeight(100) frame:SetFrameStrata("HIGH")
    frame:SetMovable(true) frame:SetClampedToScreen(true) frame:EnableMouse(true) frame:RegisterForDrag("LeftButton")
    self.viewButton = textureButton(frame, "tracker_quests.tga", 3, function() Tracker:CycleView() end)
    self.viewButton:SetScript("OnEnter", function() Tracker:ShowControlTooltip(this, "Quest view", "Cycle All, Watched Only, and Current Zone.") end)
    self.viewButton:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    self.sortButton = CreateFrame("Button", nil, frame)
    self.sortButton:SetWidth(20) self.sortButton:SetHeight(20) self.sortButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 27, -3)
    self.sortButton.text = self.sortButton:CreateFontString(nil, "OVERLAY", "GameFontNormal") self.sortButton.text:SetAllPoints(self.sortButton)
    self.sortButton:SetScript("OnClick", function() QuestBeacon.Config:Set("questSort", QuestBeacon.Config:Get("questSort") == "level" and "distance" or "level") end)
    self.sortButton:SetScript("OnEnter", function() Tracker:ShowControlTooltip(this, "Quest sorting", "N sorts nearest first; L sorts by quest level.") end)
    self.sortButton:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    self.settingsButton = textureButton(frame, "tracker_settings.tga", 276, function() QuestBeacon.Settings:Toggle() end)
    self.closeButton = textureButton(frame, "tracker_close.tga", 299, function() QuestBeacon.Config:Set("trackerShown", false) end)
    self.content = CreateFrame("Frame", nil, frame)
    self.content:SetWidth(300) self.content:SetHeight(20) self.content:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -27)
    frame:SetScript("OnDragStart", function()
        if not QuestBeacon.Config:Get("trackerLocked") then this:StartMoving() this.dragging = true end
    end)
    frame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        if this.dragging then this.dragging = nil Tracker:SavePosition() end
    end)
    frame:SetScript("OnUpdate", function() QuestBeacon.WatchService:HideNativeTracker() end)
    self:ApplyPosition()
    QuestBeacon.Config:RegisterListener(self, self.OnConfigChanged)
    self:Refresh()
end
