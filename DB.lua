QuestBeacon.DB = QuestBeacon.DB or {}
local DB = QuestBeacon.DB

DB.KIND_MONSTER = 1
DB.KIND_OBJECT = 2
DB.handle = nil
DB.metadata = nil
DB.entityCache = {}
DB.itemSourceCache = {}
DB.itemUseCache = {}
DB.referenceLootCache = {}
DB.cacheSize = 0
DB.questIDs = nil

local function positiveInteger(value)
    local number = tonumber(value)
    if not number or number <= 0 or math.floor(number) ~= number then
        return nil
    end
    return number
end

local function nullableNumber(value)
    if value == nil then
        return nil
    end
    return tonumber(value)
end

local function booleanNumber(value)
    return tonumber(value) == 1
end

function DB:IsEntityKind(kind)
    return kind == self.KIND_MONSTER or kind == self.KIND_OBJECT
end

function DB:QueryRaw(sql)
    if not self.handle then
        return nil, nil, "database is not open"
    end
    local ok, columns, rows = pcall(HDB_QueryRaw, self.handle, sql)
    if not ok then
        QuestBeacon:Disable("database query failed: " .. tostring(columns))
        return nil, nil, tostring(columns)
    end
    return columns, rows, nil
end

function DB:ReadMetadata()
    local columns, rows, queryError = self:QueryRaw(
        "SELECT key,value FROM build_metadata ORDER BY key"
    )
    if queryError then
        return nil, queryError
    end
    local metadata = {}
    local rowCount = table.getn(rows)
    local index
    for index = 1, rowCount do
        local value = rows[index][2]
        metadata[rows[index][1]] = tonumber(value) or value
    end
    return metadata, nil
end

function DB:Open()
    if self.handle then
        return true
    end
    local ok, handleOrError = pcall(HDB_OpenAddon, "QuestBeacon", "db/questbeacon.db")
    if not ok then
        QuestBeacon:Disable("cannot open database: " .. tostring(handleOrError))
        return false
    end
    self.handle = handleOrError
    local metadata, metadataError = self:ReadMetadata()
    if not metadata then
        self:Close()
        QuestBeacon:Disable("cannot read database metadata: " .. tostring(metadataError))
        return false
    end
    if tonumber(metadata.schema_version) ~= QuestBeacon.SCHEMA_VERSION then
        local actual = metadata.schema_version or "missing"
        self:Close()
        QuestBeacon:Disable("database schema " .. actual .. " is not supported")
        return false
    end
    self.metadata = metadata
    return true
end

function DB:Close()
    if self.handle then
        pcall(HDB_Close, self.handle)
    end
    self.handle = nil
    self.metadata = nil
    self:ClearCache()
end

function DB:GetMetadata()
    if not self:Open() then
        return nil
    end
    return self.metadata
end

function DB:ClearCache()
    self.entityCache = {}
    self.itemSourceCache = {}
    self.itemUseCache = {}
    self.referenceLootCache = {}
    self.cacheSize = 0
    self.questIDs = nil
end

function DB:GetCacheSize()
    return self.cacheSize
end

function DB:GetQuestIDs()
    if self.questIDs then
        return self.questIDs, nil
    end
    if not self:Open() then
        return nil, QuestBeacon.disabledReason
    end
    local columns, rows, queryError = self:QueryRaw("SELECT id FROM quests ORDER BY id")
    if queryError then
        return nil, queryError
    end
    local questIDs = {}
    local index
    for index = 1, table.getn(rows) do
        local questID = positiveInteger(rows[index][1])
        if questID then
            table.insert(questIDs, questID)
        end
    end
    self.questIDs = questIDs
    return questIDs, nil
end

function DB:GetEntityClusters(kind, entryID)
    local validatedKind = positiveInteger(kind)
    local validatedID = positiveInteger(entryID)
    if not validatedKind or not self:IsEntityKind(validatedKind) or not validatedID then
        return nil, 0, "invalid entity kind or entry ID"
    end
    if not self:Open() then
        return nil, 0, QuestBeacon.disabledReason
    end
    local cacheKey = tostring(validatedKind) .. ":" .. tostring(validatedID)
    local cached = self.entityCache[cacheKey]
    if cached then
        return cached.clusters, cached.unusableCount, nil
    end
    local sql = "SELECT kind,entry_id,cluster_id,area_id,mapped_area_id,map_id," ..
        "world_x,world_y,map_x,map_y,point_count,radius,is_noise,conversion_status " ..
        "FROM entity_clusters WHERE kind=" .. validatedKind .. " AND entry_id=" .. validatedID ..
        " ORDER BY cluster_id"
    local columns, rows, queryError = self:QueryRaw(sql)
    if queryError then
        return nil, 0, queryError
    end
    local clusters = {}
    local unusableCount = 0
    local rowCount = table.getn(rows)
    local index
    for index = 1, rowCount do
        local row = rows[index]
        local worldX = nullableNumber(row[7])
        local worldY = nullableNumber(row[8])
        local mapID = nullableNumber(row[6])
        if worldX and worldY and mapID then
            table.insert(clusters, {
                kind = tonumber(row[1]),
                entryID = tonumber(row[2]),
                clusterID = tonumber(row[3]),
                areaID = tonumber(row[4]),
                mappedAreaID = nullableNumber(row[5]),
                mapID = mapID,
                x = worldX,
                y = worldY,
                mapX = tonumber(row[9]),
                mapY = tonumber(row[10]),
                pointCount = tonumber(row[11]),
                radius = tonumber(row[12]),
                isNoise = booleanNumber(row[13]),
                conversionStatus = row[14],
            })
        else
            unusableCount = unusableCount + 1
        end
    end
    self.entityCache[cacheKey] = { clusters = clusters, unusableCount = unusableCount }
    self.cacheSize = self.cacheSize + 1
    return clusters, unusableCount, nil
end

function DB:GetItemSources(itemID)
    local validatedID = positiveInteger(itemID)
    if not validatedID then
        return nil, "invalid item ID"
    end
    if not self:Open() then
        return nil, QuestBeacon.disabledReason
    end
    local cached = self.itemSourceCache[validatedID]
    if cached then
        return cached, nil
    end
    local columns, rows, queryError = self:QueryRaw(
        "SELECT item_id,source_kind,source_id,rate_pct,provenance FROM item_sources " ..
        "WHERE item_id=" .. validatedID .. " ORDER BY source_kind,source_id,provenance"
    )
    if queryError then
        return nil, queryError
    end
    local results = {}
    local index
    for index = 1, table.getn(rows) do
        local row = rows[index]
        table.insert(results, {
            itemID = tonumber(row[1]), sourceKind = tonumber(row[2]),
            sourceID = tonumber(row[3]), ratePct = tonumber(row[4]), provenance = row[5],
        })
    end
    self.itemSourceCache[validatedID] = results
    self.cacheSize = self.cacheSize + 1
    return results, nil
end

function DB:GetItemUseTargets(itemID)
    local validatedID = positiveInteger(itemID)
    if not validatedID then
        return nil, "invalid item ID"
    end
    if not self:Open() then
        return nil, QuestBeacon.disabledReason
    end
    local cached = self.itemUseCache[validatedID]
    if cached then
        return cached, nil
    end
    local columns, rows, queryError = self:QueryRaw(
        "SELECT item_id,target_kind,target_id FROM item_use_targets WHERE item_id=" ..
        validatedID .. " ORDER BY target_kind,target_id"
    )
    if queryError then
        return nil, queryError
    end
    local results = {}
    local index
    for index = 1, table.getn(rows) do
        local kind = positiveInteger(rows[index][2])
        local targetID = positiveInteger(rows[index][3])
        if kind and self:IsEntityKind(kind) and targetID then
            table.insert(results, {
                itemID = tonumber(rows[index][1]),
                kind = kind,
                entryID = targetID,
            })
        end
    end
    self.itemUseCache[validatedID] = results
    self.cacheSize = self.cacheSize + 1
    return results, nil
end

function DB:GetReferenceLootSources(referenceID)
    local validatedID = positiveInteger(referenceID)
    if not validatedID then
        return nil, "invalid reference-loot ID"
    end
    if not self:Open() then
        return nil, QuestBeacon.disabledReason
    end
    local cached = self.referenceLootCache[validatedID]
    if cached then
        return cached, nil
    end
    local columns, rows, queryError = self:QueryRaw(
        "SELECT reference_id,source_kind,source_id FROM reference_loot_sources WHERE reference_id=" ..
        validatedID .. " ORDER BY source_kind,source_id"
    )
    if queryError then
        return nil, queryError
    end
    local results = {}
    local index
    for index = 1, table.getn(rows) do
        local kind = positiveInteger(rows[index][2])
        local sourceID = positiveInteger(rows[index][3])
        if kind and self:IsEntityKind(kind) and sourceID then
            table.insert(results, {
                referenceID = tonumber(rows[index][1]),
                kind = kind,
                entryID = sourceID,
            })
        end
    end
    self.referenceLootCache[validatedID] = results
    self.cacheSize = self.cacheSize + 1
    return results, nil
end

function DB:GetQuestFallbackTargets(questID, objectiveIndex)
    local validatedQuestID = positiveInteger(questID)
    local validatedObjectiveIndex = nil
    if objectiveIndex ~= nil then
        validatedObjectiveIndex = positiveInteger(objectiveIndex)
        if not validatedObjectiveIndex then
            return nil, "invalid objective index"
        end
    end
    if not validatedQuestID then
        return nil, "invalid quest ID"
    end
    if not self:Open() then
        return nil, QuestBeacon.disabledReason
    end
    local objectiveClause = "objective_index IS NULL"
    if validatedObjectiveIndex then
        objectiveClause = "(" .. objectiveClause .. " OR objective_index=" .. validatedObjectiveIndex .. ")"
    end
    local columns, rows, queryError = self:QueryRaw(
        "SELECT quest_id,objective_index,source_kind,source_id,area_id,mapped_area_id,map_id," ..
        "world_x,world_y,map_x,map_y,conversion_status FROM quest_fallback_targets WHERE quest_id=" ..
        validatedQuestID .. " AND " .. objectiveClause .. " ORDER BY area_id,map_x,map_y,source_kind,source_id"
    )
    if queryError then
        return nil, queryError
    end
    local results = {}
    local index
    for index = 1, table.getn(rows) do
        local row = rows[index]
        if row[8] and row[9] and row[7] then
            table.insert(results, {
                questID = tonumber(row[1]), objectiveIndex = nullableNumber(row[2]),
                kind = tonumber(row[3]), entryID = tonumber(row[4]), areaID = tonumber(row[5]),
                mappedAreaID = nullableNumber(row[6]), mapID = tonumber(row[7]),
                x = tonumber(row[8]), y = tonumber(row[9]), mapX = tonumber(row[10]),
                mapY = tonumber(row[11]), conversionStatus = row[12], isFallback = true,
                clusterID = 0, pointCount = 1, radius = 0, isNoise = true,
            })
        end
    end
    return results, nil
end

function DB:GetQuestRelation(tableName, questID)
    local validatedQuestID = positiveInteger(questID)
    if not validatedQuestID then
        return nil, "invalid quest ID"
    end
    if tableName ~= "quest_starters" and tableName ~= "quest_enders" then
        return nil, "invalid quest relation"
    end
    if not self:Open() then
        return nil, QuestBeacon.disabledReason
    end
    local columns, rows, queryError = self:QueryRaw(
        "SELECT quest_id,source_kind,source_id FROM " .. tableName .. " WHERE quest_id=" ..
        validatedQuestID .. " ORDER BY source_kind,source_id"
    )
    if queryError then
        return nil, queryError
    end
    local results = {}
    local index
    for index = 1, table.getn(rows) do
        table.insert(results, {
            questID = tonumber(rows[index][1]),
            sourceKind = tonumber(rows[index][2]),
            sourceID = tonumber(rows[index][3]),
        })
    end
    return results, nil
end

function DB:GetQuestStarters(questID)
    return self:GetQuestRelation("quest_starters", questID)
end

function DB:GetQuestEnders(questID)
    return self:GetQuestRelation("quest_enders", questID)
end
