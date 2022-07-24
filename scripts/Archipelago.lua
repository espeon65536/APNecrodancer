
local dev
-- dev = true

local json = require "archipelago.scripts.utils.json"
local trapScripts = require "archipelago.scripts.traps"

local components = require "necro.game.data.Components"
local customEntities = require "necro.game.data.CustomEntities"
local event = require "necro.event.Event"
local object = require "necro.game.object.Object"
local currentLevel = require "necro.game.level.CurrentLevel"
local hasStorage, storage = pcall(require, "system.file.Storage")
local ecs = require "system.game.Entities"
local inventory = require "necro.game.item.Inventory"
local itemgen = require "necro.game.item.ItemGeneration"
local itemban = require "necro.game.item.ItemBan"
local itempickup = require "necro.game.item.ItemPickup"
local chat = require "necro.client.Chat"
local damage = require "necro.game.system.Damage"
local instantreplay = require "necro.client.replay.InstantReplay"
local gameclient = require "necro.client.GameClient"
local gamesession = require "necro.client.GameSession"

local AP_VERSION = '0.3.2'
local junk_index = 1

local apStorage = ''
local infile = 'in.log'
local outfile = 'out.log'
local infile_last_modified = ''
local outfile_data = ''

local nonce = 0
local itemState = {}
local characters = {}
local consumables = {}
local replaceChests = {}
local replaceFlawlessChests = false
local keepInventory = false
local savedInventory = {}
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

-----------------------
-- Utility functions --
-----------------------

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
    chest.storage.items = {
        "archipelago_APItem",
    }
end

function giveItem(entity, item_name)
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

function isAllZones()
    return gamesession.getCurrentMode().id == gamesession.Mode.AllZones
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

----------------------------
-- Communication Handling --
----------------------------

-- Wipe files on mod load
if hasStorage then
    apStorage = storage.new('archipelago')
    apStorage.writeFile(infile, '')
    apStorage.writeFile(outfile, '')
end

-- Yell at player if storage module isn't available
event.levelLoad.add("storageChatMsg", {order="currentLevel"}, function (ev)
    if not hasStorage then
        chat.openChatbox()
        chat.print("Storage not enabled. In config.json, please whitelist the system.file.Storage script.")
    end
end)

-- Receive information from AP server
event.objectCheckAbility.add("readInfile", {order="beatDelayBypass"}, function (ev)
    if not hasStorage then return end
    local msg = apStorage.readFile(infile)
    msg = json.decode(msg)
    if msg then
        itemState = msg['item_state']
        characters = msg['characters']
        consumables = msg['consumables']
        replaceChests = msg['replace_chests']
        replaceFlawlessChests = msg['flawless']
        keepInventory = msg['keep_inventory']
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
    end
end)

-- Write info to the outfile
function APLog(type, char)
    if not hasStorage then return end
    if not (isAllZones() or currentLevel.isLobby()) then return end
    if char == 'NocturnaBat' then char = 'Nocturna' end
    local levelName = currentLevel.getZone() .. '-' .. currentLevel.getFloor()
    outfile_data = outfile_data .. '\n' .. string.format("%s %i %s %s %s", gameclient.getMessageTimestamp(), nonce, type, char, levelName)
    apStorage.writeFile(outfile, outfile_data)
end

---------------------------
-- Definition of AP Item --
---------------------------

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
        itemDestructible = false,
    },
}

-----------------------
-- Basic AP Handling --
-----------------------

-- Send collection of AP item to the log file
event.pickupEffects.add("logAPItem", {order="animation"}, function (ev)
    if ev.item.name == "archipelago_APItem" and isAllZones() then
        APLog('Item', ev.holder.name)
    end
end)

-- Send completion of floors to the log file
event.levelComplete.add("logFloorClear", {order="winScreen"}, function (ev)
    if not (isAllZones() and instantreplay.isActive()) then return end
    APLog('Clear', getPlayerOne().name)
end)

-- If nonce is 0 then send a message on level load to get data back from the server
event.levelLoad.add("requestInfo", {order="currentLevel"}, function (ev)
    if nonce == 0 then
        APLog('GetInfo', 'nil')
    end
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
-- needs testing with urns
event.levelLoad.add("replaceLevelChests", {order="initialItems", sequence=1}, function (ev)
    if not isAllZones() then return end
    for entity in ecs.entitiesWithComponents {"storageGenerateItemPool"} do
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
    if not isAllZones() then return end
    local char = getPlayerOne().name
    local floor = currentLevel.getName()
    local chestAPName = char .. ' ' .. floor
    if replaceFlawlessChests and inList(chestAPName, replaceChests) then
        for entity in ecs.entitiesWithComponents {"storageGenerateItemPool"} do
            replaceChest(entity)
        end
    end
end)

-- Give items to players
event.objectCheckAbility.add("giveItems", {order="beatDelay"}, function (ev)
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

-----------------------------------
-- Keep-Inventory Implementation --
-----------------------------------

event.objectDeath.add("keepInventory", {order="runSummary", filter="controllable"}, function (ev)
    if not keepInventory or not isAllZones() or instantreplay.isActive() or ev.entity.controllable.playerID == 0 then return end
    local inv = ev.entity.inventory.itemSlots
    savedInventory = {
        character=ev.entity.name
    }
    -- there is 100% a better way to do this but I'm not a good enough Lua programmer to figure it out
    if inv.shovel then savedInventory.shovel = ecs.getEntityByID(inv.shovel[1]).name end
    if inv.weapon then savedInventory.weapon = ecs.getEntityByID(inv.weapon[1]).name end
    if inv.head then savedInventory.head = ecs.getEntityByID(inv.head[1]).name end
    if inv.body then savedInventory.body = ecs.getEntityByID(inv.body[1]).name end
    if inv.feet then savedInventory.feet = ecs.getEntityByID(inv.feet[1]).name end
    if inv.torch then savedInventory.torch = ecs.getEntityByID(inv.torch[1]).name end
    if inv.ring then savedInventory.ring = ecs.getEntityByID(inv.ring[1]).name end
end)

event.levelLoad.add("restoreInventory", {order="music"}, function (ev)
    if not keepInventory or not isAllZones() then return end
    local char = getPlayerOne()
    if savedInventory.character == char.name then
        for slot, item in pairs(savedInventory) do
            if slot ~= 'character' and item ~= nil then
                giveItem(char, item)
            end
        end
    end
    savedInventory = {}
end)

------------------------------
-- Deathlink Implementation --
------------------------------

-- send out deaths
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

-- receive deaths
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
