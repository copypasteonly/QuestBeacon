QuestBeacon.PositionService = QuestBeacon.PositionService or {}
local PositionService = QuestBeacon.PositionService

local function unavailable(reason)
    return { available = false, reason = reason }
end

local function markUnavailable(result, reason)
    result.available = false
    result.reason = reason
    result.x = nil result.y = nil result.z = nil result.mapID = nil result.areaID = nil result.facing = nil
    return result
end

local function positiveInteger(value)
    local number = tonumber(value)
    if not number or number <= 0 or math.floor(number) ~= number then
        return nil
    end
    return number
end

function PositionService:FillPlayerMotion(result, includeFacing)
    result = result or {}
    local posY, posX, posZ, mapID = C_PlayerInfo.UnitPosition("player")
    posY = tonumber(posY)
    posX = tonumber(posX)
    posZ = tonumber(posZ)
    if posY == nil or posX == nil or posZ == nil then
        return markUnavailable(result, "player world position is unavailable")
    end
    mapID = tonumber(mapID)
    if mapID == nil then
        return markUnavailable(result, "player map ID is unavailable")
    end
    local facing = nil
    if includeFacing then
        facing = GetPlayerFacing()
        facing = tonumber(facing)
        if facing == nil then return markUnavailable(result, "player facing is unavailable") end
    end
    result.available = true
    result.reason = nil
    result.x = posX result.y = posY result.z = posZ result.mapID = mapID result.facing = facing
    return result
end

function PositionService:GetPlayerPosition()
    local result = self:FillPlayerMotion({}, true)
    if not result.available then return result end
    local areaID = C_Map.GetBestMapForUnit("player")
    areaID = tonumber(areaID)
    if areaID == nil or areaID <= 0 then
        return unavailable("player area ID is unavailable")
    end
    result.areaID = areaID
    return result
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
    x = tonumber(x)
    y = tonumber(y)
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
        x = x,
        y = y,
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
