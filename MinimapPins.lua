QuestBeacon.MinimapPins = QuestBeacon.MinimapPins or {}
local Renderer = QuestBeacon.MinimapPins

Renderer.pool = {}
Renderer.dirty = true
Renderer.spatial = {}

local BUCKET_SIZE = 500

local OUTDOOR_ZOOM = {[0]=300,[1]=240,[2]=180,[3]=120,[4]=80,[5]=50}
local INDOOR_ZOOM = {[0]=466.6666667,[1]=400,[2]=333.3333333,[3]=266.3333333,[4]=200,[5]=133.3333333}
local REFERENCE_ZOOM_YARDS = 120

local function safeGetCVar(name)
    if type(GetCVar) ~= "function" then return nil end
    -- Some 1.12 clients throw for unknown CVars instead of returning nil.
    local ok, value = pcall(GetCVar, name)
    if ok then return value end
    return nil
end

function Renderer:GetZoomYards()
    local zoom = tonumber(Minimap:GetZoom()) or 0
    local indoor = false
    if type(GetCVar) == "function" then
        local inside = tonumber(safeGetCVar("minimapInsideZoom"))
        local outside = tonumber(safeGetCVar("minimapZoom"))
        indoor = inside == zoom and inside ~= outside
    end
    return (indoor and INDOOR_ZOOM or OUTDOOR_ZOOM)[zoom] or 300
end

function Renderer:GetPinSize(pin, zoomYards)
    local cluster = pin and string.find(pin.texture or "", "^cluster_") ~= nil
    local referenceSize = cluster and 18 or 14
    local minimum = cluster and 10 or 9
    local maximum = cluster and 28 or 22
    local size = referenceSize * REFERENCE_ZOOM_YARDS / (tonumber(zoomYards) or REFERENCE_ZOOM_YARDS)
    return math.floor(math.max(minimum, math.min(maximum, size)) + 0.5)
end

function Renderer:ApplyPinSize(frame, pin, zoomYards, pinChanged)
    if not pinChanged and frame.sizeZoomYards == zoomYards then return end
    local size = self:GetPinSize(pin, zoomYards)
    if frame.pinSize ~= size then
        frame:SetWidth(size)
        frame:SetHeight(size)
        frame.pinSize = size
    end
    frame.sizeZoomYards = zoomYards
end

function Renderer:GetPin(index)
    if self.pool[index] then return self.pool[index] end
    local frame = CreateFrame("Button", nil, Minimap)
    frame:SetWidth(14) frame:SetHeight(14) frame:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    frame:RegisterForClicks("LeftButtonUp")
    frame.texture = frame:CreateTexture(nil, "ARTWORK") frame.texture:SetAllPoints(frame)
    frame:SetScript("OnClick", function() QuestBeacon.PinService:SelectPin(this.pin) end)
    frame:SetScript("OnEnter", function() Renderer:ShowTooltip(this) end)
    frame:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    self.pool[index] = frame
    return frame
end

function Renderer:ShowTooltip(frame)
    if not GameTooltip or not frame.pin then return end
    GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
    local associations = frame.pin.associations or {}
    local index
    for index = 1, table.getn(associations) do
        local row = associations[index]
        if index == 1 then GameTooltip:SetText("[" .. tostring(frame.pin.quest.level or 0) .. "] " .. tostring(row.title))
        else GameTooltip:AddLine(tostring(row.title), 1, 0.82, 0) end
        GameTooltip:AddLine(tostring(row.text or frame.pin.role), 0.85, 0.85, 0.85)
    end
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    local distance = QuestBeacon.PositionService:Distance2D(player, frame.pin)
    if distance then GameTooltip:AddLine(string.format("%.1f yards", distance), 0.5, 1, 0.5) end
    GameTooltip:Show()
end

function Renderer:RefreshData()
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    if player.available then QuestBeacon.PinService:Rebuild(player.areaID, "minimap") end
    self:BuildSpatialIndex()
    self.zoomYards = self:GetZoomYards()
    self.rotateMinimap = safeGetCVar("rotateMinimap") == "1"
    self.dirty = false
end

function Renderer:BuildSpatialIndex()
    self.spatial = {}
    local pins = QuestBeacon.PinService:GetMinimapPins()
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
end

function Renderer:RenderPin(pin, player, settings, width, height, zoomYards, radius, cosine, sine, shown)
    if not settings[pin.role] then return shown end
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
    end
    self:ApplyPinSize(frame, pin, zoomYards, pinChanged)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", Minimap, "CENTER", x, y)
    frame:Show()
    return shown
end

function Renderer:RefreshPositions()
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    if not player.available then
        local hidden
        for hidden = 1, table.getn(self.pool) do self.pool[hidden]:Hide() end
        return
    end
    local dataChanged = self.dirty
    if self.dirty then self:RefreshData() end
    local now = type(GetTime) == "function" and GetTime() or 0
    local facing = self.rotateMinimap and (player.facing or 0) or 0
    local zoomYards = self.zoomYards or self:GetZoomYards()
    local unchanged = not dataChanged and self.lastX == player.x and self.lastY == player.y and
        self.lastMapID == player.mapID and self.lastFacing == facing and self.lastZoomYards == zoomYards
    -- Movement stays frame-smooth; while standing still we only do the
    -- occasional safety refresh, matching pfQuest's minimap update behavior.
    if unchanged and now < (self.nextForcedRefresh or 0) then return end
    self.lastX = player.x
    self.lastY = player.y
    self.lastMapID = player.mapID
    self.lastFacing = facing
    self.lastZoomYards = zoomYards
    self.nextForcedRefresh = now + 1
    local width, height = Minimap:GetWidth(), Minimap:GetHeight()
    local radius = math.min(width, height) / 2 - 10
    local cosine, sine = math.cos(facing), math.sin(facing)
    local settings = QuestBeacon.Config:Get("minimap")
    local mapBuckets = self.spatial[player.mapID]
    local shown = 0
    if mapBuckets then
        local playerBucketX = math.floor(player.x / BUCKET_SIZE)
        local playerBucketY = math.floor(player.y / BUCKET_SIZE)
        local bucketX, bucketY
        for bucketX = playerBucketX - 1, playerBucketX + 1 do
            local column = mapBuckets[bucketX]
            if column then
                for bucketY = playerBucketY - 1, playerBucketY + 1 do
                    local bucket = column[bucketY]
                    if bucket then
                        local pinIndex
                        for pinIndex = 1, table.getn(bucket) do
                            shown = self:RenderPin(bucket[pinIndex], player, settings, width, height,
                                zoomYards, radius, cosine, sine, shown)
                        end
                    end
                end
            end
        end
    end
    local index
    for index = shown + 1, table.getn(self.pool) do self.pool[index]:Hide() end
end

function Renderer:MarkDirty()
    self.dirty = true
end

function Renderer:RefreshZoom()
    self.zoomYards = self:GetZoomYards()
    self.nextForcedRefresh = 0
    self:RefreshPositions()
end

function Renderer:Initialize()
    if self.frame then return end
    if not Minimap then return end
    self.frame = CreateFrame("Frame", nil, Minimap)
    self.frame:RegisterEvent("MINIMAP_UPDATE_ZOOM")
    self.frame:RegisterEvent("ZONE_CHANGED")
    self.frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self.frame:RegisterEvent("PLAYER_LEVEL_UP")
    self.frame:RegisterEvent("SKILL_LINES_CHANGED")
    self.frame:SetScript("OnEvent", function()
        if event == "MINIMAP_UPDATE_ZOOM" then
            -- Zoom changes only affect projection and hitbox size. Pin data and
            -- its spatial buckets remain valid, so there is no reason to query again.
            Renderer:RefreshZoom()
        else
            Renderer:MarkDirty()
            Renderer:RefreshPositions()
        end
    end)
    self.frame:SetScript("OnUpdate", function()
        Renderer:RefreshPositions()
    end)
    QuestBeacon.Config:RegisterListener(self, function(owner, path)
        if string.find(path, "^minimap") or string.find(path, "^availability") or path == "reset" then
            owner:MarkDirty() owner:RefreshPositions()
        end
    end)
    self:RefreshPositions()
end
