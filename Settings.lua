QuestBeacon.Settings = QuestBeacon.Settings or {}
local Settings = QuestBeacon.Settings

Settings.rows = {}
Settings.controlCount = 0

function Settings:ControlName(kind)
    self.controlCount = self.controlCount + 1
    return "QuestBeaconSettings" .. kind .. tostring(self.controlCount)
end

local function setText(font, text)
    if font then font:SetText(text) end
end

local function setButtonEnabled(button, enabled)
    if enabled then button:Enable() else button:Disable() end
end

function Settings:CreateLabel(parent, text, x, y, size)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetText(text)
    if label.GetFont and label.SetFont then
        local path, oldSize, flags = label:GetFont()
        if path then label:SetFont(path, size or oldSize or 12, flags) end
    end
    return label
end

function Settings:CreateCheck(parent, label, path, x, y, iconPath)
    local button = CreateFrame("CheckButton", self:ControlName("Check"), parent, "UICheckButtonTemplate")
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local textOffset = 26
    if iconPath then
        local icon = parent:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(18) icon:SetHeight(18)
        icon:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 27, y - 3)
        icon:SetTexture(iconPath)
        textOffset = 49
        button.icon = icon
    end
    local text = self:CreateLabel(parent, label, x + textOffset, y - 5, 11)
    button.path = path
    button.label = text
    button:SetScript("OnClick", function()
        QuestBeacon.Config:Set(this.path, this:GetChecked() and true or false)
    end)
    table.insert(self.rows, button)
    return button
end

function Settings:CreateSlider(parent, label, path, minimum, maximum, x, y)
    self:CreateLabel(parent, label, x, y, 11)
    local slider = CreateFrame("Slider", self:ControlName("Slider"), parent, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 18)
    slider:SetWidth(170)
    slider:SetMinMaxValues(minimum, maximum)
    slider:SetValueStep(1)
    slider.path = path
    slider.valueText = self:CreateLabel(parent, "", x + 180, y - 20, 11)
    slider:SetScript("OnValueChanged", function()
        local value = math.floor((tonumber(arg1) or this:GetValue()) + 0.5)
        setText(this.valueText, tostring(value))
        if not Settings.refreshing then QuestBeacon.Config:Set(this.path, value) end
    end)
    table.insert(self.rows, slider)
    return slider
end

function Settings:CreateButton(parent, label, x, y, width, callback)
    local button = CreateFrame("Button", self:ControlName("Button"), parent, "UIPanelButtonTemplate")
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    button:SetWidth(width or 110)
    button:SetHeight(22)
    button:SetText(label)
    button:SetScript("OnClick", callback)
    return button
end

function Settings:Refresh()
    if not self.frame then return end
    self.refreshing = true
    local index
    for index = 1, table.getn(self.rows) do
        local row = self.rows[index]
        if row.GetObjectType and row:GetObjectType() == "Slider" then
            row:SetValue(QuestBeacon.Config:Get(row.path))
            setText(row.valueText, tostring(QuestBeacon.Config:Get(row.path)))
        elseif row.SetChecked then
            row:SetChecked(QuestBeacon.Config:Get(row.path) and 1 or nil)
        end
    end
    if self.sortButton then
        self.sortButton:SetText("Sort: " .. (QuestBeacon.Config:Get("questSort") == "level" and "Level" or "Distance"))
    end
    if self.viewButton then
        local view = QuestBeacon.Config:Get("trackerView")
        self.viewButton:SetText("View: " .. (view == "zone" and "Current Zone" or view == "watched" and "Watched Only" or "All Quests"))
    end
    local function refreshServiceToggle(button, path)
        if not button or not QuestBeacon.ServiceMarkerService then return end
        local values = QuestBeacon.Config:Get(path) or {}
        local allEnabled = true
        local categories = QuestBeacon.ServiceMarkerService.categories
        local categoryIndex
        for categoryIndex = 1, table.getn(categories) do
            if not values[categories[categoryIndex].key] then allEnabled = false end
        end
        button:SetText(allEnabled and "Disable all" or "Enable all")
        button.allEnabled = allEnabled
    end
    refreshServiceToggle(self.worldServiceToggle, "worldMapServices")
    refreshServiceToggle(self.minimapServiceToggle, "minimapServices")
    if self.disabledQuestButton and QuestBeacon.MapQuestVisibility then
        local count = table.getn(QuestBeacon.MapQuestVisibility:GetDisabledQuestIDs())
        self.disabledQuestButton:SetText("Disabled map quests (" .. tostring(count) .. ")")
    end
    if self.disabledQuestFrame and self.disabledQuestFrame:IsVisible() then self:RefreshDisabledQuests() end
    self.refreshing = false
end

function Settings:Toggle()
    if not self.frame then self:Initialize() end
    if self.frame:IsVisible() then
        self:Hide()
    else
        self:Refresh()
        self.frame:Show()
    end
end

function Settings:Hide()
    if self.frame then self.frame:Hide() end
    if self.markerFrame then self.markerFrame:Hide() end
    if self.disabledQuestFrame then self.disabledQuestFrame:Hide() end
end

function Settings:ToggleMarkerFrame()
    if not self.markerFrame then self:InitializeMarkerFrame() end
    if self.markerFrame:IsVisible() then self.markerFrame:Hide()
    else
        if self.disabledQuestFrame then self.disabledQuestFrame:Hide() end
        self.markerFrame:ClearAllPoints()
        self.markerFrame:SetPoint("TOPLEFT", self.frame, "TOPRIGHT", 12, 0)
        self:Refresh()
        self.markerFrame:Show()
    end
end

function Settings:ToggleDisabledQuestFrame()
    if not self.disabledQuestFrame then self:InitializeDisabledQuestFrame() end
    if self.disabledQuestFrame:IsVisible() then
        self.disabledQuestFrame:Hide()
    else
        if self.markerFrame then self.markerFrame:Hide() end
        self.disabledQuestPage = 1
        self.disabledQuestFrame:ClearAllPoints()
        self.disabledQuestFrame:SetPoint("TOPLEFT", self.frame, "TOPRIGHT", 12, 0)
        self:RefreshDisabledQuests()
        self.disabledQuestFrame:Show()
    end
end

function Settings:RefreshDisabledQuests()
    local frame = self.disabledQuestFrame
    if not frame or not QuestBeacon.MapQuestVisibility then return end
    local ids = QuestBeacon.MapQuestVisibility:GetDisabledQuestIDs()
    local perPage = table.getn(frame.rows)
    local pages = math.max(1, math.ceil(table.getn(ids) / perPage))
    self.disabledQuestPage = math.max(1, math.min(pages, self.disabledQuestPage or 1))
    local index
    for index = 1, perPage do
        local questID = ids[(self.disabledQuestPage - 1) * perPage + index]
        local row = frame.rows[index]
        row.questID = questID row.restore.questID = questID
        if questID then
            row.label:SetText(QuestBeacon.MapQuestVisibility:GetQuestLabel(questID) .. "  (ID " .. tostring(questID) .. ")")
            row:Show()
        else
            row:Hide()
        end
    end
    frame.empty:SetText(table.getn(ids) == 0 and "No quests are hidden from the maps." or "")
    frame.page:SetText("Page " .. tostring(self.disabledQuestPage) .. " of " .. tostring(pages))
    setButtonEnabled(frame.previous, self.disabledQuestPage > 1)
    setButtonEnabled(frame.next, self.disabledQuestPage < pages)
    setButtonEnabled(frame.restoreAll, table.getn(ids) > 0)
end

function Settings:InitializeDisabledQuestFrame()
    if self.disabledQuestFrame then return end
    local frame = CreateFrame("Frame", "QuestBeaconDisabledMapQuestsFrame", UIParent)
    self.disabledQuestFrame = frame
    frame:SetWidth(540) frame:SetHeight(480)
    frame:SetPoint("TOPLEFT", self.frame, "TOPRIGHT", 12, 0)
    frame:SetFrameStrata("DIALOG") frame:EnableMouse(true)
    frame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", tile=true, tileSize=32,
        edgeSize=32, insets={left=11,right=12,top=12,bottom=11}})
    self:CreateLabel(frame, "Disabled Map Quests", 25, -22, 16)
    self:CreateButton(frame, "X", 490, -17, 25, function() Settings.disabledQuestFrame:Hide() end)
    frame.empty = self:CreateLabel(frame, "", 35, -72, 11)
    frame.rows = {}
    local index
    for index = 1, 10 do
        local row = CreateFrame("Frame", nil, frame)
        row:SetWidth(470) row:SetHeight(28)
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", 35, -82 - (index - 1) * 31)
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.label:SetWidth(345) row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.label:SetJustifyH("LEFT")
        row.restore = self:CreateButton(row, "Restore", 365, -3, 95, function()
            if this.questID then QuestBeacon.MapQuestVisibility:SetDisabled(this.questID, false) end
        end)
        frame.rows[index] = row
    end
    frame.previous = self:CreateButton(frame, "Previous", 35, -428, 90, function()
        Settings.disabledQuestPage = (Settings.disabledQuestPage or 1) - 1 Settings:RefreshDisabledQuests()
    end)
    frame.page = self:CreateLabel(frame, "", 213, -433, 11)
    frame.next = self:CreateButton(frame, "Next", 315, -428, 90, function()
        Settings.disabledQuestPage = (Settings.disabledQuestPage or 1) + 1 Settings:RefreshDisabledQuests()
    end)
    frame.restoreAll = self:CreateButton(frame, "Restore all", 410, -428, 95, function()
        QuestBeacon.Config:Set("disabledMapQuests", {})
    end)
    frame:Hide()
end

function Settings:InitializeMarkerFrame()
    if self.markerFrame then return end
    local frame = CreateFrame("Frame", "QuestBeaconMarkerSettingsFrame", UIParent)
    self.markerFrame = frame
    frame:SetWidth(600) frame:SetHeight(500)
    frame:SetPoint("TOPLEFT", self.frame, "TOPRIGHT", 12, 0)
    frame:SetFrameStrata("DIALOG") frame:EnableMouse(true)
    frame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", tile=true, tileSize=32, edgeSize=32, insets={left=11,right=12,top=12,bottom=11}})
    self:CreateLabel(frame, "Map Service Markers", 25, -22, 16)
    self:CreateButton(frame, "X", 550, -17, 25, function() Settings.markerFrame:Hide() end)
    self:CreateLabel(frame, "World Map", 35, -62, 13)
    self:CreateLabel(frame, "Minimap", 315, -62, 13)
    self.worldServiceToggle = self:CreateButton(frame, "Enable all", 35, -82, 120, function()
        QuestBeacon.Config:SetAll("worldMapServices", not this.allEnabled)
    end)
    self.minimapServiceToggle = self:CreateButton(frame, "Enable all", 315, -82, 120, function()
        QuestBeacon.Config:SetAll("minimapServices", not this.allEnabled)
    end)
    local categories = QuestBeacon.ServiceMarkerService.categories
    local index
    for index = 1, table.getn(categories) do
        local category = categories[index]
        local y = -116 - (index - 1) * 31
        local icon = "Interface\\AddOns\\QuestBeacon\\img\\tracking\\" .. category.key
        self:CreateCheck(frame, category.label, "worldMapServices." .. category.key, 35, y, icon)
        self:CreateCheck(frame, category.label, "minimapServices." .. category.key, 315, y, icon)
    end
    frame:Hide()
end

function Settings:Initialize()
    if self.frame then return end
    local frame = CreateFrame("Frame", "QuestBeaconSettingsFrame", UIParent)
    self.frame = frame
    frame:SetWidth(640)
    frame:SetHeight(650)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", tile=true, tileSize=32, edgeSize=32, insets={left=11,right=12,top=12,bottom=11}})
    frame:SetScript("OnDragStart", function() this:StartMoving() end)
    frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    self:CreateLabel(frame, "QuestBeacon Settings", 30, -22, 16)
    local close = self:CreateButton(frame, "X", 590, -17, 25, function() Settings:Hide() end)

    self:CreateLabel(frame, "Interface", 30, -62, 13)
    self:CreateCheck(frame, "Show arrow", "shown", 30, -85)
    self:CreateCheck(frame, "Show tracker", "trackerShown", 30, -120)
    self:CreateCheck(frame, "Lock tracker", "trackerLocked", 30, -155)
    self:CreateSlider(frame, "Arrow text size", "arrowFontSize", 8, 24, 30, -205)
    self:CreateSlider(frame, "Tracker text size", "trackerFontSize", 8, 20, 30, -265)
    self.sortButton = self:CreateButton(frame, "Sort: Distance", 30, -330, 170, function()
        local current = QuestBeacon.Config:Get("questSort")
        QuestBeacon.Config:Set("questSort", current == "distance" and "level" or "distance")
        Settings:Refresh()
    end)
    self.viewButton = self:CreateButton(frame, "View: All Quests", 30, -362, 170, function()
        QuestBeacon.Tracker:CycleView()
        Settings:Refresh()
    end)
    self:CreateCheck(frame, "Replace native tracker", "replaceNativeTracker", 30, -400)
    self:CreateCheck(frame, "Show quest levels", "trackerShowLevels", 30, -430)
    self:CreateCheck(frame, "Unfold objectives by default", "trackerExpandObjectives", 30, -460)

    local groups = {{"World Map", "worldMap", 230}, {"Minimap", "minimap", 430}}
    local groupIndex
    for groupIndex = 1, table.getn(groups) do
        local group = groups[groupIndex]
        self:CreateLabel(frame, group[1], group[3], -62, 13)
        self:CreateCheck(frame, "Objectives", group[2] .. ".objectives", group[3], -85)
        self:CreateCheck(frame, "Item sources", group[2] .. ".itemSources", group[3], -120)
        self:CreateCheck(frame, "Turn-ins", group[2] .. ".turnIns", group[3], -155)
        self:CreateCheck(frame, "Available quests", group[2] .. ".available", group[3], -190)
        self:CreateCheck(frame, "Spawn circles", group[2] .. ".spawnPoints", group[3], -225)
        self:CreateCheck(frame, "Objective clusters", group[2] .. ".objectiveClusters", group[3], -260)
    end
    self:CreateLabel(frame, "Available Quest Filters", 230, -305, 13)
    self:CreateCheck(frame, "Show low-level quests", "availability.lowLevel", 230, -330)
    self:CreateCheck(frame, "Show event quests", "availability.event", 230, -365)
    self:CreateLabel(frame, "Quest Mob Icons", 430, -305, 13)
    self:CreateCheck(frame, "Target frame", "questMobs.target", 430, -330)
    self:CreateCheck(frame, "Mouseover tooltip", "questMobs.tooltip", 430, -365)
    self:CreateCheck(frame, "Nameplates", "questMobs.nameplates", 430, -400)
    self:CreateSlider(frame, "Tracker opacity", "trackerOpacity", 0, 100, 30, -500)
    self:CreateButton(frame, "Service markers", 430, -455, 170, function() Settings:ToggleMarkerFrame() end)
    self.disabledQuestButton = self:CreateButton(frame, "Disabled map quests (0)", 230, -545, 170, function()
        Settings:ToggleDisabledQuestFrame()
    end)
    self:CreateButton(frame, "Reset interface", 230, -590, 170, function()
        QuestBeacon.Config:ResetUI()
        Settings:Refresh()
    end)
    self.historyArmed = false
    self.historyButton = self:CreateButton(frame, "Reset quest history", 430, -590, 170, function()
        if not Settings.historyArmed then
            Settings.historyArmed = true
            this:SetText("Click again to confirm")
        else
            QuestBeacon.QuestHistory:Reset()
            Settings.historyArmed = false
            this:SetText("Reset quest history")
            QuestBeacon.EventCoordinator:MarkQuestDirty(true)
        end
    end)
    QuestBeacon.Config:RegisterListener(self, function(owner) owner:Refresh() end)
    self:Refresh()
    frame:Hide()
end
