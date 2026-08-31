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

local function activeCandidateDistance(questID)
    local candidates = QuestBeacon.Navigation:GetCandidates()
    local best = nil
    local index
    for index = 1, table.getn(candidates) do
        local candidate = candidates[index]
        if candidate.quest and candidate.quest.id == questID and (not best or candidate.distanceSquared < best) then
            best = candidate.distanceSquared
        end
    end
    return best
end

local function before(first, second)
    if first.starred ~= second.starred then return first.starred end
    if QuestBeacon.Config:Get("questSort") == "level" then
        if first.quest.level ~= second.quest.level then return first.quest.level > second.quest.level end
    else
        if first.distance ~= second.distance then return first.distance < second.distance end
        if first.quest.level ~= second.quest.level then return first.quest.level > second.quest.level end
    end
    return first.quest.id < second.quest.id
end

function Tracker:GetSortedQuests()
    local active = QuestBeacon.QuestService:GetActiveQuests()
    local starred = QuestBeacon.Config:Get("starredQuests")
    local hidden = QuestBeacon.Config:Get("hiddenQuests")
    local rows = {}
    local index
    for index = 1, table.getn(active) do
        if not hidden[active[index].id] then
            table.insert(rows, {quest=active[index], starred=starred[active[index].id] and true or false,
                distance=activeCandidateDistance(active[index].id) or 999999999999})
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

function Tracker:GetQuestRow(index)
    if self.questRows[index] then return self.questRows[index] end
    local row = CreateFrame("Button", nil, self.content)
    row:SetWidth(300) row:SetHeight(20) row:RegisterForClicks("LeftButtonUp")
    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.title:SetPoint("LEFT", row, "LEFT", 24, 0) row.title:SetWidth(246) row.title:SetJustifyH("LEFT")
    row.star = CreateFrame("Button", nil, row)
    row.star:SetWidth(20) row.star:SetHeight(20) row.star:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.star.text = row.star:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.star.text:SetAllPoints(row.star)
    row.star:SetScript("OnClick", function() Tracker:ToggleStar(this.questID) end)
    row.star:SetScript("OnEnter", function() Tracker:ShowControlTooltip(this, "Prioritize quest", "Starred quests stay at the top.") end)
    row.star:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    row.unwatch = CreateFrame("Button", nil, row)
    row.unwatch:SetWidth(20) row.unwatch:SetHeight(20) row.unwatch:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.unwatch.text = row.unwatch:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.unwatch.text:SetAllPoints(row.unwatch) row.unwatch.text:SetText("x")
    row.unwatch.text:SetTextColor(0.8, 0.35, 0.35, 1)
    row.unwatch:SetScript("OnClick", function() Tracker:SetWatched(this.questID, false) end)
    row.unwatch:SetScript("OnEnter", function() Tracker:ShowControlTooltip(this, "Unwatch quest", "Hide this quest from the tracker.") end)
    row.unwatch:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    row:SetScript("OnClick", function() Tracker:Select(this.questID, nil) end)
    self.questRows[index] = row
    return row
end

function Tracker:ShowControlTooltip(control, title, description)
    if not GameTooltip then return end
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:SetText(title)
    GameTooltip:AddLine(description, 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

function Tracker:GetObjectiveRow(index)
    if self.objectiveRows[index] then return self.objectiveRows[index] end
    local row = CreateFrame("Button", nil, self.content)
    row:SetWidth(286) row:SetHeight(18) row:RegisterForClicks("LeftButtonUp")
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

function Tracker:ToggleStar(questID)
    local starred = QuestBeacon.Config:Get("starredQuests")
    starred[questID] = starred[questID] and nil or true
    QuestBeacon.Config:Set("starredQuests", starred)
end

function Tracker:SetWatched(questID, watched)
    local id = tonumber(questID)
    if not id or id <= 0 or math.floor(id) ~= id then return false end
    local hidden = QuestBeacon.Config:Get("hiddenQuests")
    hidden[id] = watched and nil or true
    QuestBeacon.Config:Set("hiddenQuests", hidden)
    return true
end

function Tracker:IsWatched(questID)
    local hidden = QuestBeacon.Config:Get("hiddenQuests")
    return not hidden[tonumber(questID)]
end

function Tracker:GetHiddenActiveQuests()
    local hidden = QuestBeacon.Config:Get("hiddenQuests")
    local active = QuestBeacon.QuestService:GetActiveQuests()
    local result = {}
    local index
    for index = 1, table.getn(active) do
        if hidden[active[index].id] then table.insert(result, active[index]) end
    end
    return result
end

function Tracker:WatchAll()
    QuestBeacon.Config:Set("hiddenQuests", {})
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
        row.questID = quest.id row.star.questID = quest.id row.unwatch.questID = quest.id
        row:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, y)
        row.title:SetText("[" .. tostring(quest.level or 0) .. "] " .. tostring(quest.title or ("Quest " .. quest.id)))
        row.star.text:SetText(model.starred and "*" or "+")
        if model.starred then row.star.text:SetTextColor(1, 0.82, 0, 1)
        else row.star.text:SetTextColor(0.5, 0.5, 0.5, 1) end
        setFontSize(row.title, size + 1) setFontSize(row.star.text, size + 1)
        setFontSize(row.unwatch.text, size)
        if quest.pendingData then row.title:SetTextColor(0.65,0.65,0.65,1)
        elseif quest.complete then row.title:SetTextColor(0.2,1,0.2,1)
        else row.title:SetTextColor(1,0.82,0,1) end
        row:Show() y = y - (size + 9)
        local objectiveIndex
        for objectiveIndex = 1, table.getn(quest.objectives) do
            local objective = quest.objectives[objectiveIndex]
            objectiveRowIndex = objectiveRowIndex + 1
            local objectiveRow = self:GetObjectiveRow(objectiveRowIndex)
            objectiveRow.questID = quest.id objectiveRow.objectiveIndex = objective.index
            objectiveRow:SetPoint("TOPLEFT", self.content, "TOPLEFT", 18, y)
            objectiveRow.text:SetText(self:ObjectiveText(objective)) setFontSize(objectiveRow.text, size)
            if objective.complete then objectiveRow.text:SetTextColor(0.35,0.8,0.35,1)
            elseif objective.unresolvedReason then objectiveRow.text:SetTextColor(0.6,0.6,0.6,1)
            elseif objective.progressUnavailable then objectiveRow.text:SetTextColor(0.9,0.72,0.4,1)
            else objectiveRow.text:SetTextColor(0.9,0.9,0.9,1) end
            objectiveRow:Show() y = y - (size + 7)
        end
        y = y - 5
    end
    for index = questRowIndex + 1, table.getn(self.questRows) do self.questRows[index]:Hide() end
    for index = objectiveRowIndex + 1, table.getn(self.objectiveRows) do self.objectiveRows[index]:Hide() end
    self.content:SetHeight(math.max(20, -y)) self.frame:SetHeight(math.max(45, -y + 35))
    if QuestBeacon.Config:Get("trackerShown") then self.frame:Show() else self.frame:Hide() end
end

function Tracker:OnConfigChanged(path)
    if path == "trackerPoint" or path == "trackerX" or path == "trackerY" or path == "reset" then self:ApplyPosition() end
    self:Refresh()
end

function Tracker:Initialize()
    if self.frame then return end
    local frame = CreateFrame("Frame", "QuestBeaconTrackerFrame", UIParent)
    self.frame = frame
    frame:SetWidth(320) frame:SetHeight(100) frame:SetFrameStrata("HIGH")
    frame:SetMovable(true) frame:SetClampedToScreen(true) frame:EnableMouse(true) frame:RegisterForDrag("LeftButton")
    local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -9) header:SetText("QuestBeacon   + star   x hide")
    header:SetTextColor(0.75, 0.75, 0.75, 1)
    local gear = CreateFrame("Button", nil, frame)
    gear:SetWidth(28) gear:SetHeight(20) gear:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -7, -6)
    gear:SetText("S") gear:SetScript("OnClick", function() QuestBeacon.Settings:Toggle() end)
    self.content = CreateFrame("Frame", nil, frame)
    self.content:SetWidth(300) self.content:SetHeight(20) self.content:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -32)
    frame:SetScript("OnDragStart", function()
        if not QuestBeacon.Config:Get("trackerLocked") then this:StartMoving() this.dragging=true end
    end)
    frame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        if this.dragging then this.dragging=nil Tracker:SavePosition() end
    end)
    self:ApplyPosition()
    QuestBeacon.Config:RegisterListener(self, self.OnConfigChanged)
    self:Refresh()
end
