QuestBeacon.EventCoordinator = QuestBeacon.EventCoordinator or {}
local Coordinator = QuestBeacon.EventCoordinator

Coordinator.questDirty = false
Coordinator.initialRefresh = true
Coordinator.questSettleUntil = 0
Coordinator.nextQuestSettle = 0
Coordinator.corpseRefreshUntil = 0
Coordinator.nextCorpseRefresh = 0

function Coordinator:Now()
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

function Coordinator:StartQuestSettlement()
    local now = self:Now()
    self.questSettleUntil = now + 8
    self.nextQuestSettle = now
end

function Coordinator:MarkQuestDirty(logChanged)
    self.questDirty = true
    if QuestBeacon.QuestService and logChanged then
        QuestBeacon.QuestService:OnQuestLogChanged()
    end
end

function Coordinator:IsPlayerDeadOrGhost()
    if type(UnitIsDeadOrGhost) == "function" then
        return UnitIsDeadOrGhost("player") and true or false
    end
    local dead = type(UnitIsDead) == "function" and UnitIsDead("player")
    local ghost = type(UnitIsGhost) == "function" and UnitIsGhost("player")
    return dead and true or ghost and true or false
end

function Coordinator:GetNativeCorpsePosition()
    if type(GetCorpseMapPosition) ~= "function" or not QuestBeacon.DB then return nil end
    if type(C_Map) ~= "table" or type(C_Map.GetBestMapForUnit) ~= "function" then return nil end
    if type(SetMapToCurrentZone) == "function" and
       (not WorldMapFrame or not WorldMapFrame:IsVisible()) then
        SetMapToCurrentZone()
    end
    local rawAreaID = C_Map.GetBestMapForUnit("player")
    local areaID = tonumber(rawAreaID)
    local area = areaID and QuestBeacon.DB:GetArea(areaID) or nil
    if not area or area.mappingStatus ~= "mapped" or area.mapID == nil then return nil end
    if not area.locLeft or not area.locRight or not area.locTop or not area.locBottom then return nil end
    local rawX, rawY = GetCorpseMapPosition()
    local normalizedX, normalizedY = tonumber(rawX), tonumber(rawY)
    if not normalizedX or not normalizedY or normalizedX <= 0 or normalizedX > 1 or
       normalizedY <= 0 or normalizedY > 1 then return nil end
    local width = area.locLeft - area.locRight
    local height = area.locTop - area.locBottom
    if width == 0 or height == 0 then return nil end
    return {
        available=true, areaID=areaID, mapID=area.mapID,
        x=area.locTop - normalizedY * height,
        y=area.locLeft - normalizedX * width,
    }
end

function Coordinator:RefreshCorpseNavigation(allowPlayerFallback)
    if not QuestBeacon.Navigation then return false end
    local position = self:GetNativeCorpsePosition()
    if not position and allowPlayerFallback and QuestBeacon.PositionService then
        position = QuestBeacon.PositionService:FillPlayerMotion({}, false)
        if position.available and type(C_Map) == "table" and type(C_Map.GetBestMapForUnit) == "function" then
            local rawAreaID = C_Map.GetBestMapForUnit("player")
            position.areaID = tonumber(rawAreaID)
        end
    end
    if not position or not position.available then return false end
    return QuestBeacon.Navigation:StartCorpseNavigation(position)
end

function Coordinator:StartCorpseRefresh(allowPlayerFallback)
    local now = self:Now()
    self.corpseRefreshUntil = now + 10
    self.nextCorpseRefresh = now
    self:RefreshCorpseNavigation(allowPlayerFallback)
end

function Coordinator:ProcessFrame()
    if not QuestBeacon.enabled then
        return
    end
    local now = self:Now()
    if QuestBeacon.AvailabilityService then QuestBeacon.AvailabilityService:ProcessCompletionSync() end
    if self:IsPlayerDeadOrGhost() and self.corpseRefreshUntil > now and self.nextCorpseRefresh <= now then
        if self:RefreshCorpseNavigation(false) then
            self.corpseRefreshUntil = 0
        else
            self.nextCorpseRefresh = now + 0.25
        end
    end
    if not self.questDirty and self.questSettleUntil > now and self.nextQuestSettle <= now then
        self.questDirty = true
        self.nextQuestSettle = now + 0.25
    end
    if self.questDirty then
        self.questDirty = false
        local published = true
        if QuestBeacon.QuestService then
            local quests
            quests, published = QuestBeacon.QuestService:Refresh()
            if published and QuestBeacon.WatchService then
                QuestBeacon.WatchService:Refresh(QuestBeacon.QuestService:GetActiveQuests())
            end
            if published and QuestBeacon.AvailabilityService then
                QuestBeacon.AvailabilityService:ObserveQuestState(QuestBeacon.QuestService:GetActiveQuests())
            end
            local diagnostics = QuestBeacon.QuestService:GetDiagnostics()
            if published and diagnostics.resolvedQuestIDs > 0 then
                self.questSettleUntil = 0
            end
        end
        if published and QuestBeacon.Navigation and QuestBeacon.PositionService then
            QuestBeacon.Navigation:AutoResolve(self.initialRefresh)
        end
        if published and QuestBeacon.Tracker then QuestBeacon.Tracker:Refresh() end
        if published and QuestBeacon.WorldMapPins then QuestBeacon.WorldMapPins:Refresh() end
        if published and QuestBeacon.MinimapPins then QuestBeacon.MinimapPins:MarkDirty() end
        if published and QuestBeacon.QuestMobMarkers then QuestBeacon.QuestMobMarkers:Refresh() end
        if published then self.initialRefresh = false end
    elseif QuestBeacon.Navigation then
        QuestBeacon.Navigation:CheckAreaChange()
    end
end

function Coordinator:OnEvent(eventName, first, second)
    if eventName == "ADDON_LOADED" then
        if first == QuestBeacon.NAME then
            if QuestBeacon.Config then QuestBeacon.Config:Initialize() end
            QuestBeacon:Initialize()
            if QuestBeacon.QuestService then QuestBeacon.QuestService:Initialize() end
            if QuestBeacon.WatchService then QuestBeacon.WatchService:Initialize() end
            if QuestBeacon.QuestHistory then
                QuestBeacon.QuestHistory:Initialize()
            end
            if QuestBeacon.AvailabilityService then QuestBeacon.AvailabilityService:Initialize() end
            if QuestBeacon.Arrow then
                QuestBeacon.Arrow:OnAddonLoaded()
            end
            if QuestBeacon.Settings then QuestBeacon.Settings:Initialize() end
            if QuestBeacon.Tracker then QuestBeacon.Tracker:Initialize() end
            if QuestBeacon.WorldMapPins then QuestBeacon.WorldMapPins:Initialize() end
            if QuestBeacon.MinimapPins then QuestBeacon.MinimapPins:Initialize() end
            if QuestBeacon.QuestMobMarkers then QuestBeacon.QuestMobMarkers:Initialize() end
        end
        return
    end
    if eventName == "PLAYER_LOGOUT" then
        if QuestBeacon.DB then
            QuestBeacon.DB:Close()
        end
        return
    end
    if not QuestBeacon:Initialize() then
        return
    end
    if eventName == "PLAYER_ENTERING_WORLD" then
        if QuestBeacon.DB and not QuestBeacon.DB:Open() then
            return
        end
        if QuestBeacon.AvailabilityService then
            if type(QueryQuestsCompleted) == "function" and type(GetQuestsCompleted) == "function" then
                self.frame:RegisterEvent("QUEST_QUERY_COMPLETE")
            end
            QuestBeacon.AvailabilityService:RequestCompletedQuestSync()
        end
        self:StartQuestSettlement()
        self:MarkQuestDirty(true)
        if self:IsPlayerDeadOrGhost() then self:StartCorpseRefresh(false) end
    elseif eventName == "GOSSIP_SHOW" or eventName == "QUEST_GREETING" then
        if QuestBeacon.AvailabilityService and QuestBeacon.AvailabilityService:ObserveQuestgiver() then
            self:MarkQuestDirty(false)
        end
    elseif eventName == "QUEST_QUERY_COMPLETE" then
        if QuestBeacon.AvailabilityService and QuestBeacon.AvailabilityService:OnCompletedQuestQuery() then
            self:MarkQuestDirty(false)
        end
    elseif eventName == "CHAT_MSG_ADDON" then
        if QuestBeacon.AvailabilityService then
            QuestBeacon.AvailabilityService:OnServerQuestData(first, second)
        end
    elseif eventName == "QUEST_LOG_UPDATE" or eventName == "UNIT_QUEST_LOG_CHANGED" then
        self:MarkQuestDirty(true)
    elseif eventName == "BAG_UPDATE" then
        self:MarkQuestDirty(false)
    elseif eventName == "QUEST_TURNED_IN" then
        if QuestBeacon.QuestHistory and QuestBeacon.QuestHistory:RecordComplete(first, "turnin") then
            self:MarkQuestDirty(true)
        end
    elseif eventName == "PLAYER_LEVEL_UP" or eventName == "SKILL_LINES_CHANGED" then
        if QuestBeacon.AvailabilityService then QuestBeacon.AvailabilityService:Invalidate("player eligibility") end
        if QuestBeacon.WorldMapPins then QuestBeacon.WorldMapPins:Refresh() end
        if QuestBeacon.MinimapPins then QuestBeacon.MinimapPins:MarkDirty() end
    elseif eventName == "QUEST_DATA_LOAD_RESULT" then
        if QuestBeacon.QuestService then
            local pvpChanged = QuestBeacon.QuestService:OnQuestDataLoaded(
                tonumber(first), tonumber(second) == 1)
            if pvpChanged and QuestBeacon.WorldMapPins then
                QuestBeacon.WorldMapPins.filterRevision = QuestBeacon.WorldMapPins.filterRevision + 1
                QuestBeacon.WorldMapPins:Refresh()
            end
            if pvpChanged and QuestBeacon.MinimapPins then
                QuestBeacon.MinimapPins.filterRevision = QuestBeacon.MinimapPins.filterRevision + 1
                QuestBeacon.MinimapPins:MarkDirty()
            end
            self.questDirty = true
        end
    elseif eventName == "PLAYER_DEAD" then
        self:StartCorpseRefresh(true)
    elseif eventName == "PLAYER_ALIVE" then
        if self:IsPlayerDeadOrGhost() then
            self:StartCorpseRefresh(false)
        elseif QuestBeacon.Navigation then
            self.corpseRefreshUntil = 0
            QuestBeacon.Navigation:StopCorpseNavigation()
        end
    elseif eventName == "PLAYER_UNGHOST" then
        self.corpseRefreshUntil = 0
        if QuestBeacon.Navigation then QuestBeacon.Navigation:StopCorpseNavigation() end
    end
end

local frame = CreateFrame("Frame", "QuestBeaconEventFrame")
Coordinator.frame = frame
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GOSSIP_SHOW")
frame:RegisterEvent("QUEST_GREETING")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
frame:RegisterEvent("QUEST_DATA_LOAD_RESULT")
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_ALIVE")
frame:RegisterEvent("PLAYER_UNGHOST")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function()
    Coordinator:OnEvent(event, arg1, arg2)
end)
frame:SetScript("OnUpdate", function()
    Coordinator:ProcessFrame()
end)
