-- What a PvP match shows (arena.lua drives it): the countdown, painted 三 二 一 and 斗 over a crimson ink circle; each foe on the
-- game's own boss health bar, its name text saying who, the score and the clock; the banners between rounds; and the game's
-- own death card for the fallen at the end. Pictures from art/make_pvp_art.py (art/pvp), each in the game's one-image widget
-- (hud.lua), placed every frame against the screen's size. (The user, 11-06: health bars in the game's own design.)

return function(api)
    local log, valid, hud = api.log, api.valid, api.hud
    local coop = api.coop

    local Z = 460
    local COUNT_SIZE = 300          -- the countdown's picture, against a screen 1080 high
    local BANNER_W, BANNER_H = 900, 150
    local BANNER_S = 2.6            -- a banner on screen this long
    -- The match's last screens, the winners' and the losers' made and played the same way (the user, 11-07: "Make both
    -- victory and defeat play same way", "without that black background and same size", "Make sure it doesn't stretch or
    -- expands"): the game's own dark edge over the scene, then the calligraphy fading in, each picture at its own shape and
    -- one size from start to end. Picture (a game path, or our own art by file name); height against the screen's (nil:
    -- all of it); down from the middle; seconds to come in.
    local DEATH_ART = "/Game/PBZContent/UI/InGame/Dead/"
    local CARDS = {
        lost = {
            { DEATH_ART .. "bg_dead.bg_dead", nil, 0, 0.5 },
            { DEATH_ART .. "T_UI_blood_Combine.T_UI_blood_Combine", 0.7, 0.02, 0.9 },
            { "/Game/PBZContent/UI/UINew/testplaceholder/yun.yun", 0.31, -0.12, 0.4 },
            { "/Game/PBZContent/UI/UINew/testplaceholder/ming.ming", 0.31, 0.14, 0.6 },
        },
        -- 生 over 还 (art/shenghuan.png, the gilded painting after the screen's own 殒命), as tall as 殒 and 命 together.
        won = {
            { DEATH_ART .. "bg_dead.bg_dead", nil, 0, 0.5 },
            { "shenghuan.png", 0.57, 0.01, 0.5 },
        },
    }

    local ui = {}
    local parts = {}                -- name -> { widget, tex, w, h }
    local screen = { w = 1920, h = 1080, s = 1 }
    local count = nil               -- { start, total, round, mode }: the countdown on screen
    local banner = nil              -- { tex, at, until }
    local fightAt = nil             -- 斗's moment
    local death = nil               -- { since, widgets }

    local function zh()
        return api.lang and api.lang.code == "zh"
    end

    -- A picture in the player's language, where it has one.
    local function worded(tex)
        return zh() and ("zh_" .. tex) or tex
    end

    local function measure()
        local pc = api.getPlayer1()
        if not valid(pc) then
            return false
        end
        local ok = pcall(function()
            local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
            local size, scale = lib:GetViewportSize(pc), lib:GetViewportScale(pc)
            screen.w, screen.h = size.X / scale, size.Y / scale
            screen.s = screen.h / 1080
        end)
        return ok
    end

    local function setTexture(p, tex)
        if p.tex == tex then
            return
        end
        local t = hud.texture(tex)
        if t then
            pcall(function()
                local img = p.widget.Circle
                img:SetBrushFromTexture(t, false)
                local b = img.Brush
                b.ImageSize = { X = p.w, Y = p.h }
                img:SetBrush(b)
            end)
            p.tex = tex
        end
    end

    -- A picture by name: made once (again after a map change, when the old widget has gone), then placed and shown each frame.
    local function part(name, tex, w, h, z)
        local p = parts[name]
        if p and (p.map ~= coop.net.localMap or not (api.status and api.status.onScreen(p.widget))) then
            parts[name], p = nil, nil
        end
        if not p then
            local widget = hud.newImage(tex, w, h, Z + (z or 0))
            if not widget then
                return nil
            end
            pcall(function() widget:SetVisibility(2) end)     -- hidden till put() can size it (see there)
            p = { widget = widget, tex = tex, w = w, h = h, map = coop.net.localMap }
            parts[name] = p
        end
        setTexture(p, tex)
        return p
    end

    -- Centred at x, y (screen units, 1080 high), drawn w x h, at opacity a and size k (1: as drawn).
    local function put(p, x, y, w, h, a, k)
        if not p then
            return
        end
        local s = screen.s * (k or 1)
        pcall(function()
            p.widget:SetPositionInViewport({ X = x * screen.s, Y = y * screen.s }, false)
            p.widget:SetRenderOpacity(a or 1)
        end)
        -- Shown only once sized: a new one isn't laid out yet in its first frame and drew at its own size (on the bench, a
        -- guest's countdown opened on a huge "PLAYER 1" over a red block). Hidden, not collapsed, so it gets laid out.
        if hud.fit(p.widget, (w or p.w) * s, (h or p.h) * s) then
            hud.show(p.widget, (a or 1) > 0.01)
        else
            pcall(function() p.widget:SetVisibility(2) end)
        end
    end

    -- A picture made on a map that's gone went with it: dropped untouched. (The review of 1.7.0: hidden with a bare valid()
    -- at every tick of the next match on another map, a gone widget "reads as valid for a while, and moving it crashed".)
    local function usable(p)
        return p.map == coop.net.localMap and api.status ~= nil and api.status.onScreen(p.widget)
    end

    local function hide(name)
        local p = parts[name]
        if p and usable(p) then
            hud.show(p.widget, false)
        elseif p then
            parts[name] = nil
        end
    end

    local function hideAll(prefix)
        for name, p in pairs(parts) do
            if not prefix or name:sub(1, #prefix) == prefix then
                if usable(p) then
                    hud.show(p.widget, false)
                else
                    parts[name] = nil
                end
            end
        end
    end

    local function ease(t)
        t = math.max(0, math.min(1, t))
        return 1 - (1 - t) * (1 - t)
    end

    ------------------------------------------------------------------ the countdown

    function ui.countdown(seconds, round, m)
        -- Which banner over the numbers: FINAL ROUND by the score (both a round from winning), not by the round's number
        -- (a draw adds a round: round 3 wasn't always the last, and a 4th had no banner at all; the review of 1.7.0).
        local which = nil                       -- (a round with no banner of its own: the numbers alone)
        if m and m.mode == "death" then
            which = "death"
        elseif m and (m.score[1] or 0) >= 1 and (m.score[2] or 0) >= 1 then
            which = "round_3"
        elseif (round or 1) <= 1 then
            which = "round_1"
        elseif round == 2 then
            which = "round_2"
        end
        count = { start = os.clock(), total = seconds, round = round, which = which }
        fightAt = nil
        banner = nil
    end

    function ui.fight(seconds)
        fightAt = os.clock()
        count = nil
    end

    local function drawCount(now)
        local W = screen.w / screen.s
        local cx, cy = W / 2, 470
        if count then
            local t = now - count.start
            local left = count.total - t
            local n = math.max(1, math.min(3, math.ceil(left)))
            local into = 1 - (left - (n - 1))           -- 0..1 through this number
            local a = into < 0.18 and ease(into / 0.18) or (into > 0.82 and 1 - ease((into - 0.82) / 0.18) or 1)
            local k = 1.32 - 0.32 * ease(math.min(1, into / 0.22))
            put(part("count", "pvp/count_" .. n .. ".png", COUNT_SIZE, COUNT_SIZE, 2), cx, cy, COUNT_SIZE, COUNT_SIZE, a, k)
            local words = part("count_words", "pvp/" .. worded("count_" .. n .. "_words") .. ".png", 260, 46, 3)
            put(words, cx, cy + COUNT_SIZE * 0.52, 260, 46, a)
            -- The round over the numbers.
            if count.which then
                local ba = math.min(1, t / 0.3)
                put(part("round", "pvp/" .. worded("banner_" .. count.which) .. ".png", BANNER_W, BANNER_H, 1), cx, 210,
                    BANNER_W * 0.7, BANNER_H * 0.7, ba)
            else
                hide("round")
            end
        elseif fightAt and now - fightAt < 1.0 then
            local t = now - fightAt
            local a = t < 0.5 and 1 or 1 - ease((t - 0.5) / 0.5)
            local k = 1.6 - 0.6 * ease(math.min(1, t / 0.16))
            put(part("count", "pvp/count_fight.png", COUNT_SIZE, COUNT_SIZE, 2), cx, cy, COUNT_SIZE, COUNT_SIZE, a, k)
            put(part("count_words", "pvp/" .. worded("count_fight_words") .. ".png", 260, 56, 3), cx, cy + COUNT_SIZE * 0.52,
                260, 56, a)
            hide("round")
        else
            hide("count")
            hide("count_words")
            hide("round")
        end
    end

    ------------------------------------------------------------------ banners

    local function showBanner(key, seconds)
        banner = { tex = "pvp/" .. worded("banner_" .. key) .. ".png", at = os.clock(), till = os.clock() + (seconds or BANNER_S) }
    end

    local function drawBanner(now)
        if not banner or now >= banner.till then
            hide("banner")
            banner = nil
            return
        end
        local t, left = now - banner.at, banner.till - now
        local a = math.min(ease(t / 0.25), left < 0.4 and left / 0.4 or 1)
        local W = screen.w / screen.s
        put(part("banner", banner.tex, BANNER_W, BANNER_H, 4), W / 2, 300, BANNER_W, BANNER_H, a, 1.06 - 0.06 * ease(t / 0.3))
    end

    function ui.roundOver(round, winner, mine, s1, s2, m)
        if winner == 0 then
            showBanner("round_draw")
        elseif m and m.mode == "death" then
            -- (One life: the match's end says it.)
        else
            showBanner(winner == mine and "round_won" or "round_lost")
        end
    end

    function ui.matchOver(won, m)
        showBanner(won and "won" or "lost", 2.2)
        if won then
            api.arena.finishHint = os.clock() + 2.2      -- (then "PRESS F TO FINISH" till F stops working)
        end
    end

    function ui.youDown(why)
        showBanner(why == "fell" and "fell" or "down", 2.2)
    end

    -- No word over the finishing move (the user didn't like the FINISHED banner): the boss's move, the slow beat, the
    -- game's own death, then the game's own screens (生还, 殒命) say it. Only the hint to press F goes.
    function ui.finisher(victim, by, mine)
        banner = nil
        hide("banner")
    end

    function ui.matchStarted(m, me)
        death = nil
    end

    ------------------------------------------------------------------ the bars, the score, the clock

    -- Seconds left this round, or nil with no clock.
    local function clockLeft(m, now)
        if m.endsAt and (m.phase == "fight" or m.phase == "out") then
            return math.max(0, m.endsAt - now)
        elseif m.timer and m.timer > 0 then
            return m.timer
        end
        return nil
    end

    local function healthOf(slot, me)
        local hp, maxhp
        if slot == me then
            local _, pawn = api.getPlayer1()
            if valid(pawn) then
                hp, maxhp = api.game.getHealth(pawn)
            end
        else
            local body = coop.playerBody and coop.playerBody(slot)
            for _, p in ipairs(coop.partners()) do
                if p.ghost == body and p.target then
                    hp, maxhp = p.target.Hp, p.target.MaxHp
                end
            end
        end
        if hp and maxhp and maxhp > 0 then
            return math.max(0, math.min(1, hp / maxhp))
        end
        return nil
    end

    -- The foes' bars are the game's: slot -> { addr = the body's address, checkAt, last = the share shown }.
    local foeBars = {}
    local FOE_CHECK_S = 1.0

    -- A foe's name over their bar, in the player's language.
    local function foeName(slot)
        return (zh() and "玩家 " or "PLAYER ") .. tostring(slot)
    end

    -- The words over the first foe's bar: their name, then (a duel) this player's rounds against theirs, then the clock.
    -- The game's own text in its own font, where the score strip of ours was.
    local function foeLabel(m, slot, first, mine, now)
        local text = foeName(slot)
        if not first then
            return text
        end
        if m.mode == "duel" then
            text = text .. string.format("  ·  %s %d – %d", zh() and "你" or "YOU", m.score[mine] or 0, m.score[3 - mine] or 0)
        end
        local left = (m.phase == "count" or m.phase == "fight" or m.phase == "out") and clockLeft(m, now)
        if left then
            left = math.ceil(left)
            text = text .. string.format("  ·  %d:%02d", math.floor(left / 60), left % 60)
        end
        return text
    end

    local function hideFoeBar(slot)
        local body = coop.playerBody and coop.playerBody(slot)
        if valid(body) and api.game.hideFoeBar then
            api.game.hideFoeBar(body)
        end
        foeBars[slot] = nil
    end

    local function drawBars(m, me, now)
        local mine = m.teams[me]
        local foes = {}
        for slot, team in pairs(m.teams) do
            if slot ~= me and team ~= mine then
                foes[#foes + 1] = slot
            end
        end
        table.sort(foes)
        -- Foes on the game's own boss bar (the user: health bars in the game's own design, not ours): put up once, its
        -- health moved by the game's own ForSeq_UpdateHealth, its words by its own name text, put up again if the HUD
        -- drops it. (Teammates get no bar: the game's player bar only follows its own player, and ours isn't the game's.)
        for i, slot in ipairs(foes) do
            local body = coop.playerBody and coop.playerBody(slot)
            if valid(body) then
                local addr = body:GetAddress()
                local fb = foeBars[slot]
                if not fb or fb.addr ~= addr or (now >= fb.checkAt and not api.game.foeBar(addr)) then
                    if fb and fb.addr ~= addr then
                        hideFoeBar(slot)
                    end
                    fb = { addr = addr, checkAt = now + FOE_CHECK_S, last = -1 }
                    foeBars[slot] = fb
                    api.game.showFoeBar(body, foeName(slot))
                elseif now >= fb.checkAt then
                    fb.checkAt = now + FOE_CHECK_S
                end
                local frac = healthOf(slot, me) or 1
                if math.abs(frac - fb.last) > 0.001 and api.game.setFoeBar(addr, frac) then
                    fb.last = frac
                end
                local label = foeLabel(m, slot, i == 1, mine, now)
                if label ~= fb.label and api.game.setFoeName(addr, label) then
                    fb.label = label
                end
            end
        end
    end

    -- The blow that decides the match: on the winners' screens the beaten's bars break, as a boss's posture does.
    function ui.decided(m, winner, me)
        if m.teams[me] ~= winner or not api.game.breakFoeBar then
            return
        end
        for _, fb in pairs(foeBars) do
            api.game.breakFoeBar(fb.addr)
        end
    end

    ------------------------------------------------------------------ the fallen: the game's own death card

    local function gameTexture(path)
        local t = StaticFindObject(path)
        if not valid(t) and type(LoadAsset) == "function" then
            pcall(LoadAsset, (path:gsub("%.[^.]*$", "")))
            t = StaticFindObject(path)
        end
        return valid(t) and t or nil
    end

    local function card(parts)
        death = { since = os.clock(), widgets = {} }
        for i, d in ipairs(parts) do
            local ours = not d[1]:find("^/")
            local t = ours and hud.texture(d[1]) or gameTexture(d[1])
            if t then
                -- Its own shape: as wide as its height asks (a whole-screen one 1080 high, its width by its shape too).
                local okS, wide = pcall(function() return t:Blueprint_GetSizeX() / t:Blueprint_GetSizeY() end)
                local h = 1080 * (d[2] or 1)
                local w = h * ((okS and wide and wide > 0) and wide or (d[2] and 1 or 16 / 9))
                local widget = hud.newImage(t, w, h, Z + 20 + i)
                if widget then
                    pcall(function() widget:SetRenderOpacity(0) end)
                    death.widgets[#death.widgets + 1] = { widget = widget, w = w, h = h, dy = d[3], fade = d[4] }
                end
            end
        end
        return #death.widgets > 0
    end

    -- The losers' 殒命 and the winners' 生还. True when it's up.
    function ui.deathCard()
        return card(CARDS.lost)
    end

    function ui.victoryCard()
        return card(CARDS.won)
    end

    local function drawDeath(now)
        if not death then
            return
        end
        local W = screen.w / screen.s
        for _, d in ipairs(death.widgets) do
            local a = math.min(1, (now - death.since) / d.fade)
            pcall(function()
                d.widget:SetPositionInViewport({ X = W / 2 * screen.s, Y = (540 + 1080 * d.dy) * screen.s }, false)
            end)
            -- (Seen only once sized: a new one isn't laid out in its first frame and drew at its own size, as put() says.)
            local fitted = hud.fit(d.widget, d.w * screen.s, d.h * screen.s)
            pcall(function() d.widget:SetRenderOpacity(fitted and a or 0) end)
            if fitted then
                hud.show(d.widget, true)
            end
        end
    end

    local function dropDeath()
        for _, d in ipairs(death and death.widgets or {}) do
            if valid(d.widget) then
                pcall(function() d.widget:RemoveFromParent() end)
            end
        end
        death = nil
    end

    ------------------------------------------------------------------ each frame, and away

    function ui.frame(m, me)
        if not measure() then
            return
        end
        local now = os.clock()
        local ok, err = pcall(function()
            local fighting = m.phase ~= "going" and m.phase ~= "there"
            if fighting and m.phase ~= "result" then
                drawBars(m, me, now)
            else
                for slot in pairs(foeBars) do
                    hideFoeBar(slot)
                end
            end
            drawCount(now)
            if api.arena.finishHint and now >= api.arena.finishHint and m.phase == "finish" and not m.finished
                and m.teams[me] == m.winner and not m.down[me] and not banner then
                showBanner("finish", math.max(0.5, (m.finishBy or m.finishUntil or now) - now))
            end
            drawBanner(now)
            drawDeath(now)
        end)
        if not ok and err ~= ui.lastError then
            ui.lastError = err
            log("arena screen: " .. tostring(err))
        end
    end

    function ui.clear()
        count, banner, fightAt = nil, nil, nil
        -- Off the screen for good, not only hidden: the next match may be on another map (usable says why).
        for name, p in pairs(parts) do
            if usable(p) then
                pcall(function() p.widget:RemoveFromParent() end)
            end
            parts[name] = nil
        end
        for slot in pairs(foeBars) do
            hideFoeBar(slot)
        end
        dropDeath()
        api.arena.finishHint = nil
    end

    return ui
end
