-- A session: some PCs, a relay between them, and the enemies each world has.

local Fake = dofile(SIM_DIR .. "/fakepc.lua")
local Relay = dofile(SIM_DIR .. "/simrelay.lua")

local Session = {}
Session.__index = Session
Session.Fake = Fake

-- four: true for FourPlayers = On, or a party size (6) for PartySize.
local function ini(role, four, extra)
    return "Role = " .. role .. "\nConnect = Tailscale\nHostAddress = 10.0.0.1\nOnlinePanel = On\nLanguage = English\nCoopEnemyHealth = 150\n"
        .. "CoopEnemyPosture = 130\nFourPlayers = " .. (four and "On" or "Off") .. "\n"
        .. (type(four) == "number" and ("PartySize = " .. four .. "\n") or "") .. "PartnerTeleport = Off\n" .. (extra or "")
end

-- roles: "Host", "Guest"... in the order they are PCs 1, 2...; enemies: { { id, class, x, y, z, hp, posture, boss }... }
-- The ini as it ships, for what a fresh install does.
function Session.shippedIni()
    local f = assert(io.open(SIM_REPO .. "/mod/PBZCoop/PhantomPact.ini", "rb"))
    local text = f:read("a")
    f:close()
    return text
end

function Session.new(scripts, roles, party, enemies, extraIni, wholeIni)
    local self = setmetatable({ pcs = {}, relay = Relay.new(party) }, Session)
    -- The relay says the version of these scripts, as a real build does.
    local main = assert(io.open(scripts .. "/main.lua", "rb"))
    self.relay.version = main:read("a"):match('local VERSION = "([^"]+)"')
    main:close()
    self.relay.mapOf = function(pc)
        local host = self.relay:host()
        return host and host ~= pc and host.map or (self.relay.slots[2] and self.relay.slots[2].map) or "-"
    end
    for i, role in ipairs(roles) do
        local link = {}
        local pc = Fake.new("pc" .. i, scripts, wholeIni or ini(role, party and i == 1 and party, extraIni), link)
        for k, v in pairs(self.relay:linkFor(pc)) do
            link[k] = v
        end
        self.relay:add(pc)
        for _, e in ipairs(enemies or {}) do
            Fake.enemy(pc, e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8])
        end
        Fake.pickup(pc, "pickup1", "R_500", 300.0, 0.0, 100.0)
        Fake.pickup(pc, "pickup2", "R_501", 90000.0, 0.0, 100.0)
        Fake.chest(pc, "BP_Chest_C_1", 400.0, 400.0, 100.0)
        self.pcs[i] = pc
    end
    for _, pc in ipairs(self.pcs) do
        Fake.start(pc)
    end
    return self
end

function Session:run(seconds, each)
    for _ = 1, math.floor(seconds * 60 + 0.5) do
        for _, pc in ipairs(self.pcs) do
            Fake.frame(pc, 1 / 60)
        end
        self.relay:step(self.pcs[1].now)
        if each then
            each()
        end
    end
end

-- The game starts loading a map.
function Session.loadMap(pc)
    for _, fn in ipairs(pc.loadMapHooks) do
        fn()
    end
end

function Session.moveTo(pc, x, y, z)
    Fake.put(pc.pawn, "loc", { X = x, Y = y, Z = z or 100.0 })
end

function Session.enemyOn(pc, id)
    local i = Session.indexOf(pc, id)
    return i and rawget(pc.spawners[i], "__fields").SpawnedAI or nil
end
Session.ini = ini

function Session.indexOf(pc, id)
    for i, spawner in ipairs(pc.spawners) do
        if rawget(spawner, "__fields").SpawnerID:ToString() == id then
            return i
        end
    end
end

function Session.command(pc, line)
    pc.files["cmd.txt"] = (pc.files["cmd.txt"] or "") .. line .. "\n"
end

-- What the game does when the player gets the money or an item, or starts a move.
function Session.gainDust(pc, amount)
    Fake.put(pc.pawn, "ConsciousnessDust", rawget(pc.pawn, "__fields").ConsciousnessDust + amount)
end

function Session.dust(pc)
    return rawget(pc.pawn, "__fields").ConsciousnessDust
end

function Session.gainItem(pc, id, count)
    pc.bag:AddPropsToBackPack(count or 1, pc.env.FName(id), true)
    -- (The game's own pickup shows its notice at once, and whatever waited with it: both calls, its animation through, then
    -- every card closed with Space, the lines after them.)
    pc.bag:TryToPushPickupUI()
    pc.bag:ReadyToPlayConfirmUI()
    for _ = 1, 20 do
        if not pc.cardUp then
            break
        end
        pc.closeCard()
    end
    pc.bag:TryToPushPickupUI()
end

function Session.items(pc, id)
    return rawget(pc.bag, "__fields").items[id] or 0
end

function Session.startMove(pc, path)
    local m = pc.env.StaticFindObject(path)
    Fake.put(pc.pawn.anim, "montage", m)
    Fake.put(pc.pawn.anim, "startedAt", pc.now)
end

function Session.endMove(pc)
    Fake.put(pc.pawn.anim, "montage", nil)
    Fake.put(pc.pawn.anim, "startedAt", nil)
end

function Session.enemyMove(pc, id, path)
    local e = Session.enemyOn(pc, id)
    Fake.put(rawget(e, "__fields").anim, "montage", path and pc.env.StaticFindObject(path) or nil)
end

function Session.hold(pc, weapon, armed)
    local w = rawget(pc.pawn, "__fields")["Character Weapons Component"]
    Fake.put(w, "config", pc.env.StaticFindObject(weapon))
    Fake.put(w, "armed", armed)
end

function Session.holdEdge(pc, weapon, armed)
    local w = rawget(pc.pawn, "__fields")["Character Weapons Component"]
    Fake.put(w, "edgeConfig", pc.env.StaticFindObject(weapon))
    Fake.put(w, "edgeArmed", armed)
end

function Session.edgeMove(pc, path)
    Fake.put(rawget(pc.pawn, "__fields").edgeAnim, "montage", pc.env.StaticFindObject(path))
end

-- Player 2's button, pressed for one frame and let go.
function Session.press2(s, key)
    local pc = s.pcs[1]
    pc.keys2[key] = true
    s:run(0.05)
    pc.keys2[key] = false
    s:run(0.05)
end

-- A story scene plays, or stops. name: its sequence's (none by default).
function Session.scene(pc, on, name)
    pc.scene = pc.scene or Fake.sceneManager(pc)
    Fake.put(pc.scene, "playing", on)
    -- (A scene takes the camera, as the game's camera cuts do: a sequence with the camera still on the player is no scene.)
    if pc.controller then
        pc.sceneCamera = pc.sceneCamera or { IsValid = function() return true end, GetAddress = function() return -77 end }
        Fake.put(pc.controller, "viewTarget", on and pc.sceneCamera or nil)
    end
    Fake.put(pc.scene, "sequence", on and name and { GetFName = function() return { ToString = function() return name end } end,
        IsValid = function() return true end } or nil)
end

-- A bullet in the game's list. solid: an actor, not one of the sweeps every swing makes.
function Session.bullet(pc, owner, path, x, y, z, solid, parent)
    local b = Fake.bullet(pc, owner, pc.env.StaticFindObject(path), x, y, z, solid ~= false, parent == true)
    return b
end

function Session.stagger(pc, tag)
    Fake.put(rawget(pc.pawn, "__fields").hit, "state", tag)
end

-- The game's refresh, as after resting at a bell or a death.
function Session.bell(pc)
    Fake.refreshMonsters(pc)
    for _, fn in ipairs(pc.hooks["/Game/PBZContent/Blueprint/BP_GameMode_Build.BP_GameMode_Build_C:Refresh Monster"]) do
        fn()
    end
end

-- A player sits at a bell: the game heals them, and runs no refresh.
function Session.sit(pc)
    pc.bell:RestoreHealth()
end

-- A player rings a bell for the first time: its first touch, then its sit. (A crane bell's scene follows.)
function Session.firstTouch(pc)
    for _, fn in ipairs(pc.hooks["/Game/PBZContent/Blueprint/Item/BP_MelodiousBell.BP_MelodiousBell_C:OnFirstTouchBell"] or {}) do
        fn()
    end
    Session.sit(pc)
end

function Session.respawned(pc)
    for _, fn in ipairs(pc.hooks["/Game/RenewalContent/Prototypes/Character/BP_RenewalPlayer.BP_RenewalPlayer_C:Respawn Refresh Monster"]) do
        fn()
    end
    Session.bell(pc)
end

function Session.die(pc)
    Fake.setHealth(pc.pawn, 0)
    Fake.put(pc.pawn, "dead", true)
end

function Session.revive(pc)
    Fake.setHealth(pc.pawn, 1000)
    Fake.put(pc.pawn, "dead", false)
end

return Session
