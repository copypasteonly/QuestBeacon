QuestBeacon.WorldMapPins = QuestBeacon.WorldMapPins or {}
local Renderer = QuestBeacon.WorldMapPins

Renderer.pool = {}
Renderer.filterRevision = 1
Renderer.renderGeneration = 0
Renderer.lastRenderKey = nil
Renderer.pendingRenderKey = nil
Renderer.waitingAreaID = nil
Renderer.stats = {received=0, skipped=0, requested=0, completed=0, lastPinCount=0}

local MIN_ZOOM = 1
local MAX_ZOOM = 4
local ZOOM_STEP = 0.25
local DRAG_THRESHOLD = 3

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

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

function Renderer:GetPinDisplaySize(pin, zoom)
    local cluster = pin and string.find(pin.texture or "", "^cluster_") ~= nil
    local maximum = cluster and 28 or 24
    local size = 18 + (maximum - 18) * ((tonumber(zoom) or MIN_ZOOM) - MIN_ZOOM) / (MAX_ZOOM - MIN_ZOOM)
    return math.floor(clamp(size, 18, maximum) + 0.5)
end

function Renderer:ApplyPinSize(frame)
    if not frame or not frame.pin then return end
    local zoom = self.zoom or MIN_ZOOM
    local mapScale = (self.baseScale or 1) * zoom
    local displaySize = self:GetPinDisplaySize(frame.pin, zoom)
    local localSize = displaySize / mapScale
    if frame.pinDisplaySize == displaySize and frame.pinMapScale == mapScale then return end
    frame:SetWidth(localSize) frame:SetHeight(localSize)
    frame.pinDisplaySize = displaySize
    frame.pinMapScale = mapScale
end

function Renderer:RefreshPinSizes()
    local index
    for index = 1, table.getn(self.pool) do
        local frame = self.pool[index]
        if frame:IsShown() then self:ApplyPinSize(frame) end
    end
end

function Renderer:GetScrollLimits(zoom)
    local width = self.mapWidth or self.viewportWidth or 0
    local height = self.mapHeight or self.viewportHeight or 0
    local mapScale = (self.baseScale or 1) * (tonumber(zoom) or self.zoom or MIN_ZOOM)
    local maximumX = (width * mapScale - (self.viewportWidth or 0)) / mapScale
    local maximumY = (height * mapScale - (self.viewportHeight or 0)) / mapScale
    return math.max(0, maximumX), math.max(0, maximumY)
end

function Renderer:SetScroll(x, y)
    if not self.viewport then return end
    local maximumX, maximumY = self:GetScrollLimits()
    self.scrollX = clamp(tonumber(x) or 0, 0, maximumX)
    self.scrollY = clamp(tonumber(y) or 0, 0, maximumY)
    self.viewport:SetHorizontalScroll(-self.scrollX)
    self.viewport:SetVerticalScroll(self.scrollY)
end

function Renderer:SetZoom(zoom, cursorX, cursorY)
    if not self.viewport or not WorldMapDetailFrame then return false end
    local oldZoom = self.zoom or MIN_ZOOM
    local newZoom = clamp(tonumber(zoom) or oldZoom, MIN_ZOOM, MAX_ZOOM)
    if newZoom == oldZoom then return false end
    local focusX = clamp(tonumber(cursorX) or self.viewportWidth / 2, 0, self.viewportWidth)
    local focusY = clamp(tonumber(cursorY) or self.viewportHeight / 2, 0, self.viewportHeight)
    local baseScale = self.baseScale or 1
    local oldScale = baseScale * oldZoom
    local newScale = baseScale * newZoom
    local mapX = (self.scrollX or 0) + focusX / oldScale
    local mapY = (self.scrollY or 0) + focusY / oldScale
    self.zoom = newZoom
    WorldMapDetailFrame:SetScale(newScale)
    self:SetScroll(mapX - focusX / newScale, mapY - focusY / newScale)
    self:RefreshPinSizes()
    self:ApplyPlayerIndicatorSize()
    return true
end

function Renderer:ResetZoom()
    if not self.viewport then return end
    self.zoom = MIN_ZOOM
    self.scrollX = 0 self.scrollY = 0
    self.dragging = false self.dragMoved = false self.suppressRightClick = false
    WorldMapDetailFrame:SetScale(self.baseScale or 1)
    self:SetScroll(0, 0)
    self:RefreshPinSizes()
    self:ApplyPlayerIndicatorSize()
end

function Renderer:GetCursorInViewport()
    if not self.viewport or type(GetCursorPosition) ~= "function" then return nil, nil end
    local scale = self.viewport:GetEffectiveScale()
    local left, top = self.viewport:GetLeft(), self.viewport:GetTop()
    if not scale or scale == 0 or not left or not top then return nil, nil end
    local cursorX, cursorY = GetCursorPosition()
    return cursorX / scale - left, top - cursorY / scale
end

function Renderer:HandleMouseWheel(delta)
    if not self.viewport or not MouseIsOver(self.viewport) then return end
    if type(IsControlKeyDown) == "function" and IsControlKeyDown() then return end
    if type(IsShiftKeyDown) == "function" and IsShiftKeyDown() then return end
    local cursorX, cursorY = self:GetCursorInViewport()
    self:SetZoom((self.zoom or MIN_ZOOM) + (tonumber(delta) or 0) * ZOOM_STEP, cursorX, cursorY)
end

function Renderer:StartPan()
    if not self.viewport or (self.zoom or MIN_ZOOM) <= MIN_ZOOM or type(GetCursorPosition) ~= "function" then return end
    local cursorX, cursorY = GetCursorPosition()
    local scale = self.viewport:GetEffectiveScale()
    if not scale or scale == 0 then return end
    self.dragging = true
    self.dragMoved = false
    self.suppressRightClick = false
    self.dragStartX = cursorX / scale self.dragStartY = cursorY / scale
    self.dragScrollX = self.scrollX or 0 self.dragScrollY = self.scrollY or 0
end

function Renderer:UpdatePan()
    if not self.dragging or type(GetCursorPosition) ~= "function" then return end
    local scale = self.viewport:GetEffectiveScale()
    if not scale or scale == 0 then return end
    local cursorX, cursorY = GetCursorPosition()
    local deltaX = cursorX / scale - self.dragStartX
    local deltaY = cursorY / scale - self.dragStartY
    if deltaX * deltaX + deltaY * deltaY >= DRAG_THRESHOLD * DRAG_THRESHOLD then self.dragMoved = true end
    local mapScale = (self.baseScale or 1) * (self.zoom or MIN_ZOOM)
    self:SetScroll(self.dragScrollX - deltaX / mapScale, self.dragScrollY + deltaY / mapScale)
end

function Renderer:StopPan()
    local moved = self.dragging and self.dragMoved
    if moved then self.suppressRightClick = true end
    self.dragging = false
    self.dragMoved = false
    return moved
end

function Renderer:IsWindowedMap()
    return tonumber(WORLDMAP_WINDOWED) == 1
end

function Renderer:GetViewportLayout(windowed)
    if windowed then return 702, 468, 2, -24, 0.7, -15, -20 end
    local compactWindow = false
    if type(IsAddOnLoaded) == "function" then
        compactWindow = IsAddOnLoaded("ShaguTweaks") or IsAddOnLoaded("pfUI")
    end
    return 1002, 668, 0, compactWindow and -48 or -70, 1, -60, -24
end

function Renderer:PositionMapAreaText(offsetY)
    if not WorldMapFrameAreaFrame then return end
    WorldMapFrameAreaFrame:SetParent(WorldMapFrame)
    WorldMapFrameAreaFrame:ClearAllPoints()
    WorldMapFrameAreaFrame:SetPoint("TOP", WorldMapFrame, "TOP", 0, offsetY)
    WorldMapFrameAreaFrame:SetFrameStrata("FULLSCREEN_DIALOG")
end

function Renderer:RefreshFixedOverlays()
    if not self.viewport then return end
    local coordinateOffset = self.coordinateOffset or -24
    if WorldMapButton.coords then
        WorldMapButton.coords:SetParent(WorldMapFrame)
        WorldMapButton.coords:Show()
        if WorldMapButton.coords.text then
            WorldMapButton.coords.text:ClearAllPoints()
            WorldMapButton.coords.text:SetPoint("BOTTOMLEFT", self.viewport, "BOTTOMLEFT", 10, coordinateOffset)
        end
    end
    if WorldMapButton.player then
        WorldMapButton.player:SetParent(WorldMapFrame)
        WorldMapButton.player:Show()
        if WorldMapButton.player.text then
            WorldMapButton.player.text:ClearAllPoints()
            WorldMapButton.player.text:SetPoint("BOTTOMRIGHT", self.viewport, "BOTTOMRIGHT", -10, coordinateOffset)
        end
    end
    local reveal = getglobal and getglobal("shagutweaks_mapreveal_onmap") or nil
    if reveal then
        reveal:SetParent(WorldMapFrame)
        reveal:SetFrameStrata("FULLSCREEN_DIALOG")
        reveal:ClearAllPoints()
        reveal:SetPoint("TOPLEFT", self.viewport, "TOPLEFT", 1, 19)
    end
end

function Renderer:ApplyPlayerIndicatorSize()
    if not self.playerIndicator or not WorldMapPlayer then return end
    local mapScale = (self.baseScale or 1) * (self.zoom or MIN_ZOOM)
    WorldMapPlayer:SetWidth(24 / mapScale)
    WorldMapPlayer:SetHeight(24 / mapScale)
end

function Renderer:EnsurePlayerIndicator()
    if not WorldMapPlayer or not WorldMapButton then return end
    WorldMapPlayer:SetParent(WorldMapButton)
    WorldMapPlayer:SetFrameLevel(WorldMapButton:GetFrameLevel() + 10)
    if not self.playerIndicator then
        self.playerIndicator = WorldMapPlayer:CreateTexture(nil, "OVERLAY")
        self.playerIndicator:SetTexture("Interface\\AddOns\\QuestBeacon\\img\\world_map_arrow")
        self.playerIndicator:SetAllPoints(WorldMapPlayer)
    end
    self:ApplyPlayerIndicatorSize()
end

function Renderer:UpdatePlayerIndicator()
    if not self.playerIndicator or not WorldMapPlayer or not WorldMapFrame:IsVisible() then return end
    if type(GetPlayerMapPosition) ~= "function" then self.playerIndicator:Hide() return end
    local rawX, rawY = GetPlayerMapPosition("player")
    local x, y = tonumber(rawX), tonumber(rawY)
    if not x or not y or x <= 0 or y <= 0 then
        self.playerIndicator:Hide()
        return
    end
    WorldMapPlayer:ClearAllPoints()
    WorldMapPlayer:SetPoint("CENTER", WorldMapButton, "TOPLEFT",
        x * WorldMapButton:GetWidth(), -y * WorldMapButton:GetHeight())
    if type(GetPlayerFacing) == "function" then
        local rawFacing = GetPlayerFacing()
        local facing = tonumber(rawFacing)
        if facing then
            local root = math.sqrt(2)
            local rightBottomX = 0.5 + math.cos(facing + 0.25 * math.pi) / root
            local rightBottomY = 0.5 + math.sin(facing + 0.25 * math.pi) / root
            local leftBottomX = 0.5 + math.cos(facing + 0.75 * math.pi) / root
            local leftBottomY = 0.5 + math.sin(facing + 0.75 * math.pi) / root
            local leftTopX = 0.5 + math.cos(facing + 1.25 * math.pi) / root
            local leftTopY = 0.5 + math.sin(facing + 1.25 * math.pi) / root
            local rightTopX = 0.5 + math.cos(facing - 0.25 * math.pi) / root
            local rightTopY = 0.5 + math.sin(facing - 0.25 * math.pi) / root
            self.playerIndicator:SetTexCoord(leftTopX, leftTopY, leftBottomX, leftBottomY,
                rightTopX, rightTopY, rightBottomX, rightBottomY)
        end
    end
    WorldMapPlayer:Show()
    self.playerIndicator:Show()
end

function Renderer:SuppressNativeMapModels()
    if WorldMapPing then
        if type(WorldMapPing.SetModelScale) == "function" then WorldMapPing:SetModelScale(0) end
        WorldMapPing:Hide()
        if not WorldMapPing.questBeaconSuppressed then
            WorldMapPing.questBeaconSuppressed = true
            WorldMapPing:SetScript("OnShow", function() this:Hide() end)
        end
    end
    local children = {WorldMapFrame:GetChildren()}
    local index
    for index = 1, table.getn(children) do
        local child = children[index]
        if child and type(child.GetFrameType) == "function" and child:GetFrameType() == "Model" and
           type(child.GetName) == "function" and not child:GetName() then
            child:Hide()
            if not child.questBeaconSuppressed then
                child.questBeaconSuppressed = true
                child:SetScript("OnShow", function() this:Hide() end)
            end
        end
    end
end

function Renderer:ConfigureViewport(windowed)
    if not self.viewport or not WorldMapDetailFrame or not WorldMapButton then return end
    local width, height, offsetX, offsetY, baseScale, areaOffset, coordinateOffset =
        self:GetViewportLayout(windowed)
    self.viewport:SetParent(WorldMapFrame)
    self.viewport:ClearAllPoints()
    self.viewport:SetWidth(width) self.viewport:SetHeight(height)
    self.viewport:SetPoint("TOP", WorldMapFrame, "TOP", offsetX, offsetY)
    WorldMapDetailFrame:SetParent(self.viewport)
    WorldMapDetailFrame:ClearAllPoints()
    WorldMapDetailFrame:SetPoint("TOPLEFT", self.viewport, "TOPLEFT", 0, 0)
    self.viewport:SetScrollChild(WorldMapDetailFrame)
    WorldMapButton:SetParent(WorldMapDetailFrame)
    WorldMapButton:ClearAllPoints()
    WorldMapButton:SetPoint("TOPLEFT", WorldMapDetailFrame, "TOPLEFT", 0, 0)
    WorldMapButton:SetScale(1)
    self.viewportWidth = width self.viewportHeight = height
    self.mapWidth = WorldMapDetailFrame:GetWidth() self.mapHeight = WorldMapDetailFrame:GetHeight()
    self.baseScale = baseScale self.coordinateOffset = coordinateOffset
    self.windowedMode = windowed and true or false
    self:PositionMapAreaText(areaOffset)
    self:ResetZoom()
    self:RefreshFixedOverlays()
    self:SuppressNativeMapModels()
    self:EnsurePlayerIndicator()
end

function Renderer:InstallWindowSizeHooks()
    if self.resizeHooksInstalled then return end
    self.resizeHooksInstalled = true
    if type(WorldMapFrame_Minimize) == "function" then
        local previousMinimize = WorldMapFrame_Minimize
        WorldMapFrame_Minimize = function()
            previousMinimize()
            Renderer:ConfigureViewport(true)
        end
    end
    if type(WorldMapFrame_Maximize) == "function" then
        local previousMaximize = WorldMapFrame_Maximize
        WorldMapFrame_Maximize = function()
            previousMaximize()
            Renderer:ConfigureViewport(false)
        end
    end
end

function Renderer:InstallZoomViewport()
    if self.viewport or not WorldMapDetailFrame or not WorldMapButton then return end
    local parent = WorldMapDetailFrame:GetParent()
    local point, relativeTo, relativePoint, offsetX, offsetY = WorldMapDetailFrame:GetPoint(1)
    local width, height = WorldMapDetailFrame:GetWidth(), WorldMapDetailFrame:GetHeight()
    if not parent or not point or not width or width <= 0 or not height or height <= 0 then return end

    local viewport = CreateFrame("ScrollFrame", nil, WorldMapFrame)
    viewport:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel())
    self.viewport = viewport
    self.mapWidth = width self.mapHeight = height
    self:ConfigureViewport(self:IsWindowedMap())
    self:InstallWindowSizeHooks()

    WorldMapFrame:EnableMouseWheel(true)
    local function onMouseWheel()
        Renderer:HandleMouseWheel(arg1)
    end
    if WorldMapFrame.HookScript then
        WorldMapFrame:HookScript("OnMouseWheel", onMouseWheel)
    else
        local previousWheel = WorldMapFrame:GetScript("OnMouseWheel")
        WorldMapFrame:SetScript("OnMouseWheel", function()
            if previousWheel then previousWheel() end
            onMouseWheel()
        end)
    end

    local previousDown = WorldMapButton:GetScript("OnMouseDown")
    WorldMapButton:SetScript("OnMouseDown", function()
        if previousDown then previousDown() end
        if arg1 == "RightButton" and MouseIsOver(Renderer.viewport) then Renderer:StartPan() end
    end)
    local previousUp = WorldMapButton:GetScript("OnMouseUp")
    WorldMapButton:SetScript("OnMouseUp", function()
        local suppress
        if arg1 == "RightButton" then
            suppress = Renderer:StopPan() or Renderer.suppressRightClick
            Renderer.suppressRightClick = false
        end
        if previousUp and not suppress then previousUp() end
    end)
    self.frame:SetScript("OnUpdate", function()
        Renderer:UpdatePlayerIndicator()
        if Renderer.dragging then
            if type(IsMouseButtonDown) == "function" and not IsMouseButtonDown("RightButton") then
                Renderer:StopPan()
            else
                Renderer:UpdatePan()
            end
        end
    end)
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
                    Renderer:ApplyPinSize(frame)
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
    self:RefreshFixedOverlays()
    if not WorldMapButton or not WorldMapFrame or not WorldMapFrame:IsVisible() then return end
    local areaID = self:GetViewedAreaID()
    if self.zoomAreaID ~= areaID then
        self.zoomAreaID = areaID
        self:ResetZoom()
    end
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
    self:InstallZoomViewport()
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
        local windowed = Renderer:IsWindowedMap()
        if Renderer.windowedMode ~= windowed then Renderer:ConfigureViewport(windowed) end
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
