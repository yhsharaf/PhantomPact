-- Phantom Pact's own UE4SS signature for Phantom Blade Zero: where the blueprint bytecode table (GNatives) is.
-- Written for Phantom Pact 1.6.1 (2026-11-04), after the game update of that day moved the game's code and the
-- signatures pinned to one build stopped UE4SS from starting. MIT, like UE4SS itself.
--
-- The script interpreter's loop loads the table into r14 (lea r14, [GNatives]) and calls through it twice
-- (mov r9, [r14+rcx*8]; call r9). Nothing here is pinned to one build: the table has to hold 255 handlers that all
-- point into the game's own code, near the loop. Found on Steam builds 26266538 and 26367565, once each.

local Pattern = "48 8B 42 20 4C 8D 35 ?? ?? ?? ?? 48 8B 72 10 49 8B F8 48 8B DA 80 38 04 74 40 48 8B D0 0F 1F 80 00 00 00 00 80 BB A1 00 00 00 00 48 8B C2 75 5C 0F B6 0A 48 8D 42 01 48 89 43 20 4C 8D 44 24 20 48 8B D3 4D 8B 0C CE"
local Handlers = 0xFF           -- EX_Max: one 8-byte handler per bytecode
local Reach = 0x40000000        -- every handler lies within 1 GB of this code: the game's own executable

local function target(address, at, next_instruction)
    local displacement = DerefToInt32(address + at)
    if displacement == nil then return nil end
    return address + next_instruction + displacement
end

local function pointer(address)
    local low, high = DerefToInt32(address), DerefToInt32(address + 4)
    if low == nil or high == nil then return nil end
    return ((high & 0xFFFFFFFF) << 32) | (low & 0xFFFFFFFF)
end

function Register()
    return Pattern
end

function OnMatchFound(address)
    local table = target(address, 7, 11)
    if table == nil or table % 8 ~= 0 then return nil end
    for index = 0, Handlers - 1 do
        local handler = pointer(table + index * 8)
        if handler == nil or handler == 0 or math.abs(handler - address) > Reach then return nil end
    end
    print(string.format("[Phantom Pact] GNatives at 0x%X (%d handlers)", table, Handlers))
    return table
end
