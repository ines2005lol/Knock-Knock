-- Knock Knock (B42) — knock on a closed door or tap a window to hear if anything is inside.

KnockKnock = KnockKnock or {}

-- ===== Tuning =====
KnockKnock.NOISE_RADIUS    = 6     -- default soft-knock noise radius (tiles)
KnockKnock.NOISE_VOLUME    = 7
KnockKnock.SCAN_RADIUS     = 25    -- zombies further than this are ignored
KnockKnock.REPLY_DELAY_MS  = 1200  -- pause before the reply

KnockKnock.MODES = {
    -- radiusMult: x noise radius option | bonus: added to answer chance | scope: who can hear
    soft   = { radiusMult = 1.0, bonus = 0.00, scope = "room",     sound = "KnockKnock_Knock" },
    bang   = { radiusMult = 2.5, bonus = 0.15, scope = "building", sound = "KnockKnock_Bang"  },
    weapon = { radiusMult = 3.0, bonus = 0.25, scope = "building", sound = "KnockKnock_Bang"  },
    tap    = { radiusMult = 0.7, bonus = 0.00, scope = "room",     sound = "KnockKnock_Tap"   },
}
KnockKnock.WEAPON_DAMAGE_CHANCE = 25   -- % chance a weapon bang costs 1 condition
KnockKnock.SNEAK_XP             = 2    -- XP for a soft knock/tap nothing answers

-- ===== Mod Options (Options > Mods > Knock Knock) =====
KnockKnock.opt = {}
pcall(function()
    local o = PZAPI.ModOptions:create("KnockKnock", "Knock Knock")
    KnockKnock.opt.key = o:addKeyBind("knockKey", "Knock (hold Shift to bang)", Keyboard.KEY_K,
        "Knock on the closest door or tap the closest window. Hold Shift to bang on a door.")
    KnockKnock.opt.chance = o:addSlider("chance", "Answer chance (%)", 50, 100, 5, 75,
        "How often each zombie inside reacts. Lower = silence is less trustworthy.")
    KnockKnock.opt.attract = o:addTickBox("attract", "Zombies hear my knock", true,
        "If on, knocking makes noise: zombies inside and nearby may come to the door.")
    KnockKnock.opt.radius = o:addSlider("radius", "Soft knock noise radius (tiles)", 2, 15, 1, KnockKnock.NOISE_RADIUS,
        "How far a soft knock carries. Banging carries 2.5x further, with a weapon 3x.")
    KnockKnock.opt.fear = o:addTickBox("fear", "Fear reactions", true,
        "A crowd answering raises panic. Silence gives a little relief.")
    KnockKnock.opt.xp = o:addTickBox("xp", "Sneaking XP", true,
        "Gain a little Sneaking XP when a soft knock or tap goes unanswered.")
    KnockKnock.opt.voice = o:addTickBox("voice", "Character voice reactions", true,
        "Play a short sound from your character's own voice when they react.")
end)

local function optValue(name, default)
    local opt = KnockKnock.opt[name]
    if opt and opt.getValue then
        local ok, v = pcall(function() return opt:getValue() end)
        if ok and v ~= nil then return v end
    end
    return default
end
KnockKnock.optValue = optValue

-- ===== Text =====
local TEXT = {
    soft    = "Knock softly",
    bang    = "Bang on door",
    weapon  = "Bang on door (with weapon)",
    tap     = "Tap on window",
    outside = { "That leads outside." },
    none    = { "...Nothing.", "Silence. Probably empty.", "Quiet. Too quiet?" },
    one     = { "Something shuffled in there.", "I heard something move." },
    few     = { "Movement. More than one.", "Several of them in there." },
    many    = { "That's a crowd. Nope.", "It sounds full in there." },
    deaf    = { "Did I hear something? Can't tell." },
    noDoor  = "No door or window nearby.",
}
KnockKnock.TEXT = TEXT
local function pick(list) return list[ZombRand(#list) + 1] end

-- ===== Voice reactions =====
-- Vanilla B42 voice sounds; "%s" becomes Male or Female to match the character.
KnockKnock.VOICE = {
    relief = { "Voice%sSighReliefed" },
    shrug  = { "Voice%sSighBored" },
    uneasy = { "Voice%sLureTsk" },
    dread  = { "Voice%sSighSad", "Voice%sLureTsk" },
}

function KnockKnock.playVoice(player, mood)
    if not optValue("voice", true) then return end
    local list = KnockKnock.VOICE[mood]
    if not list or #list == 0 then return end
    local pattern = list[ZombRand(#list) + 1]
    local name = string.format(pattern, player:isFemale() and "Female" or "Male")
    local suffix = string.gsub(pattern, "^Voice%%s", "")
    local emitter = player:getEmitter()
    if player.playerVoiceSound then
        player:playerVoiceSound(suffix)
    elseif emitter.playVocals then
        emitter:playVocals(name)
    else
        emitter:playSound(name)
    end
end

-- ===== Version-safe helpers (B42.13 changed traits and stats) =====
local function hasTrait(player, oldName, enumName)
    if CharacterTrait ~= nil then
        local trait = CharacterTrait[enumName]
        if trait == nil then return false end
        return player:hasTrait(trait) == true
    end
    return player:HasTrait(oldName) == true
end

-- Panic is 0-100, stress is 0-1.
local function addPanic(player, amount)
    local stats = player:getStats()
    if CharacterStat ~= nil then
        stats:add(CharacterStat.PANIC, amount)
    else
        stats:setPanic(math.min(100, stats:getPanic() + amount))
    end
end

local function reduceStress(player, amount)
    local stats = player:getStats()
    if CharacterStat ~= nil then
        stats:remove(CharacterStat.STRESS, amount)
    else
        stats:setStress(math.max(0, stats:getStress() - amount))
    end
end

-- ===== Targets: doors and windows =====
function KnockKnock.isDoor(obj)
    if not obj then return false end
    if instanceof(obj, "IsoDoor") then return true end
    if instanceof(obj, "IsoThumpable") and obj:isDoor() then return true end
    return false
end

function KnockKnock.isWindow(obj)
    return obj ~= nil and instanceof(obj, "IsoWindow")
end

-- A target is usable when it's a closed door or a closed, intact window.
function KnockKnock.isClosedTarget(obj)
    if KnockKnock.isDoor(obj) then return not obj:IsOpen() end
    if KnockKnock.isWindow(obj) then return not obj:IsOpen() and not obj:isSmashed() end
    return false
end

-- Kept for older calls.
function KnockKnock.isDoorOpen(door) return door:IsOpen() end

-- Returns (nearSquare, farSquare) relative to the player.
function KnockKnock.getSides(player, target)
    local sq = target:getSquare()
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local cell = getCell()
    local other, playerOnSqSide
    if target:getNorth() then
        other = cell:getGridSquare(x, y - 1, z)
        playerOnSqSide = player:getY() >= y
    else
        other = cell:getGridSquare(x - 1, y, z)
        playerOnSqSide = player:getX() >= x
    end
    if playerOnSqSide then return sq, other end
    return other, sq
end

local function findTarget(worldobjects)
    local window = nil
    for _, obj in ipairs(worldobjects) do
        local sq = obj.getSquare and obj:getSquare()
        if sq then
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                if KnockKnock.isDoor(o) and KnockKnock.isClosedTarget(o) then return o end
                if not window and KnockKnock.isWindow(o) and KnockKnock.isClosedTarget(o) then window = o end
            end
        end
    end
    return window
end

-- The weapon in the main hand, if it's a real weapon (not bare hands).
function KnockKnock.getWeapon(player)
    local item = player:getPrimaryHandItem()
    if item and instanceof(item, "HandWeapon") and item:getType() ~= "BareHands" then return item end
    return nil
end

-- ===== Delayed callbacks =====
local pending = {}
local function later(ms, fn) table.insert(pending, { t = getTimestampMs() + ms, fn = fn }) end
Events.OnTick.Add(function()
    if #pending == 0 then return end
    local now = getTimestampMs()
    for i = #pending, 1, -1 do
        if now >= pending[i].t then
            local fn = pending[i].fn
            table.remove(pending, i)
            local ok, err = pcall(fn)
            if not ok then print("[KnockKnock] error: " .. tostring(err)) end
        end
    end
end)

local function playAt(square, sound)
    pcall(function()
        getWorld():getFreeEmitter(square:getX() + 0.5, square:getY() + 0.5, square:getZ()):playSound(sound)
    end)
end

-- ===== Core =====
-- Returns number of zombies that answer, or nil if the far side isn't inside a building.
function KnockKnock.countResponders(farSq, mode)
    local building = farSq:getBuilding()
    if not building then return nil end
    local cfg = KnockKnock.MODES[mode]
    local room = (cfg.scope == "room") and farSq:getRoom() or nil
    local chance = math.min(1, optValue("chance", 75) / 100 + cfg.bonus)
    local list = getCell():getZombieList()
    local n = 0
    for i = 0, list:size() - 1 do
        local zed = list:get(i)
        if zed and not zed:isDead() then
            local zsq = zed:getCurrentSquare()
            if zsq and zsq:getBuilding() == building
               and zed:DistTo(farSq:getX(), farSq:getY()) <= KnockKnock.SCAN_RADIUS then
                local inScope = (room == nil) or (zsq:getRoom() == room)
                if inScope then
                    local c = chance
                    if zsq:getZ() ~= farSq:getZ() then c = c * 0.5 end -- other floors hear less
                    if ZombRandFloat(0, 1) < c then n = n + 1 end
                end
            end
        end
    end
    return n
end

function KnockKnock.resolveKnock(player, target, mode)
    local _, farSq = KnockKnock.getSides(player, target)
    if not farSq then return end
    local cfg = KnockKnock.MODES[mode]
    local tsq = target:getSquare()

    -- The knock is noise: zombies inside (and nearby) may come to it.
    if optValue("attract", true) then
        local r = math.floor(optValue("radius", KnockKnock.NOISE_RADIUS) * cfg.radiusMult + 0.5)
        addSound(player, tsq:getX(), tsq:getY(), tsq:getZ(), r, KnockKnock.NOISE_VOLUME)
    end

    -- Weapon banging wears the weapon a little.
    if mode == "weapon" then
        local weapon = KnockKnock.getWeapon(player)
        if weapon and ZombRand(100) < KnockKnock.WEAPON_DAMAGE_CHANCE then
            weapon:setCondition(math.max(0, weapon:getCondition() - 1))
        end
    end

    local n = KnockKnock.countResponders(farSq, mode)
    local hardOfHearing = hasTrait(player, "HardOfHearing", "HARD_OF_HEARING")
    local keenHearing   = hasTrait(player, "KeenHearing", "KEEN_HEARING")
    local quiet = (mode == "soft" or mode == "tap")

    later(KnockKnock.REPLY_DELAY_MS, function()
        if n == nil then
            player:Say(pick(TEXT.outside))
            KnockKnock.playVoice(player, "shrug")
            return
        end

        if hardOfHearing and n > 0 and ZombRand(2) == 0 then
            player:Say(pick(TEXT.deaf))
            KnockKnock.playVoice(player, "shrug")
            return
        end

        for i = 1, math.min(n, 3) do
            later((i - 1) * 450, function() playAt(farSq, "KnockKnock_Thump") end)
        end

        local msg, mood
        if n == 0 then msg, mood = pick(TEXT.none), "relief"
        elseif n == 1 then msg, mood = pick(TEXT.one), "uneasy"
        elseif n <= 3 then msg, mood = pick(TEXT.few), "dread"
        else msg, mood = pick(TEXT.many), "dread" end
        if keenHearing and n > 0 then msg = msg .. " (" .. n .. "?)" end
        player:Say(msg)
        later(250, function() KnockKnock.playVoice(player, mood) end)

        -- Fear: crowd raises panic, silence gives a little relief.
        if optValue("fear", true) then
            if n >= 4 then addPanic(player, 15)
            elseif n >= 2 then addPanic(player, 5)
            elseif n == 0 then reduceStress(player, 0.03) end
        end

        -- Sneaking XP for a quiet knock nothing answered.
        if quiet and n == 0 and optValue("xp", true) then
            player:getXp():AddXP(Perks.Sneak, KnockKnock.SNEAK_XP)
        end
    end)
end

-- ===== Start a knock (walks to your side first) =====
function KnockKnock.start(player, target, mode)
    local nearSq = KnockKnock.getSides(player, target)
    if nearSq and player:getCurrentSquare() ~= nearSq then
        ISTimedActionQueue.add(ISWalkToTimedAction:new(player, nearSq))
    end
    ISTimedActionQueue.add(ISKnockDoorAction:new(player, target, mode))
end

-- Picks the right mode: windows get a tap; doors get soft, bang, or weapon bang.
function KnockKnock.modeFor(player, target, wantBang)
    if KnockKnock.isWindow(target) then return "tap" end
    if not wantBang then return "soft" end
    if KnockKnock.getWeapon(player) then return "weapon" end
    return "bang"
end

local function onMenu(worldobjects, player, target, mode)
    KnockKnock.start(player, target, mode)
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end
    local target = findTarget(worldobjects)
    if not target then return end
    if test then return ISWorldObjectContextMenu.setTest() end

    if KnockKnock.isWindow(target) then
        context:addOption(TEXT.tap, worldobjects, onMenu, player, target, "tap")
    else
        context:addOption(TEXT.soft, worldobjects, onMenu, player, target, "soft")
        local bangMode = KnockKnock.modeFor(player, target, true)
        context:addOption(TEXT[bangMode], worldobjects, onMenu, player, target, bangMode)
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
