
-- Traps for use by Archipelago items

local ecs = require "system.game.Entities"
local Color = require "system.utils.Color"
local Damage = require "necro.game.system.Damage"
local Flyaway = require "necro.game.system.Flyaway"
local GrooveChain = require "necro.game.character.GrooveChain"
local Health = require "necro.game.character.Health"
local ItemPickup = require "necro.game.item.ItemPickup"
local Overlay = require "necro.render.Overlay"
local Particle = require "necro.game.system.Particle"
local Spell = require "necro.game.spell.Spell"
local Trap = require "necro.game.trap.Trap"
local Voice = require "necro.audio.Voice"

local trapScripts = {}

-- Heal by 1 heart
function trapScripts.instantHealth(entity)
    Health.heal({
        entity=entity,
    })
    Particle.play(entity, 'particlePuff')
    Flyaway.create({
        entity=entity,
        text='Heal!',
    })
end

-- Give 50 gold x multiplier
function trapScripts.instantGold(entity)
    local amt = entity.goldCounter.amount
    entity.goldCounter.amount = amt + (50 * GrooveChain.getMultiplier(entity))
    Voice.play(entity, 'spellGold')
    Flyaway.create({
        entity=entity,
        text='Gold!',
    })
end

-- Give 200 gold x multiplier
function trapScripts.instantGold2(entity)
    local amt = entity.goldCounter.amount
    entity.goldCounter.amount = amt + (200 * GrooveChain.getMultiplier(entity))
    Voice.play(entity, 'spellGold')
    Flyaway.create({
        entity=entity,
        text='Gold!',
    })
end

-- Heal to full
function trapScripts.fullHeal(entity)
    Health.heal({
        entity=entity,
        health=20,
    })
    Particle.play(entity, 'particlePuff')
    Flyaway.create({
        entity=entity,
        text='Full heal!',
    })
end

-- Damage the entity by half a heart, unless it would kill
-- Currently unused because it felt unfair
function trapScripts.instantDamage(entity)
    if Health.getCurrentHealth(entity) > 1 then
        Damage.inflict({
            victim=entity,
            damage=1,
            type=16451, -- blood damage, bypasses iframes and stairs
        })
    end
    Overlay.screenFlash(Color.rgb(176, 0, 0), 50)
    Flyaway.create({
        entity=entity,
        text='Damage!',
    })
end

-- Set gold to 0
function trapScripts.stealGold(entity)
    entity.goldCounter.amount = 0
    Voice.play(entity, 'leprechaunAttack')
    Flyaway.create({
        entity=entity,
        text='Lepped!',
    })
end

-- Run trap effect
function runTrap(entity, trap_name, flyaway)
    local trap = ecs.spawn(trap_name)
    Trap.addPendingTrap(trap, entity)
    Flyaway.create({
        entity=entity,
        text=flyaway,
    })
    trap.position = {
        x=1000,
        y=1000,
    }
end

-- Teleport trap
function trapScripts.teleportTrap(entity)
    runTrap(entity, 'TeleportTrap', 'Teleported!')
end

-- Confuse player for 8 beats
function trapScripts.confuseTrap(entity)
    runTrap(entity, 'ConfusionTrap', 'Confused!')
end

-- Inflict scatter trap
function trapScripts.scatterTrap(entity)
    runTrap(entity, 'ScatterTrap', 'Scatter!')
end

return trapScripts
