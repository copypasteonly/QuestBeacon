QuestBeacon.MinimapPins = QuestBeacon.MinimapPins or {}
local Renderer = QuestBeacon.MinimapPins

Renderer.pool = {}
Renderer.spatial = {}
Renderer.activePins = {}
Renderer.motion = {}
Renderer.planDirty = true
Renderer.discoveryDirty = true
Renderer.filterRevision = 1
Renderer.stats = {discoveries=0, repositions=0, bucketBuilds=0, activeCandidates=0, areaChecks=0}

local BUCKET_SIZE = 500
local DISCOVERY_MULTIPLIER = 1.5
local REDISCOVER_MARGIN_FRACTION = 0.25
local AREA_CHECK_INTERVAL = 0.5
local SAFETY_REFRESH_INTERVAL = 1
local SERVICE_PIN_LEVEL_OFFSET = 5
local QUEST_PIN_LEVEL_OFFSET = 100

local OUTDOOR_ZOOM = {[0]=466.6666667,[1]=400,[2]=333.3333333,[3]=266.6666667,[4]=200,[5]=133.3333333}
local INDOOR_ZOOM = {[0]=300,[1]=240,[2]=180,[3]=120,[4]=80,[5]=50}
local REFERENCE_ZOOM_YARDS = 120

local function safeGetCVar(name)
    if type(GetCVar) ~= "function" then return nil end
    local ok, value = pcall(GetCVar, name)
    if ok then return value end
    return nil
end

local function now()
    if type(GetTime) == "function" then return GetTime() end
    return 0
end

local function durationText(seconds)
    if type(SecondsToTime) == "function" then return SecondsToTime(seconds) end
    if seconds >= 3600 then
        return string.format("%dh %dm", math.floor(seconds / 3600), math.floor(seconds / 60) - math.floor(seconds / 3600) * 60)
    elseif seconds >= 60 then
        return string.format("%dm %ds", math.floor(seconds / 60), seconds - math.floor(seconds / 60) * 60)
    end
    return tostring(seconds) .. "s"
end

local function respawnText(pin)
    local minimum = pin and (pin.respawnMinimumSeconds or pin.respawnSeconds)
    local maximum = pin and (pin.respawnMaximumSeconds or pin.respawnSeconds)
    if not minimum then return nil end
    if maximum and maximum ~= minimum then return durationText(minimum) .. " - " .. durationText(maximum) end
    return durationText(minimum)
end

function Renderer:GetZoomYards()
    local zoom = tonumber(Minimap:GetZoom()) or 0
    local inside = tonumber(safeGetCVar("minimapInsideZoom"))
    local outside = tonumber(safeGetCVar("minimapZoom"))
    local indoor = inside == zoom and inside ~= outside
    return (indoor and INDOOR_ZOOM or OUTDOOR_ZOOM)[zoom] or 300
end

function Renderer:GetZoomIndex()
    if not Minimap or type(Minimap.GetZoom) ~= "function" then return 0 end
    return tonumber(Minimap:GetZoom()) or 0
end

function Renderer:ObserveZoom()
    local zoomIndex = self:GetZoomIndex()
    if self.zoomIndex == zoomIndex then return false end
    self.zoomIndex = zoomIndex
    self.zoomYards = self:GetZoomYards()
    self.discoveryDirty = true
    self.nextForcedRefresh = 0
    return true
end

function Renderer:GetPinSize(pin, zoomYards)
    local cluster = pin and string.find(pin.texture or "", "^cluster_") ~= nil
    local spawn = pin and pin.pinType == "spawn"
    local referenceSize = spawn and 14 or (cluster and 20 or 16)
    local minimum = spawn and 10 or (cluster and 14 or 12)
    local maximum = spawn and 18 or (cluster and 28 or 24)
    local size = referenceSize * REFERENCE_ZOOM_YARDS / (tonumber(zoomYards) or REFERENCE_ZOOM_YARDS)
    return math.floor(math.max(minimum, math.min(maximum, size)) + 0.5)
end

function Renderer:ApplyPinSize(frame, pin, zoomYards, pinChanged)
    if not pinChanged and frame.sizeZoomYards == zoomYards then return end
    local size = self:GetPinSize(pin, zoomYards)
    if frame.pinSize ~= size then
        frame:SetWidth(size) frame:SetHeight(size) frame.pinSize = size
    end
    frame.sizeZoomYards = zoomYards
end

function Renderer:GetPin(index)
    if self.pool[index] then return self.pool[index] end
    local frame = CreateFrame("Button", nil, Minimap)
    frame:SetWidth(14) frame:SetHeight(14) frame:SetFrameLevel(Minimap:GetFrameLevel() + SERVICE_PIN_LEVEL_OFFSET)
    frame:RegisterForClicks("LeftButtonUp")
    frame.texture = frame:CreateTexture(nil, "ARTWORK") frame.texture:SetAllPoints(frame)
    frame:SetScript("OnClick", function()
        if this.pin and this.pin.role == "available" and type(IsShiftKeyDown) == "function" and IsShiftKeyDown() then
            QuestBeacon.MapQuestVisibility:PromptForPin(this.pin, "complete")
        elseif this.pin and this.pin.role ~= "service" and type(IsAltKeyDown) == "function" and IsAltKeyDown() then
            QuestBeacon.MapQuestVisibility:PromptForPin(this.pin, "hide")
        elseif this.pin and this.pin.role ~= "service" and this.pin.role ~= "available" then
            QuestBeacon.PinService:SelectPin(this.pin)
        end
    end)
    frame:SetScript("OnEnter", function() Renderer:ShowTooltip(this) end)
    frame:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    self.pool[index] = frame
    return frame
end

function Renderer:GetPinFrameLevel(pin)
    local offset = pin and pin.role == "service" and SERVICE_PIN_LEVEL_OFFSET or QUEST_PIN_LEVEL_OFFSET
    return Minimap:GetFrameLevel() + offset
end

function Renderer:HidePins()
    local index
    for index = 1, table.getn(self.pool) do self.pool[index]:Hide() end
end

function Renderer:ShowTooltip(frame)
    if not GameTooltip or not frame.pin then return end
    GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
    local associations = frame.pin.associations or {}
    local index
    if frame.pin.role == "service" then
        GameTooltip:SetText(tostring(frame.pin.name or "Service location"))
        for index = 1, table.getn(associations) do
            GameTooltip:AddLine(tostring(associations[index].text or "Service"), 0.85, 0.85, 0.85)
        end
        local player = QuestBeacon.PositionService:GetPlayerPosition()
        local distance = QuestBeacon.PositionService:Distance2D(player, frame.pin)
        if distance then GameTooltip:AddLine(string.format("%.1f yards", distance), 0.5, 1, 0.5) end
        GameTooltip:Show()
        return
    end
    for index = 1, table.getn(associations) do
        local row = associations[index]
        if index == 1 then GameTooltip:SetText("[" .. tostring(frame.pin.quest.level or 0) .. "] " .. tostring(row.title))
        else GameTooltip:AddLine(tostring(row.title), 1, 0.82, 0) end
        GameTooltip:AddLine(tostring(row.text or frame.pin.role), 0.85, 0.85, 0.85)
    end
    if frame.pin.pinType == "spawn" and (frame.pin.authoredCount or 1) > 1 then
        GameTooltip:AddLine(tostring(frame.pin.authoredCount) .. " authored spawns at this location", 0.65, 0.85, 1)
    end
    local respawn = frame.pin.pinType == "spawn" and respawnText(frame.pin) or nil
    if respawn then GameTooltip:AddLine("Respawn: " .. respawn, 0.75, 0.85, 1) end
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    local distance = QuestBeacon.PositionService:Distance2D(player, frame.pin)
    if distance then GameTooltip:AddLine(string.format("%.1f yards", distance), 0.5, 1, 0.5) end
    if frame.pin.role == "available" then GameTooltip:AddLine("Shift-click to mark complete", 0.7, 0.7, 0.7) end
    GameTooltip:AddLine("Alt-click to hide a quest", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function pinEnabled(pin, settings)
    if pin.role == "service" then return true end
    if type(settings) ~= "table" then
        settings = {objectives=true,itemSources=true,turnIns=true,available=true,
            spawnPoints=true,objectiveClusters=false}
    end
    if not settings[pin.role] then return false end
    if pin.pinType == "spawn" then return settings.spawnPoints and true or false end
    if pin.role == "objectives" or pin.role == "itemSources" then
        return settings.objectiveClusters and true or false
    end
    return true
end

function Renderer:BuildSpatialIndex(plan)
    self.spatial = {}
    local pins = plan and plan.pins or {}
    local index
    for index = 1, table.getn(pins) do
        local pin = pins[index]
        local mapBuckets = self.spatial[pin.mapID]
        if not mapBuckets then mapBuckets = {} self.spatial[pin.mapID] = mapBuckets end
        local bucketX = math.floor(pin.x / BUCKET_SIZE)
        local bucketY = math.floor(pin.y / BUCKET_SIZE)
        if not mapBuckets[bucketX] then mapBuckets[bucketX] = {} end
        if not mapBuckets[bucketX][bucketY] then mapBuckets[bucketX][bucketY] = {} end
        table.insert(mapBuckets[bucketX][bucketY], pin)
    end
    self.planIdentity = plan and plan.identity or nil
    self.stats.bucketBuilds = self.stats.bucketBuilds + 1
    self.discoveryDirty = true
end

function Renderer:RefreshArea(force)
    local currentTime = now()
    if not force and self.areaID and currentTime < (self.nextAreaCheck or 0) then return false end
    local rawAreaID = C_Map.GetBestMapForUnit("player")
    local areaID = tonumber(rawAreaID)
    self.nextAreaCheck = currentTime + AREA_CHECK_INTERVAL
    self.stats.areaChecks = self.stats.areaChecks + 1
    if not areaID or areaID <= 0 then return false end
    if self.areaID == areaID then return false end
    self.areaID = areaID
    self.planDirty = true
    self.discoveryDirty = true
    return true
end

function Renderer:RefreshRotation(force)
    local currentTime = now()
    if not force and currentTime < (self.nextRotationCheck or 0) then return false end
    self.nextRotationCheck = currentTime + SAFETY_REFRESH_INTERVAL
    local rotate = safeGetCVar("rotateMinimap") == "1"
    if self.rotateMinimap == rotate then return false end
    self.rotateMinimap = rotate
    self.discoveryDirty = true
    return true
end

function Renderer:RefreshPlan()
    if not self.areaID then return end
    QuestBeacon.PinService:RequestPlan(self.areaID)
    local plan = QuestBeacon.PinService:GetPlan(self.areaID)
    if not plan then
        if self.planAreaID ~= self.areaID then
            self.planAreaID = self.areaID
            self.planIdentity = nil
            self.activePins = {}
            self.spatial = {}
            self:HidePins()
        end
        return
    end
    if QuestBeacon.ServiceMarkerService then
        plan = QuestBeacon.ServiceMarkerService:GetCombinedPlan(self.areaID, "minimap", plan)
    end
    self.planAreaID = self.areaID
    if self.planIdentity ~= plan.identity then self:BuildSpatialIndex(plan) end
    self.planDirty = false
end

function Renderer:NeedsDiscovery(player, zoomYards)
    if self.discoveryDirty then return true end
    if self.discoveryMapID ~= player.mapID or self.discoveryAreaID ~= self.areaID then return true end
    if self.discoveryZoomYards ~= zoomYards or self.discoveryFilterRevision ~= self.filterRevision then return true end
    if self.discoveryRotate ~= self.rotateMinimap or self.discoveryPlanIdentity ~= self.planIdentity then return true end
    local deltaX = player.x - (self.discoveryX or player.x)
    local deltaY = player.y - (self.discoveryY or player.y)
    local visibleRadius = zoomYards / 2
    local margin = visibleRadius * (DISCOVERY_MULTIPLIER - 1)
    local threshold = margin * REDISCOVER_MARGIN_FRACTION
    return deltaX * deltaX + deltaY * deltaY >= threshold * threshold
end

function Renderer:Discover(player, zoomYards)
    local visibleRadius = zoomYards / 2
    local discoveryRadius = visibleRadius * DISCOVERY_MULTIPLIER
    local radiusSquared = discoveryRadius * discoveryRadius
    local bucketRange = math.ceil(discoveryRadius / BUCKET_SIZE) + 1
    local playerBucketX = math.floor(player.x / BUCKET_SIZE)
    local playerBucketY = math.floor(player.y / BUCKET_SIZE)
    local settings = QuestBeacon.Config:Get("minimap")
    local disabledMapQuests = QuestBeacon.Config:Get("disabledMapQuests")
    local active = {}
    local mapBuckets = self.spatial[player.mapID]
    if mapBuckets then
        local bucketX, bucketY
        for bucketX = playerBucketX - bucketRange, playerBucketX + bucketRange do
            local column = mapBuckets[bucketX]
            if column then
                for bucketY = playerBucketY - bucketRange, playerBucketY + bucketRange do
                    local bucket = column[bucketY]
                    if bucket then
                        local pinIndex
                        for pinIndex = 1, table.getn(bucket) do
                            local pin = bucket[pinIndex]
                            if QuestBeacon.MapQuestVisibility then
                                pin = QuestBeacon.MapQuestVisibility:FilterPin(pin, disabledMapQuests)
                            end
                            if pin and pinEnabled(pin, settings) then
                                local deltaX = pin.x - player.x
                                local deltaY = pin.y - player.y
                                if deltaX * deltaX + deltaY * deltaY <= radiusSquared then table.insert(active, pin) end
                            end
                        end
                    end
                end
            end
        end
    end
    self.activePins = active
    self.discoveryX = player.x self.discoveryY = player.y
    self.discoveryMapID = player.mapID self.discoveryAreaID = self.areaID
    self.discoveryZoomYards = zoomYards self.discoveryFilterRevision = self.filterRevision
    self.discoveryRotate = self.rotateMinimap self.discoveryPlanIdentity = self.planIdentity
    self.discoveryDirty = false
    self.stats.discoveries = self.stats.discoveries + 1
    self.stats.activeCandidates = table.getn(active)
end

function Renderer:RenderPin(pin, player, width, height, zoomYards, radius, cosine, sine, shown)
    local east = (player.y - pin.y) * width / zoomYards
    local north = (pin.x - player.x) * height / zoomYards
    local x = east * cosine - north * sine
    local y = east * sine + north * cosine
    if x * x + y * y > radius * radius then return shown end
    shown = shown + 1
    local frame = self:GetPin(shown)
    local pinChanged = frame.pin ~= pin
    if pinChanged then
        frame.pin = pin
        frame.texture:SetTexture("Interface\\AddOns\\QuestBeacon\\img\\" .. pin.texture)
        if pin.pinType == "spawn" then
            frame.texture:SetVertexColor(pin.colorR, pin.colorG, pin.colorB, 1)
        elseif pin.role == "available" or
           (pin.role == "turnIns" and pin.quest and pin.quest.complete) then
            frame.texture:SetVertexColor(1, 0.8, 0, 1)
        else
            frame.texture:SetVertexColor(1, 1, 1, 1)
        end
    end
    frame:SetFrameLevel(self:GetPinFrameLevel(pin))
    self:ApplyPinSize(frame, pin, zoomYards, pinChanged)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", Minimap, "CENTER", x, y)
    frame:Show()
    return shown
end

function Renderer:RefreshPositions()
    self:ObserveZoom()
    self:RefreshRotation(false)
    local player = QuestBeacon.PositionService:FillPlayerMotion(self.motion, self.rotateMinimap)
    if not player.available then self:HidePins() return end
    local mapChanged = self.lastMapID ~= player.mapID
    self:RefreshArea(mapChanged)
    if self.planDirty then self:RefreshPlan() end
    if not self.areaID or self.planAreaID ~= self.areaID then self:HidePins() return end
    local zoomYards = self.zoomYards or self:GetZoomYards()
    local discovered = false
    if self:NeedsDiscovery(player, zoomYards) then
        self:Discover(player, zoomYards)
        discovered = true
    end
    local currentTime = now()
    local facing = self.rotateMinimap and (player.facing or 0) or 0
    local unchanged = self.lastX == player.x and self.lastY == player.y and self.lastMapID == player.mapID and
        self.lastFacing == facing and self.lastZoomYards == zoomYards and not discovered
    if unchanged and currentTime < (self.nextForcedRefresh or 0) then return end
    self.lastX = player.x self.lastY = player.y self.lastMapID = player.mapID
    self.lastFacing = facing self.lastZoomYards = zoomYards
    self.nextForcedRefresh = currentTime + SAFETY_REFRESH_INTERVAL
    local width, height = Minimap:GetWidth(), Minimap:GetHeight()
    local radius = math.min(width, height) / 2 - 10
    local cosine, sine = math.cos(facing), math.sin(facing)
    local shown = 0
    local index
    for index = 1, table.getn(self.activePins) do
        shown = self:RenderPin(self.activePins[index], player, width, height, zoomYards,
            radius, cosine, sine, shown)
    end
    for index = shown + 1, table.getn(self.pool) do self.pool[index]:Hide() end
    self.stats.repositions = self.stats.repositions + 1
end

function Renderer:MarkDirty()
    self.planDirty = true
end

function Renderer:RefreshZoom()
    self.zoomIndex = nil
    self:ObserveZoom()
    self:RefreshPositions()
end

function Renderer:GetStats() return self.stats end

function Renderer:Initialize()
    if self.frame or not Minimap then return end
    self.frame = CreateFrame("Frame", nil, Minimap)
    self.frame:RegisterEvent("MINIMAP_UPDATE_ZOOM")
    self.frame:RegisterEvent("ZONE_CHANGED")
    self.frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self.frame:SetScript("OnEvent", function()
        if event == "MINIMAP_UPDATE_ZOOM" then
            Renderer:RefreshZoom()
        else
            Renderer:RefreshArea(true)
            Renderer:MarkDirty()
            Renderer:RefreshPositions()
        end
    end)
    self.frame:SetScript("OnUpdate", function() Renderer:RefreshPositions() end)
    QuestBeacon.Config:RegisterListener(self, function(owner, path)
        if string.find(path or "", "^minimap") or path == "disabledMapQuests" or path == "reset" then
            owner.filterRevision = owner.filterRevision + 1
            owner.planDirty = true
            owner.discoveryDirty = true
            owner:RefreshPositions()
        end
    end)
    QuestBeacon.PinService:RegisterListener(self, function(owner, areaID)
        if not owner.areaID or owner.areaID == areaID then owner:MarkDirty() end
    end)
    self:RefreshArea(true)
    self:RefreshPositions()
end
