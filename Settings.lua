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

function Settings:CreateCheck(parent, label, path, x, y)
    local button = CreateFrame("CheckButton", self:ControlName("Check"), parent, "UICheckButtonTemplate")
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local text = self:CreateLabel(parent, label, x + 26, y - 5, 11)
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
    self.refreshing = false
end

function Settings:Toggle()
    if not self.frame then self:Initialize() end
    if self.frame:IsVisible() then self.frame:Hide() else self:Refresh() self.frame:Show() end
end

function Settings:ToggleMarkerFrame()
    if not self.markerFrame then self:InitializeMarkerFrame() end
    if self.markerFrame:IsVisible() then self.markerFrame:Hide()
    else self:Refresh() self.markerFrame:Show() end
end

function Settings:InitializeMarkerFrame()
    if self.markerFrame then return end
    local frame = CreateFrame("Frame", "QuestBeaconMarkerSettingsFrame", UIParent)
    self.markerFrame = frame
    frame:SetWidth(620) frame:SetHeight(500)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("DIALOG") frame:SetMovable(true) frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", tile=true, tileSize=32, edgeSize=32, insets={left=11,right=12,top=12,bottom=11}})
    frame:SetScript("OnDragStart", function() this:StartMoving() end)
    frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    self:CreateLabel(frame, "Map Service Markers", 24, -20, 16)
    self:CreateButton(frame, "X", 570, -15, 25, function() Settings.markerFrame:Hide() end)
    self:CreateLabel(frame, "World Map", 45, -55, 13)
    self:CreateLabel(frame, "Minimap", 330, -55, 13)
    local categories = QuestBeacon.ServiceMarkerService.categories
    local index
    for index = 1, table.getn(categories) do
        local category = categories[index]
        local y = -72 - (index - 1) * 34
        self:CreateCheck(frame, category.label, "worldMapServices." .. category.key, 45, y)
        self:CreateCheck(frame, category.label, "minimapServices." .. category.key, 330, y)
    end
    frame:Hide()
end

function Settings:Initialize()
    if self.frame then return end
    local frame = CreateFrame("Frame", "QuestBeaconSettingsFrame", UIParent)
    self.frame = frame
    frame:SetWidth(620)
    frame:SetHeight(500)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", tile=true, tileSize=32, edgeSize=32, insets={left=11,right=12,top=12,bottom=11}})
    frame:SetScript("OnDragStart", function() this:StartMoving() end)
    frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    self:CreateLabel(frame, "QuestBeacon Settings", 24, -20, 16)
    local close = self:CreateButton(frame, "X", 570, -15, 25, function() Settings.frame:Hide() end)

    self:CreateLabel(frame, "Interface", 25, -55, 13)
    self:CreateCheck(frame, "Show arrow", "shown", 25, -75)
    self:CreateCheck(frame, "Show tracker", "trackerShown", 25, -105)
    self:CreateCheck(frame, "Lock tracker", "trackerLocked", 25, -135)
    self:CreateSlider(frame, "Arrow text size", "arrowFontSize", 8, 24, 25, -180)
    self:CreateSlider(frame, "Tracker text size", "trackerFontSize", 8, 20, 25, -235)
    self.sortButton = self:CreateButton(frame, "Sort: Distance", 25, -300, 150, function()
        local current = QuestBeacon.Config:Get("questSort")
        QuestBeacon.Config:Set("questSort", current == "distance" and "level" or "distance")
        Settings:Refresh()
    end)
    self.viewButton = self:CreateButton(frame, "View: All Quests", 25, -330, 170, function()
        QuestBeacon.Tracker:CycleView()
        Settings:Refresh()
    end)
    self:CreateCheck(frame, "Replace native tracker", "replaceNativeTracker", 25, -362)
    self:CreateCheck(frame, "Show quest levels", "trackerShowLevels", 25, -392)
    self:CreateCheck(frame, "Unfold objectives by default", "trackerExpandObjectives", 25, -422)

    local groups = {{"World Map", "worldMap", 220}, {"Minimap", "minimap", 415}}
    local groupIndex
    for groupIndex = 1, table.getn(groups) do
        local group = groups[groupIndex]
        self:CreateLabel(frame, group[1], group[3], -55, 13)
        self:CreateCheck(frame, "Objectives", group[2] .. ".objectives", group[3], -80)
        self:CreateCheck(frame, "Item sources", group[2] .. ".itemSources", group[3], -115)
        self:CreateCheck(frame, "Turn-ins", group[2] .. ".turnIns", group[3], -150)
        self:CreateCheck(frame, "Available quests", group[2] .. ".available", group[3], -185)
    end
    self:CreateLabel(frame, "Available Quest Filters", 220, -245, 13)
    self:CreateCheck(frame, "Show low-level quests", "availability.lowLevel", 220, -270)
    self:CreateCheck(frame, "Show quests above level +3", "availability.highLevel", 220, -305)
    self:CreateCheck(frame, "Show event quests", "availability.event", 220, -340)
    self:CreateSlider(frame, "Tracker opacity", "trackerOpacity", 0, 100, 415, -245)
    self:CreateButton(frame, "Service markers", 415, -350, 165, function() Settings:ToggleMarkerFrame() end)
    self:CreateButton(frame, "Reset interface", 220, -400, 140, function()
        QuestBeacon.Config:ResetUI()
        Settings:Refresh()
    end)
    self.historyArmed = false
    self.historyButton = self:CreateButton(frame, "Reset quest history", 380, -400, 160, function()
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
