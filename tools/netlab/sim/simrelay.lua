-- The relay as the mod sees it, for fakepc.lua. native/ has its own tests (relay_cli test); this keeps to the same contract:
-- with two players, one partner and plain events; with a host's FourPlayers = On, slots, "@<slot> " on what a guest says, D and GK
-- for the host alone, and each guest's position passed to the others. Everything arrives LATENCY later, in order.

local Relay = {}
Relay.__index = Relay

local LATENCY = 0.02

function Relay.new(party)
    -- party: false (two players), true (4) or how many at most (6)
    local size = party == true and 4 or (type(party) == "number" and party or nil)
    return setmetatable({ party = size and true or false, size = size or 2, pcs = {}, slots = {}, queue = {}, order = 0, hello = {} }, Relay)
end

local function sample(pc, ...)
    return { ... }
end

-- The functions main.lua asks main.dll for.
function Relay:linkFor(pc)
    local relay = self
    local link = {}
    pc.heard, pc.inbox, pc.enemyLines, pc.sent = {}, {}, {}, {}
    function link.now() return pc.now end
    function link.wall() return pc.now end
    function link.state(...)
        local s = { ... }
        s.at = pc.now
        relay:post(pc, "sample", s)
    end
    function link.event(line)
        pc.sent[#pc.sent + 1] = "E " .. line
        relay:post(pc, "sure", line)
    end
    function link.quick(line)
        pc.sent[#pc.sent + 1] = "Q " .. line
        relay:post(pc, "quick", line)
    end
    function link.enemy(line)
        pc.sent[#pc.sent + 1] = "N " .. line
        relay:post(pc, "enemy", line)
    end
    function link.partner()
        return relay:reading(pc, pc.heard[1])
    end
    function link.events()
        if #pc.inbox == 0 then
            return nil
        end
        local text = table.concat(pc.inbox, "\n") .. "\n"
        pc.inbox = {}
        return text
    end
    function link.enemies()
        if #pc.enemyLines == 0 then
            return nil
        end
        local text = table.concat(pc.enemyLines, "\n") .. "\n"
        pc.enemyLines = {}
        return text
    end
    function link.status()
        return relay:status(pc)
    end
    function link.map(mapName)
        pc.mapName = mapName
        local h = 0
        for i = 1, #mapName do
            h = (h * 31 + mapName:byte(i)) % 4000000000
        end
        return h + 1
    end
    function link.reset()
        relay:reset(pc)
    end
    function link.stop()
        relay:leave(pc)
    end
    if relay.party ~= nil then
        function link.party()
            local players, slot = relay:partyOf(pc)
            if players then
                return players + 0.0, slot + 0.0      -- (numbers come from the DLL as floats)
            end
        end
        function link.player(slot)
            return relay:reading(pc, pc.heard[math.tointeger(slot) or slot])
        end
        function link.send_to(slot, line)
            pc.sent[#pc.sent + 1] = "T" .. slot .. " " .. line
            relay:toGuest(slot, "sure", line)
        end
    end
    return link
end

function Relay:reading(pc, s)
    if s == nil then
        return nil
    end
    return s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11], (pc.now - s.heardAt) * 1000, 4.0
end

function Relay:status(pc)
    local r = pc.relay
    if r == nil then
        return nil
    end
    local connected = false
    for _, other in ipairs(self.pcs) do
        if other ~= pc and other.relay and not other.cut and not pc.cut then
            connected = true
        end
    end
    local line = "role=" .. r .. " via=udp connected=" .. (connected and "yes" or "no") .. " peer=10.0.0.1:47800 rtt_ms=40 route=- rejected=0 auth=off"
        .. " version=" .. self.version .. " partner_version=" .. self.version .. " mismatch=- partner_map=" .. tostring(self.mapOf and self.mapOf(pc) or "-") .. " time=1"
    local players, slot = self:partyOf(pc)
    if players then
        line = line .. " players=" .. players .. " slot=" .. slot
        if pc.slot == 1 then
            for n = 2, 4 do
                if self.slots[n] then
                    line = line .. " map" .. n .. "=" .. self.slots[n].map
                end
            end
            if self.otherVersions then
                line = line .. " other_versions=" .. self.otherVersions
            end
        end
    end
    return line
end

function Relay:partyOf(pc)
    if self.party and pc.slot and (pc.slot == 1 or (self.hello[pc.slot] and pc.now >= self.hello[pc.slot])) then
        return self.size, pc.slot
    end
end

function Relay:later(to, kind, value, from)
    self.order = self.order + 1
    self.queue[#self.queue + 1] = { at = (from and from.now or to.now) + LATENCY, order = self.order, to = to, kind = kind, value = value, from = from }
end

function Relay:host()
    return self.slots[1]
end

function Relay:toGuest(slot, kind, value)
    local to = self.slots[slot]
    if to then
        self:later(to, kind, value, self:host())
    end
end

-- What a player's relay sends, to whoever it reaches.
function Relay:post(pc, kind, value)
    if not pc.slot or pc.cut then
        return
    end
    if not self.party then
        for _, other in ipairs(self.pcs) do
            if other ~= pc and other.slot and not other.cut then
                self:later(other, kind, value, pc)
            end
        end
    elseif pc.slot == 1 then
        for slot = 2, self.size do
            if self.slots[slot] and not self.slots[slot].cut then
                self:later(self.slots[slot], kind, value, pc)
            end
        end
    else
        local tag = "@" .. pc.slot .. " "
        local hostAlone = kind == "sure" and value:find("^D ")
        local tagged = (kind == "sure" or kind == "quick") and (tag .. value) or nil
        local host = self:host()
        if not host or host.cut then
            return                  -- (a star: nothing passes between guests but through the host)
        end
        self:later(host, kind == "sample" and "sampleOf" or kind, kind == "sample" and { slot = pc.slot, s = value } or tagged, pc)
        if kind == "enemy" or hostAlone then
            return
        end
        for slot = 2, self.size do
            local other = self.slots[slot]
            if other and other ~= pc and not other.cut then
                self:later(other, kind == "sample" and "sampleOf" or kind, kind == "sample" and { slot = pc.slot, s = value } or tagged, host or pc)
            end
        end
    end
end

function Relay:deliver(item)
    local pc, kind, value = item.to, item.kind, item.value
    if kind == "sample" then
        value.heardAt = pc.now
        pc.heard[1] = value
    elseif kind == "sampleOf" then
        value.s.heardAt = pc.now
        pc.heard[value.slot] = value.s
    elseif kind == "sure" or kind == "quick" then
        pc.inbox[#pc.inbox + 1] = value
    elseif kind == "enemy" then
        pc.enemyLines[#pc.enemyLines + 1] = value
    end
end

-- A relay is told to start by net_start.txt, as main.dll is.
function Relay:add(pc, joined)
    self.pcs[#self.pcs + 1] = pc
    pc.joinAt = joined or 0
end

function Relay:connect(pc)
    if pc.relay == "host" then
        pc.slot = 1
        self.slots[1] = pc
    else
        for slot = 2, self.size do
            if self.slots[slot] == nil and (self.party or slot == 2) then
                pc.slot = slot
                self.slots[slot] = pc
                break
            end
        end
    end
    local host = self.slots[1]
    if pc.relay ~= "host" and host and pc.slot then
        pc.inbox[#pc.inbox + 1] = "S"
        host.inbox[#host.inbox + 1] = self.party and ("@" .. pc.slot .. " S") or "S"
        self.hello[pc.slot] = pc.now + (self.helloLate or 0)     -- (a test can have it arrive after sync has started)
    end
end

function Relay:reset(pc)
    pc.inbox = {}
    pc.heard = {}
    if pc.slot == nil then
        return
    end
    for _, other in ipairs(self.pcs) do
        if other ~= pc and other.slot and not other.cut then
            if pc.slot == 1 then
                other.inbox[#other.inbox + 1] = "S"
            elseif other.slot == 1 then
                other.inbox[#other.inbox + 1] = self.party and ("@" .. pc.slot .. " S") or "S"
            end
        end
    end
end

function Relay:leave(pc)
    if pc.slot then
        self.slots[pc.slot] = nil
        pc.slot = nil
    end
    pc.relay = nil
    self.hello = {}
    for slot in pairs(self.slots) do
        if slot ~= 1 then
            self.hello[slot] = 0
        end
    end
end

function Relay:step(now)
    for _, pc in ipairs(self.pcs) do
        if pc.files["net_start.txt"] then
            pc.relay = pc.files["net_start.txt"]:match("role=(%w+)")
            pc.files["net_start.txt"] = nil
        end
    end
    -- The host first, whatever order they started in: a guest can only be answered by a host that's there.
    for _, pc in ipairs(self.pcs) do
        if pc.relay == "host" and not pc.slot and now >= pc.joinAt then
            self:connect(pc)
        end
    end
    for _, pc in ipairs(self.pcs) do
        if pc.relay and pc.relay ~= "host" and not pc.slot and now >= pc.joinAt and self.slots[1] then
            self:connect(pc)
        end
    end
    local keep = {}
    table.sort(self.queue, function(a, b)
        if a.at ~= b.at then
            return a.at < b.at
        end
        return a.order < b.order
    end)
    for _, item in ipairs(self.queue) do
        if item.at <= now then
            if not item.to.cut then
                self:deliver(item)
            end
        else
            keep[#keep + 1] = item
        end
    end
    self.queue = keep
end

return Relay
