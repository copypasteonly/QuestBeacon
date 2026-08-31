--[[
The directional sprite sheet at img/arrow.tga is reused from pfQuest.

MIT License

Copyright (c) 2017-2021 Eric Mauser (Shagu)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

QuestBeacon.Arrow = QuestBeacon.Arrow or {}
local Arrow = QuestBeacon.Arrow

local TWO_PI = math.pi * 2
local modulo = math.mod or math.fmod
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local CELL_COUNT = 108
local COLUMN_COUNT = 9
local CELL_WIDTH = 56 / 512
local CELL_HEIGHT = 42 / 512
local DEFAULT_POINT = "CENTER"
local DEFAULT_X = 0
local DEFAULT_Y = -100
local DEFAULT_SCALE = 1
local VALID_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true,
    LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

Arrow.lastTargetSignature = nil
Arrow.scaleTextUntil = 0

local function clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    elseif value > maximum then
        return maximum
    end
    return value
end

local function roundScale(value)
    return math.floor(clamp(tonumber(value) or DEFAULT_SCALE, 0.5, 3) * 10 + 0.5) / 10
end

function Arrow:EnsureSettings()
    QuestBeaconSettings = QuestBeaconSettings or {}
    local settings = QuestBeaconSettings
    if type(settings.point) ~= "string" or not VALID_POINTS[settings.point] then
        settings.point = DEFAULT_POINT
    end
    settings.x = tonumber(settings.x) or DEFAULT_X
    settings.y = tonumber(settings.y) or DEFAULT_Y
    settings.scale = roundScale(settings.scale)
    if settings.shown == nil then
        settings.shown = true
    end
    if settings.trackingMode ~= "auto" and settings.trackingMode ~= "quest" and
       settings.trackingMode ~= "manual" then
        settings.trackingMode = "auto"
    end
    return settings
end

function Arrow:NormalizeAngle(angle)
    local normalized = tonumber(angle) or 0
    while normalized < 0 do
        normalized = normalized + TWO_PI
    end
    while normalized >= TWO_PI do
        normalized = normalized - TWO_PI
    end
    return normalized
end

function Arrow:GetRelativeAngle(player, target)
    if not player or not target or player.x == nil or player.y == nil or
       target.x == nil or target.y == nil or player.facing == nil then
        return nil
    end
    local bearing = atan2(target.y - player.y, target.x - player.x)
    return self:NormalizeAngle(bearing - player.facing)
end

function Arrow:GetCell(angle)
    local normalized = self:NormalizeAngle(angle)
    return modulo(math.floor(normalized / TWO_PI * CELL_COUNT + 0.5), CELL_COUNT)
end

function Arrow:GetTexCoords(cell)
    local validated = modulo(math.floor(tonumber(cell) or 0), CELL_COUNT)
    local column = modulo(validated, COLUMN_COUNT)
    local row = math.floor(validated / COLUMN_COUNT)
    local left = column * CELL_WIDTH
    local right = (column + 1) * CELL_WIDTH
    local top = row * CELL_HEIGHT
    local bottom = (row + 1) * CELL_HEIGHT
    return left, right, top, bottom
end

function Arrow:GetDirectionColor(angle)
    local normalized = self:NormalizeAngle(angle)
    local signed = normalized
    if signed > math.pi then
        signed = signed - TWO_PI
    end
    local forward = 1 - math.abs(signed) / math.pi
    if forward < 0.5 then
        return 1, forward * 2, 0
    end
    return (1 - forward) * 2, 1, 0
end

function Arrow:ApplyPosition()
    local settings = self:EnsureSettings()
    self.frame:ClearAllPoints()
    self.frame:SetPoint(settings.point, UIParent, settings.point, settings.x, settings.y)
end

function Arrow:ApplyScale(showIndicator)
    local settings = self:EnsureSettings()
    settings.scale = roundScale(settings.scale)
    self.content:SetScale(settings.scale)
    if showIndicator then
        self.scaleText:SetText(string.format("%.1fx", settings.scale))
        self.scaleText:SetAlpha(1)
        self.scaleText:Show()
        self.scaleTextUntil = (type(GetTime) == "function" and GetTime() or 0) + 1.5
    end
end

function Arrow:SavePosition()
    local point, relativeTo, relativePoint, x, y = self.frame:GetPoint(1)
    local settings = self:EnsureSettings()
    settings.point = point or DEFAULT_POINT
    settings.x = tonumber(x) or DEFAULT_X
    settings.y = tonumber(y) or DEFAULT_Y
    self:ApplyPosition()
end

function Arrow:SaveTracking()
    local settings = self:EnsureSettings()
    settings.trackingMode = QuestBeacon.Navigation.trackingMode or "auto"
    settings.questID = QuestBeacon.Navigation.trackedQuestID
    settings.objectiveIndex = QuestBeacon.Navigation.trackedObjectiveIndex
end

function Arrow:RestoreTracking()
    local settings = self:EnsureSettings()
    if settings.trackingMode == "quest" and tonumber(settings.questID) then
        local restored = QuestBeacon.Navigation:SetTrackingMode(
            "quest", tonumber(settings.questID), tonumber(settings.objectiveIndex)
        )
        if restored then
            return
        end
    elseif settings.trackingMode == "manual" then
        QuestBeacon.Navigation:SetTrackingMode("manual")
        return
    end
    QuestBeacon.Navigation:SetTrackingMode("auto")
end

function Arrow:GetObjectiveDescription(target)
    local objective = target.objective or {}
    local description = objective.text or ""
    if description ~= "" then
        return description
    end
    if objective.kind == "item" then
        local name = nil
        if C_Item and type(C_Item.GetItemNameByID) == "function" then
            local rawName = C_Item.GetItemNameByID(objective.entryID)
            if rawName then
                name = tostring(rawName)
            end
        end
        local label = name or ("Item " .. tostring(objective.entryID or ""))
        local sourceLabels = {
            item_use = "use target", vendor = "vendor", drop = "drop",
            reference_loot = "reference loot", container = "container",
            fallback = "fallback",
        }
        local sourceLabel = sourceLabels[target.sourceType]
        if sourceLabel then
            label = label .. " - " .. sourceLabel
        end
        if objective.currentCount ~= nil and objective.requiredCount then
            label = label .. " " .. tostring(objective.currentCount) .. "/" .. tostring(objective.requiredCount)
        end
        return label
    elseif objective.kind == "monster" then
        return "Monster " .. tostring(objective.entryID or "")
    elseif objective.kind == "object" then
        return "Object " .. tostring(objective.entryID or "")
    end
    return "Navigation target"
end

function Arrow:UpdateTargetText(target)
    local signature = QuestBeacon.Navigation:CandidateSignature(target)
    if signature == self.lastTargetSignature then
        return
    end
    self.lastTargetSignature = signature
    local level = tonumber(target.quest.level) or 0
    local levelText = level > 0 and ("[" .. tostring(level) .. "] ") or ""
    self.title:SetText(levelText .. tostring(target.quest.title or ("Quest " .. tostring(target.quest.id))))
    self.description:SetText(self:GetObjectiveDescription(target))
end

function Arrow:Refresh(state)
    local settings = self:EnsureSettings()
    local navigationState = state or QuestBeacon.Navigation:GetState()
    if settings.shown and navigationState and navigationState.available and navigationState.target then
        self:UpdateTargetText(navigationState.target)
        self.frame:Show()
    else
        self.frame:Hide()
    end
end

function Arrow:Update()
    local state = QuestBeacon.Navigation:GetState()
    local settings = self:EnsureSettings()
    if not settings.shown or not state or not state.target then
        self.frame:Hide()
        return
    end
    local player = QuestBeacon.PositionService:GetPlayerPosition()
    if not player.available or player.mapID ~= state.target.mapID then
        self.frame:Hide()
        return
    end
    local angle = self:GetRelativeAngle(player, state.target)
    if angle == nil then
        self.frame:Hide()
        return
    end
    local left, right, top, bottom = self:GetTexCoords(self:GetCell(angle))
    self.model:SetTexCoord(left, right, top, bottom)
    local red, green, blue = self:GetDirectionColor(angle)
    self.model:SetVertexColor(red, green, blue, 1)
    local distance = QuestBeacon.PositionService:Distance2D(player, state.target)
    if not distance then
        self.frame:Hide()
        return
    end
    self.distance:SetText(string.format("Distance: %.1f yards", distance))
    self:UpdateTargetText(state.target)
    local now = type(GetTime) == "function" and GetTime() or 0
    if self.scaleText:IsVisible() and now >= self.scaleTextUntil then
        self.scaleText:Hide()
    end
end

function Arrow:Show()
    self:EnsureSettings().shown = true
    self:Refresh()
end

function Arrow:Hide()
    self:EnsureSettings().shown = false
    self.frame:Hide()
end

function Arrow:Reset()
    local settings = self:EnsureSettings()
    settings.point = DEFAULT_POINT
    settings.x = DEFAULT_X
    settings.y = DEFAULT_Y
    settings.scale = DEFAULT_SCALE
    settings.shown = true
    settings.trackingMode = "auto"
    settings.questID = nil
    settings.objectiveIndex = nil
    QuestBeacon.Navigation:SetTrackingMode("auto")
    self:ApplyPosition()
    self:ApplyScale(false)
    self:Refresh(QuestBeacon.Navigation:AutoResolve(false))
end

function Arrow:OnAddonLoaded()
    self:EnsureSettings()
    self:ApplyPosition()
    self:ApplyScale(false)
    self:RestoreTracking()
    self:Refresh()
end

function Arrow:Initialize()
    local frame = CreateFrame("Frame", "QuestBeaconArrowFrame", UIParent)
    self.frame = frame
    frame:SetWidth(208)
    frame:SetHeight(92)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:EnableMouseWheel(true)
    frame:RegisterForDrag("LeftButton")

    local content = CreateFrame("Frame", nil, frame)
    self.content = content
    content:SetWidth(208)
    content:SetHeight(92)
    content:SetPoint("TOP", frame, "TOP", 0, 0)

    local model = content:CreateTexture("QuestBeaconArrowTexture", "ARTWORK")
    self.model = model
    model:SetTexture("Interface\\AddOns\\QuestBeacon\\img\\arrow")
    model:SetWidth(48)
    model:SetHeight(36)
    model:SetPoint("TOP", content, "TOP", 0, 0)

    local title = content:CreateFontString("QuestBeaconArrowTitle", "OVERLAY", "GameFontNormal")
    self.title = title
    title:SetWidth(320)
    title:SetPoint("TOP", model, "BOTTOM", 0, -6)
    title:SetJustifyH("CENTER")
    title:SetTextColor(1, 0.8, 0, 1)

    local description = content:CreateFontString("QuestBeaconArrowDescription", "OVERLAY", "GameFontNormalSmall")
    self.description = description
    description:SetWidth(320)
    description:SetPoint("TOP", title, "BOTTOM", 0, -1)
    description:SetJustifyH("CENTER")
    description:SetTextColor(1, 0.9, 0.7, 1)

    local distance = content:CreateFontString("QuestBeaconArrowDistance", "OVERLAY", "GameFontNormalSmall")
    self.distance = distance
    distance:SetWidth(320)
    distance:SetPoint("TOP", description, "BOTTOM", 0, -1)
    distance:SetJustifyH("CENTER")
    distance:SetTextColor(0.7, 0.7, 0.7, 1)

    local scaleText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.scaleText = scaleText
    scaleText:SetPoint("BOTTOMRIGHT", model, "BOTTOMRIGHT", -2, 2)
    scaleText:SetTextColor(1, 1, 1, 1)
    scaleText:Hide()

    frame:SetScript("OnDragStart", function()
        if IsShiftKeyDown() then
            this.dragging = true
            this:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        if this.dragging then
            Arrow:SavePosition()
        end
    end)
    frame:SetScript("OnMouseUp", function()
        if this.dragging then
            this.dragging = nil
            return
        end
        if arg1 == "LeftButton" then
            QuestBeacon.Navigation:CycleTarget(1)
            Arrow:SaveTracking()
            Arrow:Refresh()
        elseif arg1 == "RightButton" then
            QuestBeacon.Navigation:SetTrackingMode("auto")
            Arrow:SaveTracking()
            Arrow:Refresh(QuestBeacon.Navigation:AutoResolve(false))
        end
    end)
    frame:SetScript("OnMouseWheel", function()
        if not IsShiftKeyDown() then
            return
        end
        local settings = Arrow:EnsureSettings()
        local direction = tonumber(arg1) or 0
        settings.scale = roundScale(settings.scale + (direction > 0 and 0.1 or -0.1))
        Arrow:ApplyScale(true)
    end)
    frame:SetScript("OnUpdate", function()
        Arrow:Update()
    end)

    self:ApplyPosition()
    self:ApplyScale(false)
    self:RestoreTracking()
    frame:Hide()
end

Arrow:Initialize()
