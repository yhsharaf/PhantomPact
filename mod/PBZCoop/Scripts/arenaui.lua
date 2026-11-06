-- What a PvP match shows (arena.lua drives it): the countdown, painted 三 二 一 and 斗 over a crimson ink circle; the score
-- and the clock at the top; the foes' health bars under them, a pale trail showing what a hit just took; teammates' small bars
-- at the left; the banners between rounds; and the game's own death card for the fallen at the end. Pictures from
-- art/make_pvp_art.py (art/pvp), each in the game's one-image widget (hud.lua), placed every frame against the screen's size.

return function(api)
    local log, valid, hud = api.log, api.valid, api.hud
    local coop = api.coop

    local Z = 460
    local COUNT_SIZE = 300          -- the countdown's picture, against a screen 1080 high
    local BANNER_W, BANNER_H = 900, 150
    local BANNER_S = 2.6            -- a banner on screen this long
    local TRAIL_HOLD_S = 0.45       -- the pale trail waits this long after a hit, then runs down to the bar
    local TRAIL_RATE = 0.9          -- of the whole bar a second
    local DEATH_ART = "/Game/PBZContent/UI/InGame/Dead/"
    local DEATH_PARTS = {           -- picture; height against the screen's (nil: all of it); down from the middle; seconds in
        { DEATH_ART .. "bg_dead.bg_dead", nil, 0, 0.5 },
        { DEATH_ART .. "T_UI_blood_Combine.T_UI_blood_Combine", 0.7, 0.02, 0.9 },
        { "/Game/PBZContent/UI/UINew/testplaceholder/yun.yun", 0.31, -0.12, 0.4 },
        { "/Game/PBZContent/UI/UINew/testplaceholder/ming.ming", 0.31, 0.14, 0.6 },
    }

    local ui = {}
    local parts = {}                -- name -> { widget, tex, w, h }
    local screen = { w = 1920, h = 1080, s = 1 }
    local count = nil               -- { start, total, round, mode }: the countdown on screen
    local banner = nil              -- { tex, at, until }
    local fightAt = nil             -- 斗's moment
    local trails = {}               -- slot -> { shown, held }
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
        if p and not (api.status and api.status.onScreen(p.widget)) then
            parts[name], p = nil, nil
        end
        if not p then
            local widget = hud.newImage(tex, w, h, Z + (z or 0))
            if not widget then
                return nil
            end
            p = { widget = widget, tex = tex, w = w, h = h }
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
        hud.fit(p.widget, (w or p.w) * s, (h or p.h) * s)
        hud.show(p.widget, (a or 1) > 0.01)
    end

    local function hide(name)
        local p = parts[name]
        if p then
            hud.show(p.widget, false)
        end
    end

    local function hideAll(prefix)
        for name, p in pairs(parts) do
            if not prefix or name:sub(1, #prefix) == prefix then
                hud.show(p.widget, false)
            end
        end
    end

    local function ease(t)
        t = math.max(0, math.min(1, t))
        return 1 - (1 - t) * (1 - t)
    end

    ------------------------------------------------------------------ the countdown

    function ui.countdown(seconds, round, m)
        count = { start = os.clock(), total = seconds, round = round, mode = m and m.mode or "duel" }
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
            local which = count.mode == "death" and "death" or ("round_" .. math.min(3, count.round or 1))
            local ba = math.min(1, t / 0.3)
            put(part("round", "pvp/" .. worded("banner_" .. which) .. ".png", BANNER_W, BANNER_H, 1), cx, 210, BANNER_W * 0.7,
                BANNER_H * 0.7, ba)
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
        showBanner(won and "won" or "lost", 3.0)
        if won then
            api.arena.finishHint = os.clock() + 3.0
        end
    end

    function ui.youDown(why)
        showBanner(why == "fell" and "fell" or "down", 2.2)
    end

    function ui.finisher(victim, by, mine)
        showBanner("finished", 2.4)
    end

    function ui.matchStarted(m, me)
        trails = {}
        death = nil
    end

    ------------------------------------------------------------------ the score, the clock, the bars

    local function digitsOf(seconds)
        local mm, ss = math.floor(seconds / 60), math.floor(seconds % 60)
        return { tostring(mm), "colon", tostring(math.floor(ss / 10)), tostring(ss % 10) }
    end

    local function drawScore(m, now)
        local W = screen.w / screen.s
        local cx = W / 2
        put(part("score_bg", "pvp/score_bg.png", 460, 74, 0), cx, 46, 460, 74, 0.95)
        put(part("team1", "pvp/" .. worded("team_1") .. ".png", 120, 26, 1), cx - 150, 30, 120, 26)
        put(part("team2", "pvp/" .. worded("team_2") .. ".png", 120, 26, 1), cx + 150, 30, 120, 26)
        local wins = m.mode == "duel" and 2 or 1
        for team = 1, 2 do
            for i = 1, wins do
                local on = (m.score[team] or 0) >= i and 1 or 0
                local x = team == 1 and (cx - 120 - (i - 1) * 26) or (cx + 120 + (i - 1) * 26)
                put(part("pip" .. team .. i, "pvp/pip_" .. team .. "_" .. on .. ".png", 22, 22, 1), x, 56, 18, 18)
            end
            for i = wins + 1, 2 do
                hide("pip" .. team .. i)
            end
        end
        local left = nil
        if m.endsAt and (m.phase == "fight" or m.phase == "out") then
            left = math.max(0, m.endsAt - now)
        elseif m.timer and m.timer > 0 then
            left = m.timer
        end
        if left then
            local ds = digitsOf(math.ceil(left))
            for i, d in ipairs(ds) do
                local p = part("digit" .. i, "pvp/digit_" .. d .. ".png", 40, 64, 2)
                local warn = left <= 10 and (math.floor(now * 4) % 2 == 0) and 0.55 or 1
                put(p, cx - 39 + (i - 1) * 26, 46, 30, 48, warn)
            end
        else
            for i = 1, 4 do
                hide("digit" .. i)
            end
        end
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

    local function drawBar(key, slot, kind, x, y, w, h, frac, team, down, now)
        local tr = trails[slot]
        if not tr then
            tr = { shown = frac, held = now }
            trails[slot] = tr
        end
        if frac >= tr.shown then
            tr.shown, tr.held = frac, now
        elseif now - tr.held > TRAIL_HOLD_S then
            tr.shown = math.max(frac, tr.shown - TRAIL_RATE * (1 / 60))
        end
        local a = down and 0.45 or 1
        put(part(key .. "bg", "pvp/bar_" .. kind .. "_bg.png", w + 8, h + 8, 0), x, y, w + 8, h + 8, a)
        local trail = part(key .. "trail", "pvp/bar_" .. kind .. "_trail.png", w, h, 1)
        local fill = part(key .. "fill", "pvp/bar_" .. kind .. "_fill_" .. team .. ".png", w, h, 2)
        -- A bar's width is its health: drawn narrower from its left edge.
        local left = x - w / 2
        put(trail, left + w * tr.shown / 2, y, math.max(0.5, w * tr.shown), h, tr.shown > frac and 0.9 * a or 0)
        put(fill, left + w * frac / 2, y, math.max(0.5, w * frac), h, frac > 0.001 and a or 0)
        put(part(key .. "name", "pvp/name_" .. slot .. ".png", 160, 28, 3), left + 70, y - h / 2 - 12, 160, 28, a)
        if down then
            put(part(key .. "down", "pvp/" .. worded("down") .. ".png", 90, 28, 3), x + w / 2 - 40, y - h / 2 - 12, 90, 28)
        else
            hide(key .. "down")
        end
    end

    local function drawBars(m, me, now)
        local W = screen.w / screen.s
        local mine = m.teams[me]
        local foes, mates = {}, {}
        for slot, team in pairs(m.teams) do
            if slot ~= me then
                if team ~= mine then
                    foes[#foes + 1] = slot
                else
                    mates[#mates + 1] = slot
                end
            end
        end
        table.sort(foes)
        table.sort(mates)
        local shown = {}
        for i, slot in ipairs(foes) do
            local frac = healthOf(slot, me) or 1
            local kind = #foes == 1 and "big" or "small"
            local w, h = #foes == 1 and 520 or 300, #foes == 1 and 16 or 11
            local y = 112 + (i - 1) * 40
            drawBar("foe" .. i, slot, kind, W / 2, y, w, h, frac, m.teams[slot], m.down[slot], now)
            shown["foe" .. i] = true
        end
        for i, slot in ipairs(mates) do
            local frac = healthOf(slot, me) or 1
            drawBar("mate" .. i, slot, "mate", 150, 170 + (i - 1) * 40, 220, 9, frac, m.teams[slot], m.down[slot], now)
            shown["mate" .. i] = true
        end
        for i = 1, 5 do
            for _, prefix in ipairs({ "foe", "mate" }) do
                if not shown[prefix .. i] then
                    hideAll(prefix .. i)
                end
            end
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

    function ui.deathCard()
        death = { since = os.clock(), widgets = {} }
        for i, d in ipairs(DEATH_PARTS) do
            local t = gameTexture(d[1])
            if t then
                local w, h = 1920, 1080
                if d[2] then
                    local okS, wide = pcall(function() return t:Blueprint_GetSizeX() / t:Blueprint_GetSizeY() end)
                    h = 1080 * d[2]
                    w = h * ((okS and wide and wide > 0) and wide or 1)
                end
                local widget = hud.newImage(t, w, h, Z + 20 + i)
                if widget then
                    death.widgets[#death.widgets + 1] = { widget = widget, w = w, h = h, dy = d[3], fade = d[4] }
                end
            end
        end
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
                d.widget:SetRenderOpacity(a)
            end)
            hud.fit(d.widget, d.w * screen.s, d.h * screen.s)
            hud.show(d.widget, true)
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
                drawScore(m, now)
                drawBars(m, me, now)
            else
                hideAll("score_bg")
                hideAll("team")
                hideAll("pip")
                hideAll("digit")
                hideAll("foe")
                hideAll("mate")
            end
            drawCount(now)
            if api.arena.finishHint and now >= api.arena.finishHint and m.phase == "finish" and not m.finished
                and m.teams[me] == m.winner and not banner then
                showBanner("finish", math.max(0.5, (m.finishUntil or now) - now))
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
        hideAll()
        dropDeath()
        trails = {}
        api.arena.finishHint = nil
    end

    return ui
end
