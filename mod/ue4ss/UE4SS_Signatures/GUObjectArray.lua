-- Phantom Pact's own UE4SS signature for Phantom Blade Zero: where the engine's object array (FUObjectArray) is.
-- Written for Phantom Pact 1.6.1 (2026-11-04), after the game update of that day moved the game's code and the
-- signatures pinned to one build stopped UE4SS from starting. MIT, like UE4SS itself.
--
-- The game's object iterator starts like this: it stores the array's address (lea rax, [GUObjectArray]), then reads
-- the array's last non-GC index twice (mov eax, [GUObjectArray+4]). Nothing here is pinned to one build: the match
-- has to agree with itself instead, the lea and both reads naming the same array. Found on Steam builds 26266538
-- and 26367565, once each.

local Pattern = "48 C7 41 10 00 00 00 00 48 8D 05 ?? ?? ?? ?? 48 89 01 B8 FF FF FF FF 89 41 08 4C 8B D2 48 8B D9 45 84 C0 74 0F 8B 05 ?? ?? ?? ?? 89 41 08 8B 05 ?? ?? ?? ?? 44 8D 40 01"

-- The address a rip-relative operand points at: the 4-byte displacement at `at`, counted from the next instruction.
local function target(address, at, next_instruction)
    local displacement = DerefToInt32(address + at)
    if displacement == nil then return nil end
    return address + next_instruction + displacement
end

function Register()
    return Pattern
end

function OnMatchFound(address)
    local array = target(address, 11, 15)
    if array == nil or array % 8 ~= 0 then return nil end
    -- Both reads of the last non-GC index sit 4 bytes into the same array.
    if target(address, 39, 43) ~= array + 4 or target(address, 48, 52) ~= array + 4 then return nil end
    print(string.format("[Phantom Pact] GUObjectArray at 0x%X", array))
    return array
end
