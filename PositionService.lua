QuestBeacon.PositionService = QuestBeacon.PositionService or {}
local PositionService = QuestBeacon.PositionService

local function unavailable(reason)
    return { available = false, reason = reason }
end

local function positiveInteger(value)
    local number = tonumber(value)
    if not number or number <= 0 or math.floor(number) ~= number then
        return nil
    end
    return number
end

function PositionService:GetPlayerPosition()
    local posY, posX, posZ, mapID = C_PlayerInfo.UnitPosition("player")
    if posY == nil or posX == nil or posZ == nil then
        return unavailable("player world position is unavailable")
    end
    if mapID == nil then
        return unavailable("player map ID is unavailable")
    end
    local areaID = C_Map.GetBestMapForUnit("player")
    if areaID == nil or tonumber(areaID) == nil or tonumber(areaID) <= 0 then
        return unavailable("player area ID is unavailable")
    end
    local facing = GetPlayerFacing()
    if facing == nil then
        return unavailable("player facing is unavailable")
    end
    return {
        available = true,
        x = tonumber(posX),
        y = tonumber(posY),
        z = tonumber(posZ),
        mapID = tonumber(mapID),
        areaID = tonumber(areaID),
        facing = tonumber(facing),
    }
end

function PositionService:GetVisibleObjectivePosition(kind, entryID)
    local validatedKind = positiveInteger(kind)
    local validatedID = positiveInteger(entryID)
    if not validatedKind or not validatedID then
        return unavailable("invalid entity kind or entry ID")
    end
    local finder = nil
    if validatedKind == QuestBeacon.DB.KIND_MONSTER then
        finder = ClosestUnitPosition
    elseif validatedKind == QuestBeacon.DB.KIND_OBJECT then
        finder = ClosestGameObjectPosition
    else
        return unavailable("unsupported entity kind")
    end
    if type(finder) ~= "function" then
        return unavailable("visible-position API is unavailable")
    end
    local x, y, distance = finder(validatedID)
    if x == nil or y == nil then
        return unavailable("objective is not currently visible")
    end
    local player = self:GetPlayerPosition()
    if not player.available then
        return unavailable(player.reason)
    end
    return {
        available = true,
        kind = validatedKind,
        entryID = validatedID,
        x = tonumber(x),
        y = tonumber(y),
        distance = tonumber(distance),
        mapID = player.mapID,
        areaID = player.areaID,
    }
end

function PositionService:Distance2D(first, second)
    if not first or not second or not first.available or not second.available then
        return nil, "position unavailable"
    end
    if first.mapID == nil or second.mapID == nil or first.mapID ~= second.mapID then
        return nil, "map mismatch"
    end
    if first.x == nil or first.y == nil or second.x == nil or second.y == nil then
        return nil, "world coordinates unavailable"
    end
    local deltaX = first.x - second.x
    local deltaY = first.y - second.y
    return math.sqrt(deltaX * deltaX + deltaY * deltaY), nil
end
