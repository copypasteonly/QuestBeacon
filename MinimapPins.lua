QuestBeacon.MinimapPins = QuestBeacon.MinimapPins or {}
local Renderer = QuestBeacon.MinimapPins

Renderer.pool = {}
Renderer.elapsed = 0
Renderer.dirty = true

local OUTDOOR_ZOOM = {[0]=300,[1]=240,[2]=180,[3]=120,[4]=80,[5]=50}
local INDOOR_ZOOM = {[0]=466.6666667,[1]=400,[2]=333.3333333,[3]=266.3333333,[4]=200,[5]=133.3333333}

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
    self.dirty = false
end

function Renderer:RefreshPositions()
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    if not player.available then
        local hidden
        for hidden = 1, table.getn(self.pool) do self.pool[hidden]:Hide() end
        return
    end
    if self.dirty then self:RefreshData() end
    local pins = QuestBeacon.PinService:GetMinimapPins()
    local width, height = Minimap:GetWidth(), Minimap:GetHeight()
    local zoomYards = self:GetZoomYards()
    local radius = math.min(width, height) / 2 - 10
    local rotate = safeGetCVar("rotateMinimap") == "1"
    local facing = rotate and (player.facing or 0) or 0
    local cosine, sine = math.cos(facing), math.sin(facing)
    local shown = 0
    local index
    for index = 1, table.getn(pins) do
        local pin = pins[index]
        if pin.mapID == player.mapID and QuestBeacon.Config:Get("minimap." .. pin.role) then
            local east = (player.y - pin.y) * width / zoomYards
            local north = (pin.x - player.x) * height / zoomYards
            local x = east * cosine - north * sine
            local y = east * sine + north * cosine
            if x * x + y * y <= radius * radius then
                shown = shown + 1
                local frame = self:GetPin(shown) frame.pin = pin
                frame.texture:SetTexture("Interface\\AddOns\\QuestBeacon\\img\\" .. pin.texture)
                frame:ClearAllPoints() frame:SetPoint("CENTER", Minimap, "CENTER", x, y) frame:Show()
            end
        end
    end
    for index = shown + 1, table.getn(self.pool) do self.pool[index]:Hide() end
end

function Renderer:MarkDirty()
    self.dirty = true
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
    self.frame:SetScript("OnEvent", function() Renderer:MarkDirty() Renderer:RefreshPositions() end)
    self.frame:SetScript("OnUpdate", function()
        Renderer.elapsed = Renderer.elapsed + (tonumber(arg1) or 0)
        if Renderer.elapsed >= 0.2 then Renderer.elapsed = 0 Renderer:RefreshPositions() end
    end)
    QuestBeacon.Config:RegisterListener(self, function(owner, path)
        if string.find(path, "^minimap") or string.find(path, "^availability") or path == "reset" then
            owner:MarkDirty() owner:RefreshPositions()
        end
    end)
    self:RefreshPositions()
end
