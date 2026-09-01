QuestBeacon.WorldMapPins = QuestBeacon.WorldMapPins or {}
local Renderer = QuestBeacon.WorldMapPins

Renderer.pool = {}
Renderer.filterRevision = 1
Renderer.renderGeneration = 0
Renderer.lastRenderKey = nil
Renderer.pendingRenderKey = nil
Renderer.waitingAreaID = nil
Renderer.stats = {received=0, skipped=0, requested=0, completed=0, lastPinCount=0}

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
                self:EnsureCurrent()
                return true
            end
        end
    end
    return false
end

function Renderer:GetViewedAreaID()
    if not C_Map or type(C_Map.GetMapAreaIDs) ~= "function" or type(GetMapInfo) ~= "function" then return nil end
    if type(GetCurrentMapZone) == "function" and tonumber(GetCurrentMapZone()) == 0 then return nil end
    local directory = GetMapInfo()
    if not directory then return nil end
    local areas = C_Map.GetMapAreaIDs()
    local direct = areas and areas[directory]
    if tonumber(direct) then return tonumber(direct) end
    local wanted = normalizedName(directory)
    local name, areaID
    for name, areaID in pairs(areas or {}) do
        if normalizedName(name) == wanted then return tonumber(areaID) end
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

function Renderer:HidePins()
    local index
    for index = 1, table.getn(self.pool) do self.pool[index]:Hide() end
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

function Renderer:RenderPlan(area, plan, renderKey)
    self.renderGeneration = self.renderGeneration + 1
    local generation = self.renderGeneration
    local state = {position=1, shown=0, pins=plan.pins, area=area, key=renderKey,
        width=WorldMapButton:GetWidth(), height=WorldMapButton:GetHeight()}
    self.pendingRenderKey = renderKey
    self.stats.requested = self.stats.requested + 1
    self:HidePins()
    local function step()
        if generation ~= Renderer.renderGeneration or Renderer.pendingRenderKey ~= renderKey then return end
        local count = 0
        while state.position <= table.getn(state.pins) and count < 30 do
            local pin = state.pins[state.position]
            state.position = state.position + 1
            count = count + 1
            if QuestBeacon.Config:Get("worldMap." .. pin.role) then
                local x, y = Renderer:Project(pin, state.area)
                if x and y then
                    state.shown = state.shown + 1
                    local frame = Renderer:GetPin(state.shown)
                    frame.pin = pin
                    frame.texture:SetTexture("Interface\\AddOns\\QuestBeacon\\img\\" .. pin.texture)
                    if pin.role == "available" or
                       (pin.role == "turnIns" and pin.quest and pin.quest.complete) then
                        frame.texture:SetVertexColor(1, 0.8, 0, 1)
                    else
                        frame.texture:SetVertexColor(1, 1, 1, 1)
                    end
                    frame:ClearAllPoints()
                    frame:SetPoint("CENTER", WorldMapButton, "TOPLEFT", x * state.width, -y * state.height)
                    frame:Show()
                end
            end
        end
        if state.position <= table.getn(state.pins) then
            QuestBeacon.Scheduler:Enqueue(step, "world map render", "world-map-render")
            return
        end
        local index
        for index = state.shown + 1, table.getn(Renderer.pool) do Renderer.pool[index]:Hide() end
        Renderer.lastRenderKey = renderKey
        Renderer.pendingRenderKey = nil
        Renderer.stats.completed = Renderer.stats.completed + 1
        Renderer.stats.lastPinCount = state.shown
    end
    QuestBeacon.Scheduler:Enqueue(step, "world map render", "world-map-render")
end

function Renderer:EnsureCurrent()
    if not WorldMapButton or not WorldMapFrame or not WorldMapFrame:IsVisible() then return end
    local areaID = self:GetViewedAreaID()
    local area = areaID and QuestBeacon.DB:GetArea(areaID) or nil
    if not area or area.mappingStatus ~= "mapped" then
        if self.lastRenderKey or self.pendingRenderKey then
            self.renderGeneration = self.renderGeneration + 1
            self.lastRenderKey = nil
            self.pendingRenderKey = nil
            self:HidePins()
        end
        self.currentAreaID = nil
        return
    end
    if self.currentAreaID ~= areaID then
        -- Never leave the previous zone's pins visible while its replacement plan is still being prepared.
        self.renderGeneration = self.renderGeneration + 1
        self.lastRenderKey = nil
        self.pendingRenderKey = nil
        self.currentAreaID = areaID
        self:HidePins()
    end
    QuestBeacon.PinService:RequestPlan(areaID)
    local plan = QuestBeacon.PinService:GetPlan(areaID)
    if not plan then
        if self.waitingAreaID == areaID then self.stats.skipped = self.stats.skipped + 1 end
        self.waitingAreaID = areaID
        return
    end
    self.waitingAreaID = nil
    local width, height = WorldMapButton:GetWidth(), WorldMapButton:GetHeight()
    local renderKey = table.concat({tostring(areaID), tostring(plan.identity), tostring(self.filterRevision),
        tostring(width), tostring(height)}, ":")
    if renderKey == self.lastRenderKey or renderKey == self.pendingRenderKey then
        self.stats.skipped = self.stats.skipped + 1
        return
    end
    self:RenderPlan(area, plan, renderKey)
end

function Renderer:Refresh()
    self:EnsureCurrent()
end

function Renderer:GetStats() return self.stats end

function Renderer:Initialize()
    if self.frame or not WorldMapButton then return end
    self.frame = CreateFrame("Frame", nil, WorldMapButton)
    self.frame:RegisterEvent("WORLD_MAP_UPDATE")
    self.frame:SetScript("OnEvent", function()
        Renderer.stats.received = Renderer.stats.received + 1
        Renderer:EnsureCurrent()
    end)
    QuestBeacon.Config:RegisterListener(self, function(owner, path)
        if string.find(path or "", "^worldMap") or path == "reset" then
            owner.filterRevision = owner.filterRevision + 1
            owner:EnsureCurrent()
        end
    end)
    QuestBeacon.PinService:RegisterListener(self, function(owner, areaID)
        if owner:GetViewedAreaID() == areaID then owner:EnsureCurrent() end
    end)
    local function onShow()
        Renderer:EnsureCurrent()
    end
    if WorldMapFrame.HookScript then
        WorldMapFrame:HookScript("OnShow", onShow)
    else
        local previous = WorldMapFrame:GetScript("OnShow")
        WorldMapFrame:SetScript("OnShow", function()
            if previous then previous() end
            onShow()
        end)
    end
end
