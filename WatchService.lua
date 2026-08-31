QuestBeacon.WatchService = QuestBeacon.WatchService or {}
local WatchService = QuestBeacon.WatchService

WatchService.activeByID = {}
WatchService.applying = false
WatchService.nativeTrackerHidden = false

local function positiveInteger(value)
    local number = tonumber(value)
    if not number or number <= 0 or math.floor(number) ~= number then return nil end
    return number
end

local function nativeQuestID(logIndex)
    if type(C_QuestLog) ~= "table" or type(C_QuestLog.GetQuestIDForLogIndex) ~= "function" then return nil end
    local value = C_QuestLog.GetQuestIDForLogIndex(logIndex)
    return positiveInteger(value)
end

function WatchService:IsAuthoritative(quest)
    return quest and not quest.logOrderUnavailable and positiveInteger(quest.logIndex) ~= nil
        and type(IsQuestWatched) == "function"
end

function WatchService:GetNativeState(quest)
    if not self:IsAuthoritative(quest) then return nil end
    local ok, value = pcall(IsQuestWatched, quest.logIndex)
    if not ok then return nil end
    return value and true or false
end

function WatchService:IsWatched(quest)
    if not quest then return false end
    local questID = positiveInteger(quest.id)
    if not questID then return false end
    local overrides = QuestBeacon.Config:Get("watchOverrides")
    local saved = QuestBeacon.Config:Get("watchedQuests")
    if overrides[questID] then return saved[questID] and true or false end
    local native = self:GetNativeState(quest)
    if native ~= nil then return native end
    return saved[questID] and true or false
end

function WatchService:NotifyChanged()
    if QuestBeacon.EventCoordinator then QuestBeacon.EventCoordinator:MarkQuestDirty(false) end
end

function WatchService:ApplyNative(quest, watched)
    local action = watched and AddQuestWatch or RemoveQuestWatch
    if type(action) ~= "function" then return false, "native quest-watch API is unavailable" end
    self.applying = true
    local ok = pcall(action, quest.logIndex)
    self.applying = false
    if not ok then return false, "native quest-watch API failed" end
    local actual = self:GetNativeState(quest)
    if actual ~= watched then return false, watched and "native watch limit reached" or "native unwatch failed" end
    return true, nil
end

function WatchService:SetWatched(questID, watched)
    local id = positiveInteger(questID)
    if not id then return false, "invalid quest ID" end
    local quest = self.activeByID[id]
    if not quest and QuestBeacon.QuestService then quest = QuestBeacon.QuestService:GetQuest(id) end
    if not quest then return false, "quest is not active" end
    local saved = QuestBeacon.Config:Get("watchedQuests")
    local overrides = QuestBeacon.Config:Get("watchOverrides")
    watched = watched and true or false
    if self:IsAuthoritative(quest) then
        local ok, reason = self:ApplyNative(quest, watched)
        local actual = self:GetNativeState(quest)
        saved[id] = actual and true or nil
        overrides[id] = nil
        QuestBeacon.Config:Set("watchedQuests", saved)
        QuestBeacon.Config:Set("watchOverrides", overrides)
        if not ok then return false, reason end
    else
        saved[id] = watched and true or nil
        overrides[id] = true
        QuestBeacon.Config:Set("watchedQuests", saved)
        QuestBeacon.Config:Set("watchOverrides", overrides)
    end
    self:NotifyChanged()
    return true, nil
end

function WatchService:QuestForLogIndex(logIndex)
    local questID = nativeQuestID(logIndex)
    if questID and self.activeByID[questID] then return self.activeByID[questID] end
    local id, quest
    for id, quest in pairs(self.activeByID) do
        if quest.logIndex == logIndex and not quest.logOrderUnavailable then return quest end
    end
    return nil
end

function WatchService:OnNativeWatchChanged(logIndex)
    if self.applying then return end
    local quest = self:QuestForLogIndex(positiveInteger(logIndex))
    if not quest then return end
    local actual = self:GetNativeState(quest)
    if actual == nil then return end
    local saved = QuestBeacon.Config:Get("watchedQuests")
    local overrides = QuestBeacon.Config:Get("watchOverrides")
    saved[quest.id] = actual and true or nil
    overrides[quest.id] = nil
    QuestBeacon.Config:Set("watchedQuests", saved)
    QuestBeacon.Config:Set("watchOverrides", overrides)
    self:NotifyChanged()
end

function WatchService:Refresh(activeQuests)
    local active = {}
    local index
    for index = 1, table.getn(activeQuests or {}) do
        local quest = activeQuests[index]
        active[quest.id] = quest
    end
    self.activeByID = active
    local saved = QuestBeacon.Config:Get("watchedQuests")
    local overrides = QuestBeacon.Config:Get("watchOverrides")
    local questID
    for questID in pairs(saved) do if not active[questID] then saved[questID] = nil end end
    for questID in pairs(overrides) do if not active[questID] then overrides[questID] = nil end end
    local quest
    for questID, quest in pairs(active) do
        if self:IsAuthoritative(quest) then
            if overrides[questID] then
                local requested = saved[questID] and true or false
                local ok = self:ApplyNative(quest, requested)
                local actual = self:GetNativeState(quest)
                saved[questID] = actual and true or nil
                overrides[questID] = nil
                if not ok then
                    QuestBeacon:Print("could not " .. (requested and "watch " or "unwatch ") .. "quest " .. tostring(questID))
                end
            else
                local native = self:GetNativeState(quest)
                saved[questID] = native and true or nil
            end
        end
    end
    QuestBeacon.Config:Set("watchedQuests", saved)
    QuestBeacon.Config:Set("watchOverrides", overrides)
end

function WatchService:HideNativeTracker()
    if not QuestBeacon.Config:Get("replaceNativeTracker") or not QuestBeacon.Config:Get("trackerShown") then
        self:RestoreNativeTracker()
        return
    end
    if QuestWatchFrame and QuestWatchFrame.IsVisible and QuestWatchFrame:IsVisible() then
        QuestWatchFrame:Hide()
        self.nativeTrackerHidden = true
    end
end

function WatchService:RestoreNativeTracker()
    if not self.nativeTrackerHidden then return end
    self.nativeTrackerHidden = false
    if not QuestWatchFrame then return end
    local count = 0
    if type(GetNumQuestWatches) == "function" then
        local value = GetNumQuestWatches()
        count = tonumber(value) or 0
    end
    if count > 0 then
        if type(QuestWatch_Update) == "function" then pcall(QuestWatch_Update) end
        QuestWatchFrame:Show()
    end
end

function WatchService:Initialize()
    if self.initialized then return end
    self.initialized = true
    self.originalAddQuestWatch = AddQuestWatch
    self.originalRemoveQuestWatch = RemoveQuestWatch
    if type(self.originalAddQuestWatch) == "function" then
        AddQuestWatch = function(logIndex)
            local result = WatchService.originalAddQuestWatch(logIndex)
            WatchService:OnNativeWatchChanged(logIndex)
            return result
        end
    end
    if type(self.originalRemoveQuestWatch) == "function" then
        RemoveQuestWatch = function(logIndex)
            local result = WatchService.originalRemoveQuestWatch(logIndex)
            WatchService:OnNativeWatchChanged(logIndex)
            return result
        end
    end
end
