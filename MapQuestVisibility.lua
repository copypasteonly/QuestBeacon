QuestBeacon.MapQuestVisibility = QuestBeacon.MapQuestVisibility or {}
local Visibility = QuestBeacon.MapQuestVisibility

Visibility.choicePage = 1
Visibility.choicesPerPage = 8

local function positiveInteger(value)
    local number = tonumber(value)
    if not number or number <= 0 or math.floor(number) ~= number then return nil end
    return number
end

local function createButton(parent, label, width, height)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetWidth(width or 100) button:SetHeight(height or 22) button:SetText(label)
    return button
end

local function setButtonEnabled(button, enabled)
    if enabled then button:Enable() else button:Disable() end
end

function Visibility:IsDisabled(questID)
    local id = positiveInteger(questID)
    local disabled = QuestBeacon.Config:Get("disabledMapQuests")
    return id and disabled[id] and true or false
end

function Visibility:SetDisabled(questID, disabled)
    local id = positiveInteger(questID)
    if not id then return false, "invalid quest ID" end
    local values = QuestBeacon.Config:Get("disabledMapQuests")
    if disabled then values[id] = true else values[id] = nil end
    QuestBeacon.Config:Set("disabledMapQuests", values)
    return true, nil
end

function Visibility:GetDisabledQuestIDs()
    local result = {}
    local questID, disabled
    for questID, disabled in pairs(QuestBeacon.Config:Get("disabledMapQuests") or {}) do
        local id = positiveInteger(questID)
        if disabled and id then table.insert(result, id) end
    end
    table.sort(result)
    return result
end

function Visibility:GetQuestLabel(questID, fallbackTitle, fallbackLevel)
    local id = positiveInteger(questID)
    local quest = id and QuestBeacon.QuestService and QuestBeacon.QuestService:GetQuest(id) or nil
    local info = quest
    if not info and id and QuestBeacon.DB and QuestBeacon.DB.GetQuestInfo then info = QuestBeacon.DB:GetQuestInfo(id) end
    local title = info and info.title or fallbackTitle or ("Quest " .. tostring(id or questID))
    local level = info and info.level or fallbackLevel
    if tonumber(level) and tonumber(level) > 0 then return "[" .. tostring(level) .. "] " .. tostring(title) end
    return tostring(title)
end

local function questIsPvP(questID, quest)
    if quest and quest.isPvP ~= nil then return quest.isPvP end
    if QuestBeacon.QuestService and QuestBeacon.QuestService.GetQuestPvP then
        return QuestBeacon.QuestService:GetQuestPvP(questID, false)
    end
    return false
end

function Visibility:FilterPin(pin, disabledMapQuests, hidePvP)
    if not pin or pin.role == "service" then return pin end
    local disabled = disabledMapQuests or QuestBeacon.Config:Get("disabledMapQuests") or {}
    local associations = pin.associations or {}
    if table.getn(associations) == 0 then
        if pin.quest and disabled[positiveInteger(pin.quest.id)] then return nil end
        if hidePvP and pin.quest and questIsPvP(pin.quest.id, pin.quest) then return nil end
        return pin
    end
    local visible = {}
    local removed = false
    local index
    for index = 1, table.getn(associations) do
        local association = associations[index]
        local questID = positiveInteger(association.questID)
        local quest = association.quest
        if (questID and disabled[questID]) or (hidePvP and questIsPvP(questID, quest)) then
            removed = true
        else
            table.insert(visible, association)
        end
    end
    if table.getn(visible) == 0 then return nil end
    if not removed then return pin end
    local result = {}
    local key, value
    for key, value in pairs(pin) do result[key] = value end
    result.associations = visible
    local first = visible[1]
    result.quest = first.quest or (QuestBeacon.QuestService and QuestBeacon.QuestService:GetQuest(first.questID)) or pin.quest
    result.objective = first.objective or pin.objective
    return result
end

function Visibility:GetPinChoices(pin, includeDisabled)
    local choices, seen = {}, {}
    local disabled = QuestBeacon.Config:Get("disabledMapQuests") or {}
    local associations = pin and pin.associations or {}
    local index
    for index = 1, table.getn(associations) do
        local association = associations[index]
        local questID = positiveInteger(association.questID)
        if questID and not seen[questID] and (includeDisabled or not disabled[questID]) then
            seen[questID] = true
            table.insert(choices, {id=questID, title=association.title,
                level=association.quest and association.quest.level or nil})
        end
    end
    if table.getn(choices) == 0 and pin and pin.quest then
        local questID = positiveInteger(pin.quest.id)
        if questID and (includeDisabled or not disabled[questID]) then
            table.insert(choices, {id=questID, title=pin.quest.title, level=pin.quest.level})
        end
    end
    table.sort(choices, function(first, second) return first.id < second.id end)
    return choices
end

function Visibility:EnsurePrompt()
    if self.prompt then return end
    local frame = CreateFrame("Frame", "QuestBeaconMapQuestPrompt", UIParent)
    self.prompt = frame
    frame:SetWidth(440) frame:SetHeight(360) frame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    frame:SetFrameStrata("FULLSCREEN_DIALOG") frame:EnableMouse(true)
    frame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", tile=true, tileSize=32,
        edgeSize=32, insets={left=11,right=12,top=12,bottom=11}})
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -28)
    frame.message = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.message:SetWidth(370) frame.message:SetPoint("TOP", frame.title, "BOTTOM", 0, -22)

    frame.rows = {}
    local index
    for index = 1, self.choicesPerPage do
        local row = createButton(frame, "", 360, 24)
        row:SetPoint("TOP", frame, "TOP", 0, -82 - (index - 1) * 29)
        row:SetScript("OnClick", function() Visibility:ShowConfirmation(this.choice, Visibility.pendingAction) end)
        frame.rows[index] = row
    end
    frame.previous = createButton(frame, "Previous", 90, 22)
    frame.previous:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 38, 26)
    frame.previous:SetScript("OnClick", function() Visibility.choicePage = Visibility.choicePage - 1 Visibility:RefreshChoices() end)
    frame.page = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.page:SetPoint("BOTTOM", frame, "BOTTOM", 0, 33)
    frame.next = createButton(frame, "Next", 90, 22)
    frame.next:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -38, 26)
    frame.next:SetScript("OnClick", function() Visibility.choicePage = Visibility.choicePage + 1 Visibility:RefreshChoices() end)

    frame.confirm = createButton(frame, "Hide", 110, 24)
    frame.confirm:SetPoint("BOTTOM", frame, "BOTTOM", -65, 30)
    frame.confirm:SetScript("OnClick", function()
        if Visibility.pendingChoice then
            if Visibility.pendingAction == "complete" and QuestBeacon.QuestHistory then
                QuestBeacon.QuestHistory:RecordComplete(Visibility.pendingChoice.id, "manual")
                QuestBeacon:Print("marked quest " .. tostring(Visibility.pendingChoice.id) .. " complete")
            else
                Visibility:SetDisabled(Visibility.pendingChoice.id, true)
            end
        end
        Visibility.prompt:Hide()
    end)
    frame.cancel = createButton(frame, "Cancel", 110, 24)
    frame.cancel:SetPoint("BOTTOM", frame, "BOTTOM", 65, 30)
    frame.cancel:SetScript("OnClick", function() Visibility.prompt:Hide() end)
    frame:Hide()
end

function Visibility:RefreshChoices()
    local frame, choices = self.prompt, self.pendingChoices or {}
    local pages = math.max(1, math.ceil(table.getn(choices) / self.choicesPerPage))
    if self.choicePage < 1 then self.choicePage = 1 end
    if self.choicePage > pages then self.choicePage = pages end
    local index
    for index = 1, self.choicesPerPage do
        local choice = choices[(self.choicePage - 1) * self.choicesPerPage + index]
        local row = frame.rows[index]
        row.choice = choice
        if choice then row:SetText(self:GetQuestLabel(choice.id, choice.title, choice.level)) row:Show() else row:Hide() end
    end
    setButtonEnabled(frame.previous, self.choicePage > 1)
    setButtonEnabled(frame.next, self.choicePage < pages)
    frame.page:SetText("Page " .. tostring(self.choicePage) .. " of " .. tostring(pages))
end

function Visibility:ShowConfirmation(choice, action)
    if not choice then return false end
    self:EnsurePrompt()
    self.pendingChoice = choice self.pendingChoices = nil self.pendingAction = action or "hide"
    if self.pendingAction == "complete" then
        self.prompt.title:SetText("Mark quest complete?")
        self.prompt.message:SetText(self:GetQuestLabel(choice.id, choice.title, choice.level) ..
            "\n\nAdd this quest to this character's completion history?")
        self.prompt.confirm:SetText("Complete")
    else
        self.prompt.title:SetText("Hide map quest?")
        self.prompt.message:SetText(self:GetQuestLabel(choice.id, choice.title, choice.level) ..
            "\n\nHide this quest from the World Map and Minimap?")
        self.prompt.confirm:SetText("Hide")
    end
    local index
    for index = 1, self.choicesPerPage do self.prompt.rows[index]:Hide() end
    self.prompt.previous:Hide() self.prompt.next:Hide() self.prompt.page:Hide()
    self.prompt.confirm:Show() self.prompt.cancel:Show() self.prompt:Show()
    return true
end

function Visibility:PromptForPin(pin, action)
    if not pin or pin.role == "service" then return false end
    local requestedAction = action == "complete" and "complete" or "hide"
    local choices = self:GetPinChoices(pin, requestedAction == "complete")
    if table.getn(choices) == 0 then return false end
    if table.getn(choices) == 1 then return self:ShowConfirmation(choices[1], requestedAction) end
    self:EnsurePrompt()
    self.pendingChoice = nil self.pendingChoices = choices self.pendingAction = requestedAction self.choicePage = 1
    self.prompt.title:SetText(requestedAction == "complete" and "Choose a completed quest" or "Choose a quest to hide")
    self.prompt.message:SetText("This marker is shared by multiple quests.")
    self.prompt.confirm:Hide() self.prompt.cancel:Show()
    self.prompt.previous:Show() self.prompt.next:Show() self.prompt.page:Show()
    self:RefreshChoices()
    self.prompt:Show()
    return true
end
