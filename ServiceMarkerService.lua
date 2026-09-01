QuestBeacon.ServiceMarkerService = QuestBeacon.ServiceMarkerService or {}
local ServiceMarkers = QuestBeacon.ServiceMarkerService

ServiceMarkers.categories = {
    {key="auctioneer", label="Auctioneer"},
    {key="banker", label="Banker"},
    {key="battlemaster", label="Battlemaster"},
    {key="flight", label="Flight Master"},
    {key="innkeeper", label="Innkeeper"},
    {key="mailbox", label="Mailbox"},
    {key="meetingstone", label="Meeting Stone"},
    {key="repair", label="Repair"},
    {key="spirithealer", label="Spirit Healer"},
    {key="stablemaster", label="Stable Master"},
    {key="vendor", label="Vendor"},
}
ServiceMarkers.combined = {}
ServiceMarkers.plans = {}

local labels = {}
local priority = {}
local categoryIndex
for categoryIndex = 1, table.getn(ServiceMarkers.categories) do
    local category = ServiceMarkers.categories[categoryIndex]
    labels[category.key] = category.label
    priority[category.key] = categoryIndex
end

function ServiceMarkers:GetFaction()
    if type(UnitFactionGroup) ~= "function" then return "" end
    local rawFaction = UnitFactionGroup("player")
    local faction = rawFaction and string.lower(rawFaction) or ""
    if faction == "alliance" then return "A" end
    if faction == "horde" then return "H" end
    return ""
end

function ServiceMarkers:GetSelection(destination)
    local path = destination == "world" and "worldMapServices" or "minimapServices"
    local configured = QuestBeacon.Config:Get(path) or {}
    local selected = {}
    local keys = {}
    local index
    for index = 1, table.getn(self.categories) do
        local key = self.categories[index].key
        if configured[key] then selected[key] = true table.insert(keys, key) end
    end
    return selected, table.concat(keys, ",")
end

function ServiceMarkers:BuildPlan(areaID, destination)
    local selected, selectionKey = self:GetSelection(destination)
    local faction = self:GetFaction()
    local key = tostring(areaID) .. ":" .. faction .. ":" .. selectionKey
    if self.plans[key] then return self.plans[key] end
    if selectionKey == "" then
        self.plans[key] = {identity=key, pins={}}
        return self.plans[key]
    end
    local rows = QuestBeacon.DB:GetServiceMarkersForArea(areaID, selected, faction) or {}
    local pins = {}
    local byCluster = {}
    local index
    for index = 1, table.getn(rows) do
        local row = rows[index]
        local clusterKey = tostring(row.kind) .. ":" .. tostring(row.entryID) .. ":" .. tostring(row.clusterID)
        local existing = byCluster[clusterKey]
        local association = {title=row.name or (labels[row.category] .. " location"), text=labels[row.category]}
        if existing then
            table.insert(existing.associations, association)
            if (priority[row.category] or 99) < (priority[existing.category] or 99) then
                existing.category = row.category
                existing.texture = "tracking\\" .. row.category
            end
        else
            local pin = {role="service", category=row.category, texture="tracking\\" .. row.category,
                kind=row.kind, entryID=row.entryID, clusterID=row.clusterID, areaID=row.areaID,
                mappedAreaID=row.mappedAreaID, mapID=row.mapID, x=row.x, y=row.y,
                pointCount=row.pointCount, radius=row.radius, isNoise=row.isNoise,
                conversionStatus=row.conversionStatus, name=row.name, associations={association}}
            byCluster[clusterKey] = pin
            table.insert(pins, pin)
        end
    end
    self.plans[key] = {identity=key, pins=pins}
    return self.plans[key]
end

function ServiceMarkers:GetCombinedPlan(areaID, destination, questPlan)
    local servicePlan = self:BuildPlan(areaID, destination)
    local questIdentity = questPlan and questPlan.identity or 0
    local key = tostring(questIdentity) .. ":" .. servicePlan.identity
    local cached = self.combined[destination]
    if cached and cached.key == key then return cached.plan end
    local pins = {}
    local index
    local questPins = questPlan and questPlan.pins or {}
    for index = 1, table.getn(questPins) do table.insert(pins, questPins[index]) end
    for index = 1, table.getn(servicePlan.pins) do table.insert(pins, servicePlan.pins[index]) end
    local plan = {identity=key, pins=pins}
    self.combined[destination] = {key=key, plan=plan}
    return plan
end
