require "TimedActions/ISBaseTimedAction"

-- Timed action for knocking/banging on a door or tapping a window.
ISKnockDoorAction = ISBaseTimedAction:derive("ISKnockDoorAction")

local DURATION = { soft = 60, bang = 50, weapon = 45, tap = 40 }

function ISKnockDoorAction:isValid()
    if not self.target or not self.target:getSquare() then return false end
    if not KnockKnock.isClosedTarget(self.target) then return false end
    if self.mode == "weapon" and not KnockKnock.getWeapon(self.character) then return false end
    return self.character:DistTo(self.target:getX() + 0.5, self.target:getY() + 0.5) < 2.5
end

function ISKnockDoorAction:waitToStart()
    self.character:faceThisObject(self.target)
    return self.character:shouldBeTurning()
end

function ISKnockDoorAction:update()
    self.character:faceThisObject(self.target)
end

function ISKnockDoorAction:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Mid")
    self.character:getEmitter():playSound(KnockKnock.MODES[self.mode].sound)
end

function ISKnockDoorAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISKnockDoorAction:perform()
    KnockKnock.resolveKnock(self.character, self.target, self.mode)
    ISBaseTimedAction.perform(self)
end

-- B42 multiplayer hook; logic runs client-side in perform().
function ISKnockDoorAction:complete()
    return true
end

function ISKnockDoorAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return DURATION[self.mode] or 60
end

function ISKnockDoorAction:new(character, target, mode)
    local o = ISBaseTimedAction.new(self, character)
    o.target = target
    o.mode = mode or "soft"
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = o:getDuration()
    return o
end
