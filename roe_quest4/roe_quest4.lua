-- ROE Quest4 v1.4.0
-- Accept all 15 "Peculiar Foes" objectives (Records of Eminence
-- Quest 4, the monthly A.M.A.N. Trove voucher quests) at once.
--
-- The 15 quest IDs (3789-3803) are built into this file, so no
-- learning step and no shared settings file are needed: copy this
-- one file to every client and //roe4 set just works.
-- (The IDs were learned in game once; the learn commands remain
-- in case the IDs ever need to be re-recorded.)
--
-- MULTI-CHARACTER:
--   The addon must be loaded on every client (//lua load roe_quest4).
--   After replacing this file, reload it on EVERY client once:
--   //lua reload roe_quest4
--     //roe4 set      -- this character accepts all 15
--     //roe4 setall   -- tries to make every client accept at once
--   setall uses Windower IPC and a signal in the settings file.
--   If your clients do not share IPC or a settings file, setall
--   cannot reach them; run //roe4 set on each client instead.
--
-- Install:
--   1. Make a folder: Windower4/addons/roe_quest4/
--   2. Put roe_quest4.lua in it (only file needed)
--   3. In game: //lua load roe_quest4
--
-- First time only:
--   1. //roe4 learn          (learning ON, on ONE character)
--   2. Accept the 15 Peculiar Foes quests in the RoE menu as usual.
--      The addon prints each ID it learns (15 total).
--   3. Done. Learning turns itself off at 15.
--
-- Every month after that:
--   //roe4 set               (this character only)
--   //roe4 setall            (all characters at once)
--
-- Commands (//roe4 ...):
--   set           -- accept all learned quests that are not active yet
--   setall        -- run "set" on ALL clients at once (multi-character)
--   learn         -- toggle learning mode (records newly accepted quests)
--   list          -- show learned quest IDs and which are active now
--   ping          -- check which clients have this addon loaded
--   sync          -- re-read the settings file (picks up learned IDs)
--   add <id>      -- add a quest ID by hand
--   remove <id>   -- remove a quest ID from the learned list
--   clear         -- forget all learned quest IDs
--   help          -- show commands
--
-- How it works:
--   Same method as the official ROE addon: accepting is an outgoing
--   0x10C packet with the quest ID, and the active list (max 30)
--   arrives in incoming 0x111 packets. Learned IDs are saved with
--   the standard config library (global scope = shared file).
--   Saves always merge with what is already in the file, so a
--   client with a stale in-memory list can never erase the IDs.
--
-- It needs Windower (the `windower` table and the packets/config
-- libraries that ship with Windower). Plain `lua` cannot run it.

_addon.name = 'ROE Quest4'
_addon.author = 'Hide'
_addon.version = '1.4.0'
_addon.command = 'roe4'

local packets = require('packets')
local config = require('config')

local MAX_ACTIVE = 30
local TARGET_COUNT = 15

-- The 15 "Peculiar Foes" quest IDs, learned in game on 2026-11-22.
-- They are the same for every character, so they ship built in.
local BUILTIN_IDS = {
    3789, 3790, 3791, 3792, 3793, 3794, 3795, 3796,
    3797, 3798, 3799, 3800, 3801, 3802, 3803,
}

local defaults = {
    quest_ids = {},
    setall_signal = 0,
}
local settings = config.load(defaults)

local learning = false
local active = {}       -- quest id -> progress, from the last 0x111 packet
local active_count = 0
local baseline_ready = false  -- true once we know the pre-existing active set
local last_signal = nil       -- last setall signal this client acted on

local function say(msg)
    windower.add_to_chat(207, '[ROE4] ' .. msg)
end

local function my_name()
    local player = windower.ffxi.get_player and windower.ffxi.get_player()
    return (player and player.name) or 'unknown'
end

local function saved_set()
    local set = {}
    for _, id in ipairs(BUILTIN_IDS) do
        set[id] = true
    end
    for _, id in ipairs(settings.quest_ids or {}) do
        set[id] = true
    end
    return set
end

local function saved_count()
    local total = 0
    for _ in pairs(saved_set()) do total = total + 1 end
    return total
end

local function sorted_ids(set)
    local list = {}
    for id in pairs(set) do
        list[#list + 1] = id
    end
    table.sort(list)
    return list
end

-- Save the ID set. By default this merges with the IDs already in
-- the shared file first, so a stale client can never erase IDs
-- another client learned. Explicit edits (remove/clear) pass
-- merge=false and win over the file.
local function save_ids(set, merge)
    if merge ~= false then
        local disk = config.load(defaults)
        for _, id in ipairs(disk.quest_ids or {}) do
            set[id] = true
        end
    end
    settings.quest_ids = sorted_ids(set)
    settings:save('global')
end

-- Re-read the settings file, picking up IDs learned elsewhere.
local function sync_settings()
    settings = config.load(defaults)
end

-- Parse an incoming 0x111 packet: 30 slots of 4 bytes each, starting
-- at byte 5. Each slot packs a 12-bit quest id and 20-bit progress.
local function parse_active(data)
    local result = {}
    local count = 0
    if not data or #data < 4 + MAX_ACTIVE * 4 then
        return result, count
    end
    for i = 0, MAX_ACTIVE - 1 do
        local o = 5 + i * 4
        local v = data:byte(o) + data:byte(o + 1) * 256 + data:byte(o + 2) * 65536 + data:byte(o + 3) * 16777216
        local id = v % 4096
        local progress = math.floor(v / 4096)
        if id > 0 then
            result[id] = progress
            count = count + 1
        end
    end
    return result, count
end

local function refresh_active(data)
    local new_active, new_count = parse_active(data)
    -- The first active-list packet we ever see is the baseline:
    -- quests already active in it are never "learned", even if
    -- learning was switched on before the packet arrived.
    if learning and baseline_ready then
        local set = saved_set()
        local learned_now = 0
        for id in pairs(new_active) do
            if not active[id] and not set[id] then
                set[id] = true
                learned_now = learned_now + 1
                if windower.send_ipc_message then
                    windower.send_ipc_message('roe4:addid:' .. id)
                end
                say('Learned quest ID ' .. id .. ' (' .. saved_count() + learned_now .. '/' .. TARGET_COUNT .. ')')
            end
        end
        if learned_now > 0 then
            save_ids(set)
            if saved_count() >= TARGET_COUNT then
                learning = false
                say('All ' .. TARGET_COUNT .. ' quest IDs learned. Learning is OFF. Use //roe4 set from now on.')
            end
        end
    end
    active = new_active
    active_count = new_count
    baseline_ready = true
end

local function accept_roe(id)
    local p = packets.new('outgoing', 0x10C, { ['RoE Quest'] = id })
    packets.inject(p)
end

local function do_set()
    sync_settings()
    local set = saved_set()
    local total = saved_count()
    if total == 0 then
        say('No quest IDs learned yet. Run //roe4 learn on ONE character, accept the 15 quests once by hand, then try again.')
        return
    end
    local needed = {}
    for id in pairs(set) do
        if not active[id] then
            needed[#needed + 1] = id
        end
    end
    table.sort(needed)
    if #needed == 0 then
        say('All ' .. total .. ' learned quests are already active.')
        return
    end
    local free = MAX_ACTIVE - active_count
    if #needed > free then
        say('Not enough free RoE slots: need ' .. #needed .. ', only ' .. free .. ' free (max ' .. MAX_ACTIVE .. '). Cancel some objectives first.')
        return
    end
    say('Accepting ' .. #needed .. ' quests...')
    for _, id in ipairs(needed) do
        accept_roe(id)
        coroutine.sleep(0.5)
    end
    say('Done. Open the RoE menu to check, or run //roe4 list in a few seconds.')
end

local function do_setall()
    -- Write the signal into the shared settings file first (merging
    -- IDs), then set locally, then notify via IPC as well.
    local disk = config.load(defaults)
    local merged = saved_set()
    for _, id in ipairs(disk.quest_ids or {}) do
        merged[id] = true
    end
    disk.quest_ids = sorted_ids(merged)
    disk.setall_signal = (disk.setall_signal or 0) + 1
    disk:save('global')
    settings = disk
    last_signal = disk.setall_signal

    do_set()

    if windower.send_ipc_message then
        local ids = sorted_ids(merged)
        if #ids > 0 then
            windower.send_ipc_message('roe4:ids:' .. table.concat(ids, ','))
        end
        windower.send_ipc_message('roe4:set')
        say('Sent the quest IDs and the set command to all other characters.')
    end
end

local function do_list()
    sync_settings()
    local ids = sorted_ids(saved_set())
    if #ids == 0 then
        say('No quest IDs learned yet. Run //roe4 learn on one character first.')
        return
    end
    say('Learned ' .. #ids .. ' quest IDs (' .. active_count .. ' objectives active now):')
    for _, id in ipairs(ids) do
        say('  ' .. id .. (active[id] and '  [active]' or ''))
    end
end

local function do_help()
    say('Commands: //roe4 set | setall | learn | list | ping | sync | add <id> | remove <id> | clear')
    say('First time: //roe4 learn on ONE character, then accept the 15 quests by hand once.')
    say('After that: //roe4 setall accepts them on every client at once.')
end

windower.register_event('incoming chunk', function(id, original)
    if id == 0x111 then
        refresh_active(original)
    end
end)

-- File-signal watcher: if another client ran setall, the signal in
-- the shared settings file changes; notice it and run set here.
-- ('time change' fires about every 2.4 seconds.)
windower.register_event('time change', function()
    local disk = config.load(defaults)
    local signal = disk.setall_signal or 0
    if last_signal == nil then
        last_signal = signal
        return
    end
    if signal ~= last_signal then
        last_signal = signal
        settings = disk
        say('Set-all signal received from another character.')
        do_set()
    end
end)

-- Multi-character IPC: set commands, shared quest IDs, and ping.
windower.register_event('ipc', function(msg)
    if msg == 'roe4:set' then
        say('Set command received from another character.')
        do_set()
        local disk = config.load(defaults)
        last_signal = disk.setall_signal or 0
    elseif msg == 'roe4:ping' then
        say(my_name() .. ': ROE4 v' .. _addon.version .. ' is loaded here, ' .. saved_count() .. '/' .. TARGET_COUNT .. ' quest IDs known.')
        if windower.send_ipc_message then
            windower.send_ipc_message('roe4:pong:' .. my_name() .. ':' .. saved_count())
        end
    elseif msg:sub(1, 10) == 'roe4:pong:' then
        local name, count = msg:sub(11):match('^(.-):(%d+)$')
        if name then
            say('Client ready: ' .. name .. ' (' .. count .. '/' .. TARGET_COUNT .. ' quest IDs)')
        end
    elseif msg:sub(1, 9) == 'roe4:ids:' then
        local set = saved_set()
        local added = 0
        for id_str in msg:sub(10):gmatch('%d+') do
            local id = tonumber(id_str)
            if id and not set[id] then
                set[id] = true
                added = added + 1
            end
        end
        if added > 0 then
            save_ids(set)
            say('Received ' .. added .. ' quest IDs from another character (' .. saved_count() .. '/' .. TARGET_COUNT .. ' known).')
        end
    elseif msg:sub(1, 11) == 'roe4:addid:' then
        local id = tonumber(msg:sub(12))
        if id then
            local set = saved_set()
            if not set[id] then
                set[id] = true
                save_ids(set)
                say('Learned quest ID ' .. id .. ' from another character (' .. saved_count() .. '/' .. TARGET_COUNT .. ')')
            end
        end
    end
end)

windower.register_event('load', function()
    local last = windower.packets.last_incoming and windower.packets.last_incoming(0x111)
    if last then
        refresh_active(last)
    end
    last_signal = settings.setall_signal or 0
    say('loaded v' .. _addon.version .. '. ' .. saved_count() .. '/' .. TARGET_COUNT .. ' quest IDs learned. //roe4 help for commands.')
end)

windower.register_event('addon command', function(command, arg)
    command = (command or 'help'):lower()
    if command == 'set' then
        do_set()
    elseif command == 'setall' then
        do_setall()
    elseif command == 'learn' then
        learning = not learning
        if learning then
            say('Learning ON. Accept the Peculiar Foes quests in the menu now; I will record their IDs.')
        else
            say('Learning OFF.')
        end
    elseif command == 'list' then
        do_list()
    elseif command == 'ping' then
        if windower.send_ipc_message then
            say('Pinging all clients. Ready ones answer here and in their own chat:')
            say(my_name() .. ': ROE4 v' .. _addon.version .. ' is loaded here, ' .. saved_count() .. '/' .. TARGET_COUNT .. ' quest IDs known.')
            windower.send_ipc_message('roe4:ping')
        else
            say('This Windower has no IPC.')
        end
    elseif command == 'sync' then
        sync_settings()
        say('Settings reloaded: ' .. saved_count() .. '/' .. TARGET_COUNT .. ' quest IDs known.')
    elseif command == 'add' then
        local id = tonumber(arg)
        if id then
            local set = saved_set()
            set[id] = true
            save_ids(set)
            say('Added quest ID ' .. id .. '.')
        else
            say('Usage: //roe4 add <id>')
        end
    elseif command == 'remove' then
        local id = tonumber(arg)
        if id then
            local set = saved_set()
            set[id] = nil
            save_ids(set, false)
            say('Removed quest ID ' .. id .. '.')
        else
            say('Usage: //roe4 remove <id>')
        end
    elseif command == 'clear' then
        save_ids({}, false)
        say('Forgot all learned quest IDs.')
    else
        do_help()
    end
end)
