QuestBeacon.DB = QuestBeacon.DB or {}
local DB = QuestBeacon.DB

DB.KIND_MONSTER = 1
DB.KIND_OBJECT = 2
DB.handle = nil
DB.metadata = nil
DB.entityCache = {}
DB.spawnCache = {}
DB.spawnCacheOrder = {}
DB.spawnCacheCount = 0
DB.spawnCacheLimit = 64
DB.itemSourceCache = {}
DB.itemUseCache = {}
DB.referenceLootCache = {}
DB.cacheSize = 0
DB.questIDs = nil
DB.questCache = {}
DB.progressionCacheKey = nil
DB.progressionCache = nil
DB.areaCache = {}
DB.candidateAreaCache = {}
DB.starterAreaCache = {}
DB.serviceMarkerCache = {}
DB.stats = {
    queries=0, totalQuerySeconds=0, slowestQuerySeconds=0, slowestQuery="none",
    spawnCacheHits=0, spawnCacheMisses=0, spawnCacheEvictions=0,
}

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
    local started = type(GetTime) == "function" and GetTime() or 0
    local ok, columns, rows = pcall(HDB_QueryRaw, self.handle, sql)
    local finished = type(GetTime) == "function" and GetTime() or started
    local elapsed = finished - started
    local label = "other"
    if string.find(sql or "", "entity_spawn_points") then label = "entity spawn points"
    elseif string.find(sql or "", "entity_clusters") then label = "entity clusters"
    elseif string.find(sql or "", "item_sources") then label = "item sources"
    elseif string.find(sql or "", "reference_loot_sources") then label = "reference loot"
    elseif string.find(sql or "", "item_use_targets") then label = "item use targets" end
    self.stats.queries = self.stats.queries + 1
    self.stats.totalQuerySeconds = self.stats.totalQuerySeconds + elapsed
    if elapsed > self.stats.slowestQuerySeconds then
        self.stats.slowestQuerySeconds = elapsed
        self.stats.slowestQuery = label
    end
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
    self.spawnCache = {}
    self.spawnCacheOrder = {}
    self.spawnCacheCount = 0
    self.itemSourceCache = {}
    self.itemUseCache = {}
    self.referenceLootCache = {}
    self.cacheSize = 0
    self.questIDs = nil
    self.questCache = {}
    self.progressionCacheKey = nil
    self.progressionCache = nil
    self.areaCache = {}
    self.candidateAreaCache = {}
    self.starterAreaCache = {}
    self.serviceMarkerCache = {}
end

function DB:CacheSpawnResult(key, result)
    if self.spawnCache[key] then return end
    self.spawnCache[key] = result
    table.insert(self.spawnCacheOrder, key)
    self.spawnCacheCount = self.spawnCacheCount + 1
    self.cacheSize = self.cacheSize + 1
    if self.spawnCacheCount > self.spawnCacheLimit then
        local oldest = table.remove(self.spawnCacheOrder, 1)
        if oldest and self.spawnCache[oldest] then
            self.spawnCache[oldest] = nil
            self.spawnCacheCount = self.spawnCacheCount - 1
            self.cacheSize = self.cacheSize - 1
            self.stats.spawnCacheEvictions = self.stats.spawnCacheEvictions + 1
        end
    end
end

local SERVICE_CATEGORIES = {
    auctioneer=true, banker=true, battlemaster=true, flight=true, innkeeper=true,
    mailbox=true, meetingstone=true, repair=true, spirithealer=true,
    stablemaster=true, vendor=true,
}

function DB:GetServiceMarkersForArea(areaID, categories, faction)
    local id = positiveInteger(areaID)
    if not id then return nil, "invalid area ID" end
    local selected = {}
    local category
    for category in pairs(categories or {}) do
        if SERVICE_CATEGORIES[category] and categories[category] then table.insert(selected, category) end
    end
    table.sort(selected)
    if table.getn(selected) == 0 then return {}, nil end
    local factionCode = faction == "H" and "H" or faction == "A" and "A" or ""
    local cacheKey = tostring(id) .. ":" .. factionCode .. ":" .. table.concat(selected, ",")
    if self.serviceMarkerCache[cacheKey] then return self.serviceMarkerCache[cacheKey], nil end
    if not self:Open() then return nil, QuestBeacon.disabledReason end
    local quoted = {}
    local index
    for index = 1, table.getn(selected) do quoted[index] = "'" .. selected[index] .. "'" end
    local factionClause = "s.faction='AH'"
    if factionCode ~= "" then factionClause = "(s.faction='AH' OR s.faction='" .. factionCode .. "')" end
    local columns, rows, queryError = self:QueryRaw(
        "SELECT s.category,s.faction,c.kind,c.entry_id,c.cluster_id,c.area_id,c.mapped_area_id," ..
        "c.map_id,c.world_x,c.world_y,c.map_x,c.map_y,c.point_count,c.radius,c.is_noise," ..
        "c.conversion_status,e.name_en_us FROM service_markers s " ..
        "JOIN entity_clusters c ON c.kind=s.source_kind AND c.entry_id=s.source_id AND c.cluster_id=s.cluster_id " ..
        "JOIN entities e ON e.kind=s.source_kind AND e.entry_id=s.source_id " ..
        "WHERE s.area_id=" .. id .. " AND s.category IN (" .. table.concat(quoted, ",") .. ") AND " ..
        factionClause .. " ORDER BY c.kind,c.entry_id,c.cluster_id,s.category"
    )
    if queryError then return nil, queryError end
    local results = {}
    for index = 1, table.getn(rows) do
        local row = rows[index]
        table.insert(results, {category=row[1], faction=row[2], kind=tonumber(row[3]),
            entryID=tonumber(row[4]), clusterID=tonumber(row[5]), areaID=tonumber(row[6]),
            mappedAreaID=nullableNumber(row[7]), mapID=tonumber(row[8]), x=tonumber(row[9]),
            y=tonumber(row[10]), mapX=tonumber(row[11]), mapY=tonumber(row[12]),
            pointCount=tonumber(row[13]), radius=tonumber(row[14]), isNoise=booleanNumber(row[15]),
            conversionStatus=row[16], name=row[17]})
    end
    self.serviceMarkerCache[cacheKey] = results
    self.cacheSize = self.cacheSize + 1
    return results, nil
end

function DB:GetQuestInfo(questID)
    local id = positiveInteger(questID)
    if not id then return nil, "invalid quest ID" end
    if self.questCache[id] ~= nil then return self.questCache[id] or nil, nil end
    if not self:Open() then return nil, QuestBeacon.disabledReason end
    local columns, rows, queryError = self:QueryRaw(
        "SELECT id,level,min_level,race_mask,class_mask,quest_sort,skill_id,event_id,title_en_us " ..
        "FROM quests WHERE id=" .. id
    )
    if queryError then return nil, queryError end
    if table.getn(rows) == 0 then self.questCache[id] = false return nil, nil end
    local row = rows[1]
    local info = {
        id = tonumber(row[1]), level = tonumber(row[2]) or 0, minLevel = tonumber(row[3]) or 0,
        raceMask = tonumber(row[4]) or 255, classMask = tonumber(row[5]) or 0,
        questSort = nullableNumber(row[6]), skillID = nullableNumber(row[7]),
        eventID = nullableNumber(row[8]), title = row[9], prerequisites = {},
    }
    local prerequisiteColumns, prerequisiteRows, prerequisiteError = self:QueryRaw(
        "SELECT prerequisite_quest_id FROM quest_prerequisites WHERE quest_id=" .. id .. " ORDER BY ordinal"
    )
    if prerequisiteError then return nil, prerequisiteError end
    local index
    for index = 1, table.getn(prerequisiteRows) do
        table.insert(info.prerequisites, tonumber(prerequisiteRows[index][1]))
    end
    self.questCache[id] = info
    return info, nil
end

function DB:GetQuestPrerequisites(questID)
    local info, queryError = self:GetQuestInfo(questID)
    return info and info.prerequisites or {}, queryError
end

function DB:GetProgressedPastQuestIDs(activeQuestIDs)
    local unique = {}
    local ids = {}
    local index
    for index = 1, table.getn(activeQuestIDs or {}) do
        local id = positiveInteger(activeQuestIDs[index])
        if id and not unique[id] then
            unique[id] = true
            table.insert(ids, id)
        end
    end
    table.sort(ids)
    if table.getn(ids) == 0 then return {}, nil end
    local parts = {}
    for index = 1, table.getn(ids) do parts[index] = tostring(ids[index]) end
    local cacheKey = table.concat(parts, ",")
    if self.progressionCacheKey == cacheKey and self.progressionCache then
        return self.progressionCache, nil
    end
    if not self:Open() then return nil, QuestBeacon.disabledReason end
    -- An active successor proves a predecessor only along an unambiguous,
    -- single-prerequisite chain. Branching prerequisite groups are not enough
    -- evidence to decide which historical quest the player completed.
    local columns, rows, queryError = self:QueryRaw(
        "WITH RECURSIVE ancestry(id) AS (" ..
        "SELECT p.prerequisite_quest_id FROM quest_prerequisites p " ..
        "WHERE p.quest_id IN (" .. cacheKey .. ") AND " ..
        "(SELECT COUNT(*) FROM quest_prerequisites s WHERE s.quest_id=p.quest_id)=1 " ..
        "UNION SELECT p.prerequisite_quest_id FROM quest_prerequisites p " ..
        "JOIN ancestry a ON a.id=p.quest_id WHERE " ..
        "(SELECT COUNT(*) FROM quest_prerequisites s WHERE s.quest_id=p.quest_id)=1" ..
        ") SELECT id FROM ancestry ORDER BY id"
    )
    if queryError then return nil, queryError end
    local result = {}
    for index = 1, table.getn(rows) do
        local id = positiveInteger(rows[index][1])
        if id then result[id] = true end
    end
    self.progressionCacheKey = cacheKey
    self.progressionCache = result
    return result, nil
end

function DB:GetArea(areaID)
    local id = positiveInteger(areaID)
    if not id then return nil, "invalid area ID" end
    if self.areaCache[id] ~= nil then return self.areaCache[id] or nil, nil end
    if not self:Open() then return nil, QuestBeacon.disabledReason end
    local columns, rows, queryError = self:QueryRaw(
        "SELECT id,map_id,parent_area_id,name_en_us,world_map_area_id,loc_left,loc_right,loc_top,loc_bottom,mapping_status " ..
        "FROM areas WHERE id=" .. id
    )
    if queryError then return nil, queryError end
    if table.getn(rows) == 0 then self.areaCache[id] = false return nil, nil end
    local row = rows[1]
    local area = { id=tonumber(row[1]), mapID=tonumber(row[2]), parentAreaID=nullableNumber(row[3]),
        name=row[4], worldMapAreaID=nullableNumber(row[5]), locLeft=nullableNumber(row[6]),
        locRight=nullableNumber(row[7]), locTop=nullableNumber(row[8]), locBottom=nullableNumber(row[9]),
        mappingStatus=row[10] }
    self.areaCache[id] = area
    return area, nil
end

function DB:GetQuestCandidatesForArea(areaID)
    local id = positiveInteger(areaID)
    if not id then return nil, "invalid area ID" end
    if self.candidateAreaCache[id] then return self.candidateAreaCache[id], nil end
    if not self:Open() then return nil, QuestBeacon.disabledReason end
    local columns, rows, queryError = self:QueryRaw(
        "SELECT DISTINCT q.id,q.level,q.min_level,q.race_mask,q.class_mask,q.quest_sort," ..
        "q.skill_id,q.event_id,q.title_en_us FROM quest_area_candidates a " ..
        "JOIN quests q ON q.id=a.quest_id WHERE a.area_id=" .. id .. " ORDER BY q.id"
    )
    if queryError then return nil, queryError end
    local results = {}
    local byQuestID = {}
    local index
    for index = 1, table.getn(rows) do
        local row = rows[index]
        local candidate = {id=tonumber(row[1]), level=tonumber(row[2]) or 0,
            minLevel=tonumber(row[3]) or 0, raceMask=tonumber(row[4]) or 255,
            classMask=tonumber(row[5]) or 0, questSort=nullableNumber(row[6]),
            skillID=nullableNumber(row[7]), eventID=nullableNumber(row[8]),
            title=row[9], prerequisites={}}
        table.insert(results, candidate)
        byQuestID[candidate.id] = candidate
    end
    local prerequisiteColumns, prerequisiteRows, prerequisiteError = self:QueryRaw(
        "SELECT DISTINCT p.quest_id,p.prerequisite_quest_id,p.ordinal " ..
        "FROM quest_area_candidates a JOIN quest_prerequisites p ON p.quest_id=a.quest_id " ..
        "WHERE a.area_id=" .. id .. " ORDER BY p.quest_id,p.ordinal"
    )
    if prerequisiteError then return nil, prerequisiteError end
    for index = 1, table.getn(prerequisiteRows) do
        local prerequisite = prerequisiteRows[index]
        local candidate = byQuestID[tonumber(prerequisite[1])]
        if candidate then table.insert(candidate.prerequisites, tonumber(prerequisite[2])) end
    end
    self.candidateAreaCache[id] = results
    self.cacheSize = self.cacheSize + 1
    return results, nil
end

function DB:GetQuestStarterClustersForArea(areaID)
    local id = positiveInteger(areaID)
    if not id then return nil, "invalid area ID" end
    if self.starterAreaCache[id] then return self.starterAreaCache[id], nil end
    if not self:Open() then return nil, QuestBeacon.disabledReason end
    local columns, rows, queryError = self:QueryRaw(
        "SELECT a.quest_id,q.level,q.min_level,q.race_mask,q.class_mask,q.skill_id,q.event_id,q.title_en_us," ..
        "c.kind,c.entry_id,c.cluster_id,c.area_id,c.mapped_area_id,c.map_id,c.world_x,c.world_y," ..
        "c.point_count,c.radius,c.is_noise,c.conversion_status,e.name_en_us " ..
        "FROM quest_area_candidates a JOIN quests q ON q.id=a.quest_id " ..
        "JOIN entity_clusters c ON c.kind=a.source_kind AND c.entry_id=a.source_id AND c.cluster_id=a.cluster_id " ..
        "LEFT JOIN entities e ON e.kind=c.kind AND e.entry_id=c.entry_id " ..
        "WHERE a.area_id=" .. id .. " ORDER BY a.quest_id,c.kind,c.entry_id,c.cluster_id"
    )
    if queryError then return nil, queryError end
    local results = {}
    local index
    for index = 1, table.getn(rows) do
        local row = rows[index]
        table.insert(results, {questID=tonumber(row[1]), level=tonumber(row[2]) or 0,
            minLevel=tonumber(row[3]) or 0, raceMask=tonumber(row[4]) or 255,
            classMask=tonumber(row[5]) or 0, skillID=nullableNumber(row[6]), eventID=nullableNumber(row[7]),
            title=row[8], kind=tonumber(row[9]), entryID=tonumber(row[10]), clusterID=tonumber(row[11]),
            areaID=tonumber(row[12]), mappedAreaID=nullableNumber(row[13]), mapID=tonumber(row[14]),
            x=tonumber(row[15]), y=tonumber(row[16]), pointCount=tonumber(row[17]), radius=tonumber(row[18]),
            isNoise=booleanNumber(row[19]), conversionStatus=row[20], entityName=row[21]})
    end
    self.starterAreaCache[id] = results
    self.cacheSize = self.cacheSize + 1
    return results, nil
end

function DB:GetCacheSize()
    return self.cacheSize
end

function DB:GetStats()
    return self.stats
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

function DB:GetEntitySpawnPointsForScope(kind, entryID, scope, scopeID)
    local validatedKind = positiveInteger(kind)
    local validatedID = positiveInteger(entryID)
    local validatedScopeID = tonumber(scopeID)
    if not validatedKind or not self:IsEntityKind(validatedKind) or not validatedID or
        not validatedScopeID or math.floor(validatedScopeID) ~= validatedScopeID or validatedScopeID < 0 or
        (scope ~= "map" and scope ~= "area") then
        return nil, 0, "invalid entity spawn scope"
    end
    if not self:Open() then return nil, 0, QuestBeacon.disabledReason end
    local cacheKey = scope .. ":" .. tostring(validatedScopeID) .. ":" ..
        tostring(validatedKind) .. ":" .. tostring(validatedID)
    local cached = self.spawnCache[cacheKey]
    if cached then
        self.stats.spawnCacheHits = self.stats.spawnCacheHits + 1
        return cached.points, cached.unusableCount, nil
    end
    self.stats.spawnCacheMisses = self.stats.spawnCacheMisses + 1
    local scopeClause
    if scope == "map" then
        scopeClause = "map_id=" .. validatedScopeID
    else
        scopeClause = "(mapped_area_id=" .. validatedScopeID .. " OR (mapped_area_id IS NULL AND area_id=" ..
            validatedScopeID .. "))"
    end
    local columns, rows, queryError = self:QueryRaw(
        "SELECT kind,entry_id,spawn_id,cluster_id,area_id,mapped_area_id,map_id," ..
        "world_x,world_y,map_x,map_y,respawn_seconds,authored_count,conversion_status FROM entity_spawn_points " ..
        "WHERE kind=" .. validatedKind .. " AND entry_id=" .. validatedID .. " AND " .. scopeClause ..
        " ORDER BY cluster_id,spawn_id"
    )
    if queryError then return nil, 0, queryError end
    local points = {}
    local unusableCount = 0
    local index
    for index = 1, table.getn(rows) do
        local row = rows[index]
        local worldX = nullableNumber(row[8])
        local worldY = nullableNumber(row[9])
        local mapID = nullableNumber(row[7])
        if worldX and worldY and mapID then
            table.insert(points, {
                kind=tonumber(row[1]), entryID=tonumber(row[2]), spawnID=tonumber(row[3]),
                clusterID=tonumber(row[4]), parentClusterID=tonumber(row[4]), areaID=tonumber(row[5]),
                mappedAreaID=nullableNumber(row[6]), mapID=mapID, x=worldX, y=worldY,
                mapX=tonumber(row[10]), mapY=tonumber(row[11]), respawnSeconds=nullableNumber(row[12]),
                authoredCount=tonumber(row[13]) or 1,
                conversionStatus=row[14], pointCount=1, radius=0, isNoise=false,
            })
        else
            unusableCount = unusableCount + 1
        end
    end
    self:CacheSpawnResult(cacheKey, {points=points, unusableCount=unusableCount})
    return points, unusableCount, nil
end

function DB:GetEntitySpawnPoints(kind, entryID, mapID)
    return self:GetEntitySpawnPointsForScope(kind, entryID, "map", mapID)
end

function DB:GetEntitySpawnPointsForArea(kind, entryID, areaID)
    return self:GetEntitySpawnPointsForScope(kind, entryID, "area", areaID)
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
