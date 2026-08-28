QuestBeacon.EventCoordinator = QuestBeacon.EventCoordinator or {}
local Coordinator = QuestBeacon.EventCoordinator

Coordinator.questDirty = false
Coordinator.initialRefresh = true

function Coordinator:MarkQuestDirty(logChanged)
    self.questDirty = true
    if QuestBeacon.QuestService and logChanged then
        QuestBeacon.QuestService:OnQuestLogChanged()
    end
end

function Coordinator:ProcessFrame()
    if not QuestBeacon.enabled then
        return
    end
    if self.questDirty then
        self.questDirty = false
        if QuestBeacon.QuestService then
            QuestBeacon.QuestService:Refresh()
        end
        if QuestBeacon.Navigation and QuestBeacon.PositionService then
            QuestBeacon.Navigation:AutoResolve(self.initialRefresh)
        end
        self.initialRefresh = false
    elseif QuestBeacon.Navigation then
        QuestBeacon.Navigation:CheckAreaChange()
    end
end

function Coordinator:OnEvent(eventName, first, second)
    if eventName == "ADDON_LOADED" then
        if first == QuestBeacon.NAME then
            QuestBeacon:Initialize()
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
        self:MarkQuestDirty(true)
    elseif eventName == "QUEST_LOG_UPDATE" or eventName == "UNIT_QUEST_LOG_CHANGED" then
        if QuestBeacon.QuestService and QuestBeacon.QuestService.scanningHeaders then
            return
        end
        self:MarkQuestDirty(true)
    elseif eventName == "QUEST_DATA_LOAD_RESULT" then
        if QuestBeacon.QuestService then
            QuestBeacon.QuestService:OnQuestDataLoaded(tonumber(first), tonumber(second) == 1)
            self.questDirty = true
        end
    end
end

local frame = CreateFrame("Frame", "QuestBeaconEventFrame")
Coordinator.frame = frame
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
frame:RegisterEvent("QUEST_DATA_LOAD_RESULT")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function()
    Coordinator:OnEvent(event, arg1, arg2)
end)
frame:SetScript("OnUpdate", function()
    Coordinator:ProcessFrame()
end)
