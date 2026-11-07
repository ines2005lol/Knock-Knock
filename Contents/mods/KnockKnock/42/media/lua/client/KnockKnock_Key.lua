-- Knock Knock hotkey: K = knock softly / tap window, Shift+K = bang on door (rebind in Options > Mods).

local MAX_DIST = 1.6

local function getKey()
    return KnockKnock.optValue("key", Keyboard.KEY_K)
end

-- Center of the target's edge (doors and windows sit on the north or west edge of their square).
local function edgeCenter(obj)
    local x, y = obj:getX(), obj:getY()
    if obj:getNorth() then return x + 0.5, y end
    return x, y + 0.5
end

-- Nearest closed door, or closed window if no door is close. Doors win ties.
local function findNearestTarget(player)
    local sq = player:getCurrentSquare()
    if not sq then return nil end
    local cell = getCell()
    local px, py = player:getX(), player:getY()
    local bestDoor, doorDist = nil, MAX_DIST
    local bestWin, winDist = nil, MAX_DIST
    for dx = -1, 1 do
        for dy = -1, 1 do
            local s = cell:getGridSquare(sq:getX() + dx, sq:getY() + dy, sq:getZ())
            if s then
                local objs = s:getObjects()
                for i = 0, objs:size() - 1 do
                    local o = objs:get(i)
                    if KnockKnock.isClosedTarget(o) then
                        local ex, ey = edgeCenter(o)
                        local d = math.sqrt((ex - px) ^ 2 + (ey - py) ^ 2)
                        if KnockKnock.isDoor(o) then
                            if d < doorDist then bestDoor, doorDist = o, d end
                        elseif d < winDist then
                            bestWin, winDist = o, d
                        end
                    end
                end
            end
        end
    end
    return bestDoor or bestWin
end

local function shiftHeld()
    return isKeyDown(Keyboard.KEY_LSHIFT) or isKeyDown(Keyboard.KEY_RSHIFT)
end

local function onKeyPressed(key)
    if key ~= getKey() then return end
    local player = getSpecificPlayer(0)
    if not player or player:isDead() or player:getVehicle() then return end
    if player:isAiming() or ISTimedActionQueue.isPlayerDoingAction(player) then return end
    local target = findNearestTarget(player)
    if not target then
        player:Say(KnockKnock.TEXT.noDoor)
        return
    end
    KnockKnock.start(player, target, KnockKnock.modeFor(player, target, shiftHeld()))
end

Events.OnKeyPressed.Add(onKeyPressed)
