QuestBeacon.WorldMapPins = QuestBeacon.WorldMapPins or {}
local Renderer = QuestBeacon.WorldMapPins

Renderer.pool = {}

local function normalizedName(value)
    return string.lower(string.gsub(value or "", "[^%w]", ""))
end

function Renderer:OpenArea(areaID)
    local area = areaID and QuestBeacon.DB:GetArea(areaID) or nil
    if not area then return false end
    if type(ToggleWorldMap) == "function" and WorldMapFrame and not WorldMapFrame:IsVisible() then ToggleWorldMap() end
    if type(GetMapContinents) ~= "function" or type(GetMapZones) ~= "function" or type(SetMapZoom) ~= "function" then return false end
    local wanted = normalizedName(area.name)
    local continents = {GetMapContinents()}
    local continentIndex
    for continentIndex = 1, table.getn(continents) do
        local zones = {GetMapZones(continentIndex)}
        local zoneIndex
        for zoneIndex = 1, table.getn(zones) do
            if normalizedName(zones[zoneIndex]) == wanted then
                SetMapZoom(continentIndex, zoneIndex)
                self:Refresh()
                return true
            end
        end
    end
    return false
end

function Renderer:GetViewedAreaID()
    if not C_Map or type(C_Map.GetMapAreaIDs) ~= "function" or type(GetMapInfo) ~= "function" then return nil end
    local directory = GetMapInfo()
    if not directory then return nil end
    local areas = C_Map.GetMapAreaIDs()
    local direct = areas and areas[directory]
    if tonumber(direct) then return tonumber(direct) end
    local wanted = string.lower(string.gsub(directory, "[^%w]", ""))
    local name, areaID
    for name, areaID in pairs(areas or {}) do
        if string.lower(string.gsub(name, "[^%w]", "")) == wanted then return tonumber(areaID) end
    end
    return nil
end

function Renderer:Project(pin, area)
    if not area or area.mappingStatus ~= "mapped" or pin.mapID ~= area.mapID then return nil, nil end
    if not area.locLeft or not area.locRight or not area.locTop or not area.locBottom then return nil, nil end
    local width = area.locLeft - area.locRight
    local height = area.locTop - area.locBottom
    if width == 0 or height == 0 then return nil, nil end
    local x = (area.locLeft - pin.y) / width
    local y = (area.locTop - pin.x) / height
    if x < 0 or x > 1 or y < 0 or y > 1 then return nil, nil end
    return x, y
end

function Renderer:GetPin(index)
    if self.pool[index] then return self.pool[index] end
    local frame = CreateFrame("Button", nil, WorldMapButton)
    frame:SetWidth(18) frame:SetHeight(18) frame:SetFrameLevel(20) frame:RegisterForClicks("LeftButtonUp")
    frame.texture = frame:CreateTexture(nil, "ARTWORK") frame.texture:SetAllPoints(frame)
    frame:SetScript("OnClick", function() QuestBeacon.PinService:SelectPin(this.pin) end)
    frame:SetScript("OnEnter", function() Renderer:ShowTooltip(this) end)
    frame:SetScript("OnLeave", function() if WorldMapTooltip then WorldMapTooltip:Hide() elseif GameTooltip then GameTooltip:Hide() end end)
    self.pool[index] = frame
    return frame
end

function Renderer:ShowTooltip(frame)
    local tooltip = WorldMapTooltip or GameTooltip
    if not tooltip or not frame.pin then return end
    tooltip:SetOwner(frame, "ANCHOR_RIGHT")
    local associations = frame.pin.associations or {}
    local index
    for index = 1, table.getn(associations) do
        local row = associations[index]
        if index == 1 then tooltip:SetText("[" .. tostring(frame.pin.quest.level or 0) .. "] " .. tostring(row.title))
        else tooltip:AddLine(tostring(row.title), 1, 0.82, 0) end
        tooltip:AddLine(tostring(row.text or frame.pin.role), 0.85, 0.85, 0.85)
    end
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    local distance = QuestBeacon.PositionService:Distance2D(player, frame.pin)
    if distance then tooltip:AddLine(string.format("%.1f yards", distance), 0.5, 1, 0.5) end
    tooltip:Show()
end

function Renderer:Refresh()
    if not WorldMapButton or not WorldMapFrame or not WorldMapFrame:IsVisible() then return end
    local areaID = self:GetViewedAreaID()
    local area = areaID and QuestBeacon.DB:GetArea(areaID) or nil
    local pins = QuestBeacon.PinService:Rebuild(areaID, "world")
    local width, height = WorldMapButton:GetWidth(), WorldMapButton:GetHeight()
    local shown = 0
    local index
    for index = 1, table.getn(pins) do
        local pin = pins[index]
        if QuestBeacon.Config:Get("worldMap." .. pin.role) then
            local x, y = self:Project(pin, area)
            if x and y then
                shown = shown + 1
                local frame = self:GetPin(shown) frame.pin = pin
                frame.texture:SetTexture("Interface\\AddOns\\QuestBeacon\\img\\" .. pin.texture)
                if pin.role == "available" or pin.role == "turnIns" then
                    frame.texture:SetVertexColor(1, 0.82, 0, 1)
                else
                    frame.texture:SetVertexColor(1, 1, 1, 1)
                end
                frame:ClearAllPoints() frame:SetPoint("CENTER", WorldMapButton, "TOPLEFT", x * width, -y * height)
                frame:Show()
            end
        end
    end
    for index = shown + 1, table.getn(self.pool) do self.pool[index]:Hide() end
end

function Renderer:Initialize()
    if self.frame then return end
    if not WorldMapButton then return end
    self.frame = CreateFrame("Frame", nil, WorldMapButton)
    self.frame:RegisterEvent("WORLD_MAP_UPDATE")
    self.frame:RegisterEvent("PLAYER_LEVEL_UP")
    self.frame:RegisterEvent("SKILL_LINES_CHANGED")
    self.frame:SetScript("OnEvent", function() Renderer:Refresh() end)
    QuestBeacon.Config:RegisterListener(self, function(owner, path)
        if string.find(path, "^worldMap") or string.find(path, "^availability") or path == "reset" then owner:Refresh() end
    end)
end
