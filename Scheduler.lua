QuestBeacon.Scheduler = QuestBeacon.Scheduler or {}
local Scheduler = QuestBeacon.Scheduler

Scheduler.queue = {}
Scheduler.queueHead = 1
Scheduler.queueTail = 0
Scheduler.delayed = {}
Scheduler.keyed = {}
Scheduler.nextToken = 0
Scheduler.maxJobsPerFrame = 2
Scheduler.maxSecondsPerFrame = 0.004
Scheduler.errorLabels = {}
Scheduler.stats = {
    frames = 0,
    executed = 0,
    failed = 0,
    maxQueue = 0,
    maxJobsInFrame = 0,
    maxFrameSeconds = 0,
    slowestLabel = "none",
    slowestSeconds = 0,
}

local function now()
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

function Scheduler:PendingCount()
    local count = self.queueTail - self.queueHead + 1
    if count < 0 then return 0 end
    return count
end

function Scheduler:Cancel(key)
    if key == nil then return false end
    local entry = self.keyed[key]
    if not entry then return false end
    entry.cancelled = true
    self.keyed[key] = nil
    return true
end

function Scheduler:Enqueue(callback, label, key)
    if type(callback) ~= "function" then return nil end
    if key ~= nil then self:Cancel(key) end
    self.nextToken = self.nextToken + 1
    local entry = {callback=callback, label=label or "unlabelled", key=key, token=self.nextToken}
    self.queueTail = self.queueTail + 1
    self.queue[self.queueTail] = entry
    if key ~= nil then self.keyed[key] = entry end
    local pending = self:PendingCount()
    if pending > self.stats.maxQueue then self.stats.maxQueue = pending end
    return entry.token
end

function Scheduler:After(delay, callback, key)
    if type(callback) ~= "function" then return nil end
    if key ~= nil then self:Cancel(key) end
    self.nextToken = self.nextToken + 1
    local entry = {
        callback=callback,
        label=key and tostring(key) or "delayed",
        key=key,
        token=self.nextToken,
        remaining=tonumber(delay) or 0,
        delayed=true,
    }
    self.delayed[entry.token] = entry
    if key ~= nil then self.keyed[key] = entry end
    return entry.token
end

function Scheduler:ProcessDelayed(elapsed)
    local ready = {}
    local token, entry
    for token, entry in pairs(self.delayed) do
        if not entry.cancelled then
            entry.remaining = entry.remaining - elapsed
            if entry.remaining <= 0 then table.insert(ready, token) end
        else
            self.delayed[token] = nil
        end
    end
    table.sort(ready)
    local index
    for index = 1, table.getn(ready) do
        token = ready[index]
        entry = self.delayed[token]
        self.delayed[token] = nil
        if entry and not entry.cancelled then
            if entry.key ~= nil and self.keyed[entry.key] == entry then self.keyed[entry.key] = nil end
            -- Timers join the normal queue so a burst of due callbacks cannot bypass the frame budget.
            self:Enqueue(entry.callback, "timer:" .. tostring(entry.label), entry.key)
        end
    end
end

function Scheduler:ReportFailure(label, message)
    self.stats.failed = self.stats.failed + 1
    label = tostring(label or "unlabelled")
    if self.errorLabels[label] then return end
    self.errorLabels[label] = true
    if QuestBeacon and QuestBeacon.Print then
        QuestBeacon:Print("scheduled job failed (" .. label .. "): " .. tostring(message))
    end
end

function Scheduler:Tick()
    local pending = self:PendingCount()
    if pending <= 0 then return end
    local frameStart = now()
    local ran = 0
    local limit = math.min(pending, self.maxJobsPerFrame)
    while ran < limit and self.queueHead <= self.queueTail do
        local index = self.queueHead
        local entry = self.queue[index]
        self.queue[index] = nil
        self.queueHead = index + 1
        if entry and entry.key ~= nil and self.keyed[entry.key] == entry then self.keyed[entry.key] = nil end
        if entry and not entry.cancelled then
            local jobStart = now()
            local ok, message = pcall(entry.callback)
            local elapsed = now() - jobStart
            self.stats.executed = self.stats.executed + 1
            ran = ran + 1
            if elapsed > self.stats.slowestSeconds then
                self.stats.slowestSeconds = elapsed
                self.stats.slowestLabel = entry.label
            end
            if not ok then self:ReportFailure(entry.label, message) end
        end
        if ran > 0 and now() - frameStart >= self.maxSecondsPerFrame then break end
    end
    -- Reset the sparse queue after it drains; otherwise the monotonically increasing indexes live forever.
    if self.queueHead > self.queueTail then
        self.queue = {}
        self.queueHead = 1
        self.queueTail = 0
    end
    local frameSeconds = now() - frameStart
    self.stats.frames = self.stats.frames + 1
    if ran > self.stats.maxJobsInFrame then self.stats.maxJobsInFrame = ran end
    if frameSeconds > self.stats.maxFrameSeconds then self.stats.maxFrameSeconds = frameSeconds end
end

function Scheduler:GetStats()
    return self.stats
end

local frame = CreateFrame("Frame", "QuestBeaconSchedulerFrame", WorldFrame or UIParent)
Scheduler.frame = frame
frame:SetScript("OnUpdate", function()
    Scheduler:ProcessDelayed(tonumber(arg1) or 0)
    Scheduler:Tick()
end)
