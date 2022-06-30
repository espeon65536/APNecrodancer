
local dev
-- dev = true

-- sort this later
local json = require "archipelago.scripts.utils.json"
local trapScripts = require "archipelago.scripts.traps"
local components = require "necro.game.data.Components"
local customEntities = require "necro.game.data.CustomEntities"
local event = require "necro.event.Event"
local object = require "necro.game.object.Object"
local currentLevel = require "necro.game.level.CurrentLevel"
local hasIpc, ipc = pcall(require, "system.network.IPC")
local ecs = require "system.game.Entities"
local inventory = require "necro.game.item.Inventory"
local itemgen = require "necro.game.item.ItemGeneration"
local itemban = require "necro.game.item.ItemBan"
local itempickup = require "necro.game.item.ItemPickup"
local chat = require "necro.client.Chat"
local damage = require "necro.game.system.Damage"
local instantreplay = require "necro.client.replay.InstantReplay"

local AP_VERSION = '0.3.2'
local junk_index = 1

local nonce = 0
local itemState = {}
local characters = {}
local consumables = {}
local replaceChests = {}
local replaceFlawlessChests = false
local deathlink_enabled = false
local deathlink_pending = false

local trapMap = {
    APInstantHealth = trapScripts.instantHealth,
    APFullHeal = trapScripts.fullHeal,
    APInstantGold = trapScripts.instantGold,
    APInstantGold2 = trapScripts.instantGold2,

    APLeprechaun = trapScripts.stealGold,
    APTeleportTrap = trapScripts.teleportTrap,
    APConfuseTrap = trapScripts.confuseTrap,
    APScatterTrap = trapScripts.scatterTrap,
}

-- Utility functions
function len(obj)
    local i = 0
    for _ in pairs(obj) do
        i = i + 1
    end
    return i
end

function inList(item, list)
    for _, v in ipairs(list) do
        if v == item then
            return true
        end
    end
    return false
end

function replaceChest(chest)
    inventory.clear(chest)
    inventory.grant("archipelago_APItem", chest)
end

function giveItem(entity, item_name)
    print(item_name)
    print(itemban.isBanned(entity, item_name, itemban.Flag.GENERATE_ITEM_POOL))
    if not itemban.isBanned(entity, item_name, itemban.Flag.GENERATE_ITEM_POOL) then
        itempickup.noisyGrant(item_name, entity)
    end
end

function getPlayerOne()
    for entity in ecs.entitiesWithComponents {"controllable"} do
        if entity.controllable.playerID == 1 then
            return entity
        end
    end
end

function getAvailableChars()
    local char_str = ''
    for i, char in ipairs(characters) do
        char_str = char_str .. char
        if i ~= len(characters) then
            char_str = char_str .. ', '
        end
    end
    if char_str == '' then return 'None, connect to server' end
    return char_str
end

function APLog(type, char)
    if char == 'NocturnaBat' then char = 'Nocturna' end
    log.info("%i %s %s %s", nonce, type, char, currentLevel.getName())
end

-- definition of AP item
customEntities.extend {
    name = "APItem",
    template = customEntities.template.item(),
    data = {
        flyaway = "AP Item",
        hint = "Send an Item",
        slot = "misc"
    },
    components = {
        sprite = {
            texture = "mods/archipelago/gfx/ap.png",
        },
        itemDestructible = true,
    },
}

-- Send collection of AP item to the log file
event.inventoryCollectItem.add("logAPItem", {order="flyaway"}, function (ev)
    if ev.item.name == "archipelago_APItem" and not currentLevel.isLobby() then
        APLog('Item', ev.holder.name)
    end
end)

-- Send completion of floors to the log file
event.levelComplete.add("logFloorClear", {order="dad"}, function (ev)
    local entity = getPlayerOne()
    APLog('Clear', entity.name)
end)

-- Update checklist and item banlist on level load
event.levelLoad.add("updateSeenCounts", {order="currentLevel"}, function (ev)
    for name, value in pairs(itemState) do
        if value then
            if itemgen.getSeenCount(name) >= 99 then
                itemgen.markSeen(name, -itemgen.getSeenCount(name))
            end
        else
            if itemgen.getSeenCount(name) < 99 then
                itemgen.markSeen(name, 99)
            end
        end
    end
end)

-- Replace non-shop chests in the level with AP items
-- needs testing with chest mimic types
event.levelLoad.add("replaceLevelChests", {order="initialItems", sequence=1}, function (ev)
    for entity in ecs.entitiesWithComponents {"initialInventoryRandom"} do
        if entity.name ~= "Trapchest6" and (entity.sale == nil or entity.sale.priceTag == 0) then
            local char = getPlayerOne().name
            local floor = currentLevel.getName()
            local chestAPName = char .. ' ' .. floor
            if inList(chestAPName, replaceChests) then
                replaceChest(entity)
            end
        end
    end
end)

-- Replace flawless chests
event.bossFightEnd.add("replaceBossChests", {order="flawlessChests", sequence=1}, function (ev)
    local char = getPlayerOne().name
    local floor = currentLevel.getName()
    local chestAPName = char .. ' ' .. floor
    if replaceFlawlessChests and inList(chestAPName, replaceChests) then
        for entity in ecs.entitiesWithComponents {"initialInventoryRandom"} do
            replaceChest(entity)
        end
    end
end)

-- Give items to players
event.objectCheckAbility.add("giveItems", {order="beatDelayBypass"}, function (ev)
    local c = #consumables -- to prevent asynchronous issues
    if not ev.client and junk_index <= c then
        if not currentLevel.isLobby() then
            while junk_index <= c do
                local item = consumables[junk_index]
                local trap = trapMap[item]
                if trap ~= nil then
                    for entity in ecs.entitiesWithComponents {"playableCharacter"} do
                        trap(entity)
                    end
                else
                    for entity in ecs.entitiesWithComponents {"playableCharacter"} do
                        giveItem(entity, item)
                    end
                end
                junk_index = junk_index + 1
            end
        else
            junk_index = c + 1
        end
    end
end)

event.objectCheckAbility.add("deathlink", {order="beatDelayBypass"}, function (ev)
    if deathlink_pending then
        for entity in ecs.entitiesWithComponents {"playableCharacter"} do
            damage.inflict({
                victim=entity,
                damage=100,
                type=damage.Type.SUICIDE,
                killerName='Deathlink',
            })
        end
        deathlink_pending = false
    end
end)

-- Restrict character usage. In dev we don't need this active as it gets in the way.
if not dev then
    -- Show allowed characters on lobby load
    event.levelLoad.add("showAvailableChars", {order="music"}, function (ev)
        if currentLevel.isLobby() then
            chat.openChatbox()
            chat.print('Available characters: ' .. getAvailableChars())
        end
    end)

    -- Kill non-allowed chars on starting a run
    event.levelLoad.add("killBannedChars", {order="music"}, function (ev)
        for entity in ecs.entitiesWithComponents {"playableCharacter"} do
            if not inList(entity.name, characters) and not currentLevel.isLobby() then
                damage.inflict({
                    victim=entity,
                    damage=100,
                    type=damage.Type.SUICIDE,
                    killerName='Character Not Unlocked',
                })
            end
        end
    end)
end

-- If nonce is 0 then send a message on level load to get data back from the server
event.levelLoad.add("requestInfo", {order="currentLevel"}, function (ev)
    if nonce == 0 then
        APLog('GetInfo', getPlayerOne().name)
    end
end)

-- Deathlink implementation
event.objectDeath.add("handlePlayerDeath", {order="runSummary", filter="controllable"}, function (ev)
    if deathlink_enabled and ev.entity.controllable.playerID ~= 0 and not instantreplay.isActive() then
        -- Kill all other players
        for entity in ecs.entitiesWithComponents {"playableCharacter"} do
            damage.inflict({
                victim=entity,
                damage=100,
                type=damage.Type.SUICIDE,
                killerName='Deathlink',
            })
        end
        -- Log the deathlink
        if ev.killerName ~= 'Deathlink' and ev.killerName ~= 'Character Not Unlocked' then
            APLog('Death', ev.killerName)
        end
    end
end)

-- ipc listener
if hasIpc then
    ipc.listen(function (msg)
        msg = json.decode(msg)
        itemState = msg['item_state']
        characters = msg['characters']
        consumables = msg['consumables']
        replaceChests = msg['replace_chests']
        replaceFlawlessChests = msg['flawless']
        deathlink_enabled = msg['deathlink_enabled']
        deathlink_pending = msg['deathlink_pending']

        if nonce ~= msg['nonce'] then
            nonce = msg['nonce']
            if currentLevel.isLobby() then
                chat.openChatbox()
                chat.print("Connected to the Archipelago client. Available characters:")
                chat.print(getAvailableChars())
            end
        end
    end)
else
    chat.openChatbox()
    chat.print("IPC not enabled. In config.json, please enable IPC and whitelist the system.network.IPC script.")
end

if dev then

    event.objectCheckAbility.add("stuff", {order="beatDelayBypass"}, function (ev)
        for entity in ecs.entitiesWithComponents {"playableCharacter"} do
            -- trapScripts.fullHeal(entity)
        end
    end)

    event.levelLoad.add("stuff", {order="music"}, function (ev)
        for entity in ecs.entitiesWithComponents {"playableCharacter"} do
            -- trapScripts.fullHeal(entity)
            print(inventory.getItems(entity))
            for _, item in ipairs(inventory.getItems(entity)) do
                print(item)
            end
        end
    end)

    -- event.soundPlay.add("debug", {order="soundGroup"}, function (ev)
    --     dbg(ev)
    -- end)
end
