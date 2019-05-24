-- pure lua memory lib

if jit and jit.opt then
    -- boost jit limits
    jit.opt.start("maxsnap=1000","loopunroll=500","maxmcode=2048")
end

local __LONG_INT_CLASS__

local function __LONG_INT__(low,high)
    -- Note: Avoid using tail-calls on builtins
    -- This aborts a JIT trace, and can be avoided by wrapping tail calls in parentheses
    return (setmetatable({low,high},__LONG_INT_CLASS__))
end

local function __LONG_INT_N__(n)
    -- convert a double value to i64 directly
    local high = n / (2^32) -- manually rshift by 32
    local low = bit.band(n,2^32 - 1) -- get lowest 32 bits
    return (setmetatable({low,high},__LONG_INT_CLASS__))
end

_G.__LONG_INT__ = __LONG_INT__
_G.__LONG_INT_N__ = __LONG_INT_N__

__MODULES__ = __MODULES__ or {}
__GLOBALS__ = __GLOBALS__ or {}
__SETJMP_STATES__ = __SETJMP_STATES__ or setmetatable({},{__mode="k"})

if jit and jit.version_num < 20100 then
    function math.frexp(dbl)
        local aDbl = math.abs(dbl)
    
        if dbl ~= 0 and (aDbl ~= math.huge) then
            local exp = math.max(-1023,math.floor(math.log(aDbl,2) + 1))
            local x = aDbl * math.pow(2,-exp)
    
            if dbl < 0 then
                x = -x
            end
    
            return x,exp
        end
    
        return dbl,0
    end
end

local function __TRUNC__(n)
    if n >= 0 then return math.floor(n) end
    return math.ceil(n)
end

local function __STACK_POP__(__STACK__)
    local v = __STACK__[#__STACK__]
    __STACK__[#__STACK__] = nil
    return v
end

local function __MEMORY_GROW__(mem,pages)
    local old_pages = mem._page_count
    mem._len = (mem._page_count + pages) * 64 * 1024
    mem._page_count = old_pages + pages
    return old_pages
end

-- Adapted from https://github.com/notcake/glib/blob/master/lua/glib/bitconverter.lua
-- with permission from notcake
local function UInt32ToFloat(int)
    local negative = int < 0 -- check if first bit is 0
    if negative then int = int - 0x80000000 end

    local exponent = bit.rshift(bit.band(int, 0x7F800000), 23) -- and capture lowest 9 bits
    local significand = bit.band(int, 0x007FFFFF) / (2 ^ 23) -- discard lowest 9 bits and turn into a fraction

    local float

    if exponent == 0 then
        -- special case 1
        float = significand == 0 and 0 or math.ldexp(significand,-126)
    elseif exponent == 0xFF then
        -- special case 2
        float = significand == 0 and math.huge or (math.huge - math.huge) -- inf or nan
    else
        float = math.ldexp(significand + 1,exponent - 127)
    end

    return negative and -float or float
end

local function FloatToUInt32(float)
    local int = 0

    -- wtf -0
    if (float < 0) or ((1 / float) < 0) then
        int = int + 0x80000000
        float = -float
    end

    local exponent = 0
    local significand = 0

    if float == math.huge then
        -- special case 2.1
        exponent = 0xFF
        -- significand stays 0
    elseif float ~= float then -- nan
        -- special case 2.2
        exponent = 0xFF
        significand = 1
    elseif float ~= 0 then
        significand,exponent = math.frexp(float)
        exponent = exponent + 126 -- limit to 8 bits (u get what i mean)

        if exponent <= 0 then
            -- denormal float

            significand = math.floor(significand * 2 ^ (23 + exponent) + 0.5)
            -- ^ convert to back to whole number

            exponent = 0
        else
            significand = math.floor((significand * 2 - 1) * 2 ^ 23 + 0.5)
            -- ^ convert to back to whole number
        end
    end

    int = int + bit.lshift(bit.band(exponent, 0xFF), 23) -- stuff high 8 bits with exponent (after first sign bit)
    int = int + bit.band(significand, 0x007FFFFF) -- stuff low 23 bits with significand

    return int
end

local function UInt32sToDouble(uint_low,uint_high)
    local negative = false
    -- check if first bit is 0
    if uint_high < 0 then
        uint_high = uint_high - 0x80000000
        -- set first bit to  0 ^
        negative = true
    end

    local exponent = bit.rshift(uint_high, 20) -- and capture lowest 11 bits
    local significand = (bit.band(uint_high, 0x000FFFFF) * 0x100000000 + uint_low) / (2 ^ 52) -- discard low bits and turn into a fraction

    local double = 0

    if exponent == 0 then
        -- special case 1
        double = significand == 0 and 0 or math.ldexp(significand,-1022)
    elseif exponent == 0x07FF then
        -- special case 2
        double = significand == 0 and math.huge or (math.huge - math.huge) -- inf or nan
    else
        double = math.ldexp(significand + 1,exponent - 1023)
    end

    return negative and -double or double
end

local function DoubleToUInt32s(double)
    local uint_low = 0
    local uint_high = 0

    -- wtf -0
    if (double < 0) or ((1 / double) < 0) then
        uint_high = uint_high + 0x80000000
        double = -double
    end

    local exponent = 0
    local significand = 0

    if double == math.huge then
        -- special case 2.1
        exponent = 0x07FF
        -- significand stays 0
    elseif double ~= double then -- nan
        -- special case 2.2
        exponent = 0x07FF
        significand = 1
    elseif double ~= 0 then
        significand,exponent = math.frexp(double)
        exponent = exponent + 1022 -- limit to 10 bits (u get what i mean)

        if exponent <= 0 then
            -- denormal double

            significand = math.floor(significand * 2 ^ (52 + exponent) + 0.5)
            -- ^ convert to back to whole number

            exponent = 0
        else
            significand = math.floor((significand * 2 - 1) * 2 ^ 52 + 0.5)
            -- ^ convert to back to whole number
        end
    end

    -- significand is partially in low and high uints
    uint_low = significand % 0x100000000
    uint_high = uint_high + bit.lshift(bit.band(exponent, 0x07FF), 20)
    uint_high = uint_high + bit.band(math.floor(significand / 0x100000000), 0x000FFFFF)

    return uint_low,uint_high
end

--[[
    Type IDs:
        0: uint8
        1: uint16
        2: int32
        3: float
        4: double

    Cell: {
        typeID: TypeID;
        base: number;
        value: number;
    }
]]

local function __MEMORY_DESPECIALISE__(mem,cell,loc)
    if not cell then
        mem.data[loc] = {
            typeID = 0,
            base = loc,
            value = 0,
        }
        return
    end

    if cell.base ~= loc then
        loc = cell.base
        cell = mem.data[loc]
    end
    
    -- if branches weighted by how likely they are
    if cell.typeID == 2 then
        local value = cell.value
        mem.data[loc] = {
            typeID = 0,
            base = loc,
            value = bit.band(value,0x000000FF)
        }
        mem.data[loc + 1] = {
            typeID = 0,
            base = loc + 1,
            value = bit.rshift(bit.band(value,0x0000FF00),8)
        }
        mem.data[loc + 2] = {
            typeID = 0,
            base = loc + 2,
            value = bit.rshift(bit.band(value,0x00FF0000),16)
        }
        mem.data[loc + 3] = {
            typeID = 0,
            base = loc + 3,
            value = bit.rshift(bit.band(value,0xFF000000),24)
        }
    elseif cell.typeID == 4 then
        local low,high = DoubleToUInt32s(cell.value)
        mem.data[loc] = {
            typeID = 0,
            base = loc,
            value = bit.band(low,0x000000FF)
        }
        mem.data[loc + 1] = {
            typeID = 0,
            base = loc + 1,
            value = bit.rshift(bit.band(low,0x0000FF00),8)
        }
        mem.data[loc + 2] = {
            typeID = 0,
            base = loc + 2,
            value = bit.rshift(bit.band(low,0x00FF0000),16)
        }
        mem.data[loc + 3] = {
            typeID = 0,
            base = loc + 3,
            value = bit.rshift(bit.band(low,0xFF000000),24)
        }
        mem.data[loc + 4] = {
            typeID = 0,
            base = loc + 4,
            value = bit.band(high,0x000000FF)
        }
        mem.data[loc + 5] = {
            typeID = 0,
            base = loc + 5,
            value = bit.rshift(bit.band(high,0x0000FF00),8)
        }
        mem.data[loc + 6] = {
            typeID = 0,
            base = loc + 6,
            value = bit.rshift(bit.band(high,0x00FF0000),16)
        }
        mem.data[loc + 7] = {
            typeID = 0,
            base = loc + 7,
            value = bit.rshift(bit.band(high,0xFF000000),24)
        }
    elseif cell.typeID == 3 then
        local value = FloatToUInt32(cell.value)
        mem.data[loc] = {
            typeID = 0,
            base = loc,
            value = bit.band(value,0x000000FF)
        }
        mem.data[loc + 1] = {
            typeID = 0,
            base = loc + 1,
            value = bit.rshift(bit.band(value,0x0000FF00),8)
        }
        mem.data[loc + 2] = {
            typeID = 0,
            base = loc + 2,
            value = bit.rshift(bit.band(value,0x00FF0000),16)
        }
        mem.data[loc + 3] = {
            typeID = 0,
            base = loc + 3,
            value = bit.rshift(bit.band(value,0xFF000000),24)
        }
    elseif cell.typeID == 1 then
        local value = cell.value
        mem.data[loc] = {
            typeID = 0,
            base = loc,
            value = bit.band(value,0x000000FF)
        }
        mem.data[loc + 1] = {
            typeID = 0,
            base = loc + 1,
            value = bit.rshift(bit.band(value,0x0000FF00),8)
        }
    end
end

local function __MEMORY_READ_8__(mem,loc)
    assert((loc >= 0) and (loc < mem._len),"out of memory access")

    local cell = mem.data[loc]
    if not cell then return 0 end
    if cell.typeID == 0 then
        return cell.value
    else
        __MEMORY_DESPECIALISE__(mem,cell,loc)
        return mem.data[loc].value
    end
end

local function __MEMORY_READ_16__(mem,loc)
    assert((loc >= 0) and (loc < (mem._len - 1)),"out of memory access")

    local cell = mem.data[loc]
    if not cell then
        if not mem.data[loc + 1] then
            return 0
        end

        goto despecialise
    end

    if cell.typeID == 1 then
        if cell.base == loc then
            return cell.value
        end
    end

    ::despecialise::

    if not cell or cell.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell,loc)
        cell = mem.data[loc]
    end

    local cell2 = mem.data[loc + 1]
    if not cell2 or cell2.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell2,loc + 1)
        cell2 = mem.data[loc + 1]
    end

    local val = bit.bor(
        cell.value,
        bit.lshift(cell2.value,8)
    )
    
    mem.data[loc] = {typeID = 1,value = val,base = loc}
    mem.data[loc + 1] = cell

    return val
end

local function __MEMORY_READ_32__(mem,loc)
    assert((loc >= 0) and (loc < (mem._len - 3)),"out of memory access")

    local cell = mem.data[loc]
    if not cell then
        if not mem.data[loc + 1] then
            if not mem.data[loc + 2] then
                if not mem.data[loc + 3] then
                    return 0
                end
            end
        end

        goto despecialise
    end

    if cell.typeID == 2 then
        if cell.base == loc then
            return cell.value
        end
    end
    
    ::despecialise::

    if not cell or cell.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell,loc)
        cell = mem.data[loc]
    end

    local cell2 = mem.data[loc + 1]
    if not cell2 or cell2.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell2,loc + 1)
        cell2 = mem.data[loc + 1]
    end

    local cell3 = mem.data[loc + 2]
    if not cell3 or cell3.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell3,loc + 2)
        cell3 = mem.data[loc + 2]
    end

    local cell4 = mem.data[loc + 3]
    if not cell4 or cell4.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell4,loc + 3)
        cell4 = mem.data[loc + 3]
    end

    local val = bit.bor(
        cell.value,
        bit.lshift(cell2.value,8),
        bit.lshift(cell3.value,16),
        bit.lshift(cell4.value,24)
    )
    
    mem.data[loc] = {typeID = 2,value = val,base = loc}
    mem.data[loc + 1] = cell
    mem.data[loc + 2] = cell
    mem.data[loc + 3] = cell

    return val
end

local function __MEMORY_WRITE_8__(mem,loc,val)
    assert((loc >= 0) and (loc < mem._len),"out of memory access")

    local cell = mem.data[loc]
    if not cell then
        mem.data[loc] = {typeID = 0,value = bit.band(val,0xFF),base = loc}
        return
    end
    if cell.typeID == 0 then
        cell.value = bit.band(val,0xFF)
    else
        __MEMORY_DESPECIALISE__(mem,cell,loc)
        mem.data[loc].value = val
    end
end

local function __MEMORY_WRITE_16__(mem,loc,val)
    assert((loc >= 0) and (loc < (mem._len - 1)),"out of memory access")

    local cell = mem.data[loc]
    if not cell then
        if not mem.data[loc + 1] then
            mem.data[loc] = {typeID = 1,value = bit.band(val,0xFFFF),base = loc}
            mem.data[loc + 1] = cell
            return
        end

        goto despecialise
    end
    
    if cell.typeID == 1 then
        if cell.base == loc then
            cell.value = bit.band(val,0xFFFF)
        end
    end

    ::despecialise::

    if not cell or cell.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell,loc)
        cell = mem.data[loc]
    end

    local cell2 = mem.data[loc + 1]
    if not cell2 or cell2.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell2,loc + 1)
        cell2 = mem.data[loc + 1]
    end

    cell.value = bit.band(val,0x000000FF)
    cell2.value = bit.rshift(bit.band(val,0x0000FF00),8)
end

local function __MEMORY_WRITE_32__(mem,loc,val)
    assert((loc >= 0) and (loc < (mem._len - 3)),"out of memory access")

    local cell = mem.data[loc]
    if not cell then
        if not mem.data[loc + 1] then
            if not mem.data[loc + 2] then
                if not mem.data[loc + 3] then
                    mem.data[loc] = {typeID = 2,value = bit.band(val,0xFFFFFFFF),base = loc}
                    mem.data[loc + 1] = cell
                    mem.data[loc + 2] = cell
                    mem.data[loc + 3] = cell
                    return
                end
            end
        end

        goto despecialise
    end

    if cell.typeID == 2 then
        if cell.base == loc then
            cell.value = bit.band(val,0xFFFFFFFF)
        end
    end

    ::despecialise::
    
    if not cell or cell.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell,loc)
        cell = mem.data[loc]
    end

    local cell2 = mem.data[loc + 1]
    if not cell2 or cell2.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell2,loc + 1)
        cell2 = mem.data[loc + 1]
    end

    local cell3 = mem.data[loc + 2]
    if not cell3 or cell3.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell3,loc + 2)
        cell3 = mem.data[loc + 2]
    end

    local cell4 = mem.data[loc + 3]
    if not cell4 or cell4.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell4,loc + 3)
        cell4 = mem.data[loc + 3]
    end

    cell.value = bit.band(val,0x000000FF)
    cell2.value = bit.rshift(bit.band(val,0x0000FF00),8)
    cell3.value = bit.rshift(bit.band(val,0x00FF0000),16)
    cell4.value = bit.rshift(bit.band(val,0xFF000000),24)
end

local function __MEMORY_READ_32F__(mem,loc)
    assert((loc >= 0) and (loc < (mem._len - 3)),"out of memory access")

    local cell = mem.data[loc]
    if not cell then
        if not mem.data[loc + 1] then
            if not mem.data[loc + 2] then
                if not mem.data[loc + 3] then
                    return 0
                end
            end
        end

        goto despecialise
    end

    if cell.typeID == 3 then
        if cell.base == loc then
            return cell.value
        end
    end

    ::despecialise::

    if not cell or cell.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell,loc)
        cell = mem.data[loc]
    end

    local cell2 = mem.data[loc + 1]
    if not cell2 or cell2.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell2,loc + 1)
        cell2 = mem.data[loc + 1]
    end

    local cell3 = mem.data[loc + 2]
    if not cell3 or cell3.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell3,loc + 2)
        cell3 = mem.data[loc + 2]
    end

    local cell4 = mem.data[loc + 3]
    if not cell4 or cell4.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell4,loc + 3)
        cell4 = mem.data[loc + 3]
    end

    local val = UInt32ToFloat(bit.bor(
        cell.value,
        bit.lshift(cell2.value,8),
        bit.lshift(cell3.value,16),
        bit.lshift(cell4.value,24)
    ))
    
    mem.data[loc] = {typeID = 3,value = val,base = loc}
    mem.data[loc + 1] = cell
    mem.data[loc + 2] = cell
    mem.data[loc + 3] = cell

    return val
end

local function __MEMORY_READ_64F__(mem,loc)
    assert((loc >= 0) and (loc < (mem._len - 7)),"out of memory access")

    local cell = mem.data[loc]
    if not cell then
        if not mem.data[loc + 1] then
            if not mem.data[loc + 2] then
                if not mem.data[loc + 3] then
                    if not mem.data[loc + 4] then
                        if not mem.data[loc + 5] then
                            if not mem.data[loc + 6] then
                                if not mem.data[loc + 7] then
                                    return 0
                                end
                            end
                        end
                    end
                end
            end
        end

        goto despecialise
    end

    if cell.typeID == 4 then
        if cell.base == loc then
            return cell.value
        end
    end

    ::despecialise::
    
    if not cell or cell.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell,loc)
        cell = mem.data[loc]
    end

    local cell2 = mem.data[loc + 1]
    if not cell2 or cell2.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell2,loc + 1)
        cell2 = mem.data[loc + 1]
    end

    local cell3 = mem.data[loc + 2]
    if not cell3 or cell3.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell3,loc + 2)
        cell3 = mem.data[loc + 2]
    end

    local cell4 = mem.data[loc + 3]
    if not cell4 or cell4.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell4,loc + 3)
        cell4 = mem.data[loc + 3]
    end

    local cell5 = mem.data[loc + 4]
    if not cell5 or cell5.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell5,loc + 4)
        cell5 = mem.data[loc + 4]
    end

    local cell6 = mem.data[loc + 5]
    if not cell6 or cell6.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell6,loc + 5)
        cell6 = mem.data[loc + 5]
    end

    local cell7 = mem.data[loc + 6]
    if not cell7 or cell7.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell7,loc + 6)
        cell7 = mem.data[loc + 6]
    end

    local cell8 = mem.data[loc + 7]
    if not cell8 or cell8.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell8,loc + 7)
        cell8 = mem.data[loc + 7]
    end

    local val = UInt32sToDouble(
        bit.bor(
            cell.value,
            bit.lshift(cell2.value,8),
            bit.lshift(cell3.value,16),
            bit.lshift(cell4.value,24)
        ),
        bit.bor(
            cell5.value,
            bit.lshift(cell6.value,8),
            bit.lshift(cell7.value,16),
            bit.lshift(cell8.value,24)
        )
    )
    
    mem.data[loc] = {typeID = 4,value = val,base = loc}
    mem.data[loc + 1] = cell
    mem.data[loc + 2] = cell
    mem.data[loc + 3] = cell
    mem.data[loc + 4] = cell
    mem.data[loc + 5] = cell
    mem.data[loc + 6] = cell
    mem.data[loc + 7] = cell

    return val
end

local function __MEMORY_WRITE_32F__(mem,loc,val)
    assert((loc >= 0) and (loc < (mem._len - 3)),"out of memory access")
    assert((loc >= 0) and (loc < (mem._len - 3)),"out of memory access")

    local cell = mem.data[loc]
    if not cell then
        if not mem.data[loc + 1] then
            if not mem.data[loc + 2] then
                if not mem.data[loc + 3] then
                    mem.data[loc] = {typeID = 3,value = val,base = loc}
                    mem.data[loc + 1] = cell
                    mem.data[loc + 2] = cell
                    mem.data[loc + 3] = cell
                    return
                end
            end
        end

        goto despecialise
    end
    
    if cell.typeID == 3 then
        if cell.base == loc then
            cell.value = bit.band(val,0xFFFFFFFF)
        end
    end

    ::despecialise::
    
    if not cell or cell.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell,loc)
        cell = mem.data[loc]
    end

    local cell2 = mem.data[loc + 1]
    if not cell2 or cell2.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell2,loc + 1)
        cell2 = mem.data[loc + 1]
    end

    local cell3 = mem.data[loc + 2]
    if not cell3 or cell3.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell3,loc + 2)
        cell3 = mem.data[loc + 2]
    end

    local cell4 = mem.data[loc + 3]
    if not cell4 or cell4.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell4,loc + 3)
        cell4 = mem.data[loc + 3]
    end

    val = FloatToUInt32(val)

    cell.value = bit.band(val,0x000000FF)
    cell2.value = bit.rshift(bit.band(val,0x0000FF00),8)
    cell3.value = bit.rshift(bit.band(val,0x00FF0000),16)
    cell4.value = bit.rshift(bit.band(val,0xFF000000),24)
end

local function __MEMORY_WRITE_64F__(mem,loc,val)
    assert((loc >= 0) and (loc < (mem._len - 7)),"out of memory access")

    local cell = mem.data[loc]
    if not cell then
        if not mem.data[loc + 1] then
            if not mem.data[loc + 2] then
                if not mem.data[loc + 3] then
                    if not mem.data[loc + 4] then
                        if not mem.data[loc + 5] then
                            if not mem.data[loc + 6] then
                                if not mem.data[loc + 7] then
                                    mem.data[loc] = {typeID = 4,value = val,base = loc}
                                    mem.data[loc + 1] = cell
                                    mem.data[loc + 2] = cell
                                    mem.data[loc + 3] = cell
                                    mem.data[loc + 4] = cell
                                    mem.data[loc + 5] = cell
                                    mem.data[loc + 6] = cell
                                    mem.data[loc + 7] = cell
                                    return
                                end
                            end
                        end
                    end
                end
            end
        end

        goto despecialise
    end

    if cell.typeID == 4 then
        if cell.base == loc then
            cell.value = val
        end
    end

    ::despecialise::
    
    if not cell or cell.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell,loc)
        cell = mem.data[loc]
    end

    local cell2 = mem.data[loc + 1]
    if not cell2 or cell2.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell2,loc + 1)
        cell2 = mem.data[loc + 1]
    end

    local cell3 = mem.data[loc + 2]
    if not cell3 or cell3.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell3,loc + 2)
        cell3 = mem.data[loc + 2]
    end

    local cell4 = mem.data[loc + 3]
    if not cell4 or cell4.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell4,loc + 3)
        cell4 = mem.data[loc + 3]
    end

    local cell5 = mem.data[loc + 4]
    if not cell5 or cell5.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell5,loc + 4)
        cell5 = mem.data[loc + 4]
    end

    local cell6 = mem.data[loc + 5]
    if not cell6 or cell6.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell6,loc + 5)
        cell6 = mem.data[loc + 5]
    end

    local cell7 = mem.data[loc + 6]
    if not cell7 or cell7.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell7,loc + 6)
        cell7 = mem.data[loc + 6]
    end

    local cell8 = mem.data[loc + 7]
    if not cell8 or cell8.typeID ~= 0 then
        __MEMORY_DESPECIALISE__(mem,cell8,loc + 7)
        cell8 = mem.data[loc + 7]
    end

    local low,high = DoubleToUInt32s(val)

    cell.value = bit.band(low,0x000000FF)
    cell2.value = bit.rshift(bit.band(low,0x0000FF00),8)
    cell3.value = bit.rshift(bit.band(low,0x00FF0000),16)
    cell4.value = bit.rshift(bit.band(low,0xFF000000),24)

    cell5.value = bit.band(high,0x000000FF)
    cell6.value = bit.rshift(bit.band(high,0x0000FF00),8)
    cell7.value = bit.rshift(bit.band(high,0x00FF0000),16)
    cell8.value = bit.rshift(bit.band(high,0xFF000000),24)
end

local function __MEMORY_INIT__(mem,loc,data)
    for i = 1, #data do -- TODO RE-OPTIMIZE
        __MEMORY_WRITE_8__(mem, loc + i-1, data:byte(i))
    end
end

local function __MEMORY_ALLOC__(pages)
    local mem = {}
    mem.data = {}
    mem._page_count = pages
    mem._len = pages * 64 * 1024

    mem.write8 = __MEMORY_WRITE_8__
    mem.write16 = __MEMORY_WRITE_16__
    mem.write32 = __MEMORY_WRITE_32__

    mem.read8 = __MEMORY_READ_8__
    mem.read16 = __MEMORY_READ_16__
    mem.read32 = __MEMORY_READ_32__

    __SETJMP_STATES__[mem] = {}

    return mem
end

local function __UNSIGNED__(value)
    if value < 0 then
        value = value + 4294967296
    end

    return value
end

-- extra bit ops

local __clz_tab = {3, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0}
__clz_tab[0] = 4

local function __CLZ__(x)
    local n = 0
    if bit.band(x,-65536)     == 0 then n = 16;    x = bit.lshift(x,16) end
    if bit.band(x,-16777216)  == 0 then n = n + 8; x = bit.lshift(x,8) end
    if bit.band(x,-268435456) == 0 then n = n + 4; x = bit.lshift(x,4) end
    n = n + __clz_tab[bit.rshift(x,28)]
    return n
end

local __ctz_tab = {}

for i = 0,31 do
    __ctz_tab[ bit.rshift( 125613361 * bit.lshift(1,i) , 27 ) ] = i
end

local function __CTZ__(x)
    if x == 0 then return 32 end
    return __ctz_tab[ bit.rshift( bit.band(x,-x) * 125613361 , 27 ) ]
end

local __popcnt_tab = {
      1,1,2,1,2,2,3,1,2,2,3,2,3,3,4,1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,
    1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,
    1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,
    2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,4,5,5,6,5,6,6,7,5,6,6,7,6,7,7,8
}
__popcnt_tab[0] = 0

local function __POPCNT__(x)
    -- the really cool algorithm uses a multiply that can overflow, so we're stuck with a LUT
    return __popcnt_tab[bit.band(x,255)]
    + __popcnt_tab[bit.band(bit.rshift(x,8),255)]
    + __popcnt_tab[bit.band(bit.rshift(x,16),255)]
    + __popcnt_tab[bit.rshift(x,24)]
end

-- division helpers

local function __DIVIDE_S__(a,b)
    local res_1 = a / b
    res_2 = math.floor(res_1)
    if res_1 ~= res_2 and res_2 < 0 then res_2 = res_2 + 1 end
    local int = bit.tobit(res_2)
    if res_2 ~= int then error("bad division") end
    return int
end

local function __DIVIDE_U__(a,b)
    local res = math.floor(__UNSIGNED__(a) / __UNSIGNED__(b))
    local int = bit.tobit(res)
    if res ~= int then error("bad division") end
    return int
end

local function __MODULO_S__(a,b)
    if b == 0 then error("bad modulo") end
    local res = math.abs(a) % math.abs(b)
    if a < 0 then  res = -res end
    return bit.tobit(res)
end

local function __MODULO_U__(a,b)
    if b == 0 then error("bad modulo") end
    local res = __UNSIGNED__(a) % __UNSIGNED__(b)
    return bit.tobit(res)
end

-- Multiply two 32 bit integers without busting due to precision loss on overflow
local function __MULTIPLY_CORRECT__(a,b)
    local a_low = bit.band(a,65535)
    local b_low = bit.band(b,65535)

    return bit.tobit(
        a_low * b_low +
        bit.lshift(a_low * bit.rshift(b,16),16) +
        bit.lshift(b_low * bit.rshift(a,16),16)
    )
end

-- Extra math functions for floats, stored in their own table since they're not likely to be used often.
local __FLOAT__ = {
    nearest = function(x)
        if x % 1 == .5 then
            -- Must round toward even in the event of a tie.
            local y = math.floor(x)
            return y + (y % 2)
        end
        return math.floor(x + .5)
    end,
    truncate = function(x)
        return x > 0 and math.floor(x) or math.ceil(x)
    end,
    min = function(x,y)
        if x ~= x or y ~= y then return 0 / 0 end
        return math.min(x,y)
    end,
    max = function(x,y)
        if x ~= x or y ~= y then return 0 / 0 end
        return math.max(x,y)
    end
}

__LONG_INT_CLASS__ = {
    __tostring = function(self)
        return "__LONG_INT__(" .. self[1] .. "," .. self[2] .. ")"
    end,
    __add = function(a,b)
        local low = __UNSIGNED__(a[1]) + __UNSIGNED__(b[1])
        local high = a[2] + b[2] + (low >= 4294967296 and 1 or 0)
        return __LONG_INT__( bit.tobit(low), bit.tobit(high) )
    end,
    __sub = function(a,b)
        local low = __UNSIGNED__(a[1]) - __UNSIGNED__(b[1])
        local high = a[2] - b[2] - (low < 0 and 1 or 0)
        return __LONG_INT__( bit.tobit(low), bit.tobit(high) )
    end,
    __mul = function(a,b)
        -- copied from https://github.com/dcodeIO/long.js

        local a48 = bit.rshift(a[2],16)
        local a32 = bit.band(a[2],65535)
        local a16 = bit.rshift(a[1],16)
        local a00 = bit.band(a[1],65535)

        local b48 = bit.rshift(b[2],16)
        local b32 = bit.band(b[2],65535)
        local b16 = bit.rshift(b[1],16)
        local b00 = bit.band(b[1],65535)

        local c00 = a00 * b00
        local c16 = bit.rshift(c00,16)
        c00 = bit.band(c00,65535)

        c16 = c16 + a16 * b00
        local c32 = bit.rshift(c16,16)
        c16 = bit.band(c16,65535)

        c16 = c16 + a00 * b16
        c32 = c32 + bit.rshift(c16,16)
        c16 = bit.band(c16,65535)

        c32 = c32 + a32 * b00
        local c48 = bit.rshift(c32,16)
        c32 = bit.band(c32,65535)

        c32 = c32 + a16 * b16
        c48 = c48 + bit.rshift(c32,16)
        c32 = bit.band(c32,65535)

        c32 = c32 + a00 * b32
        c48 = c48 + bit.rshift(c32,16)
        c32 = bit.band(c32,65535)

        c48 = c48 + a48 * b00 + a32 * b16 + a16 * b32 + a00 * b48
        c48 = bit.band(c48,65535)

        return __LONG_INT__(
            bit.bor(c00,bit.lshift(c16,16)),
            bit.bor(c32,bit.lshift(c48,16))
        )
    end,
    __eq = function(a,b)
        return a[1] == b[1] and a[2] == b[2]
    end,
    __lt = function(a,b) -- <
        if a[2] == b[2] then return a[1] < b[1] else return a[2] < b[2] end
    end,
    __le = function(a,b) -- <=
        if a[2] == b[2] then return a[1] <= b[1] else return a[2] <= b[2] end
    end,
    __index = {
        store = function(self,mem,loc)
            assert((loc >= 0) and (loc < (mem._len - 7)),"out of memory access")

            local low = self[1]
            local high = self[2]

            __MEMORY_WRITE_32__(mem,loc,low)
            __MEMORY_WRITE_32__(mem,loc + 4,high)
        end,
        load = function(self,mem,loc)

            local low =  __MEMORY_READ_32__(mem,loc)
            local high = __MEMORY_READ_32__(mem,loc + 4)

            self[1] = low
            self[2] = high
        end,
        store32 = function(self,mem,loc)
           __MEMORY_WRITE_32__(mem,loc,self[1])
        end,
        store16 = function(self,mem,loc)
            __MEMORY_WRITE_16__(mem,loc,self[1])
        end,
        store8 = function(self,mem,loc)
            __MEMORY_WRITE_8__(mem,loc,self[1])
        end,
        _div_s = function(a,b)
            error("divide nyi")
        end,
        _div_u = function(n,d)
            assert(d[1] ~= 0 or d[2] ~= 0,"divide by zero")

            local q = __LONG_INT__(0,0)
            local r = __LONG_INT__(0,0)

            for i = 63,0,-1 do
                r = r:_shl(__LONG_INT__(1,0)) -- left-shift r by 1 bit
                local x = bit.band(n:_shr_u( __LONG_INT__(i,0) )[1] ,1) -- bit i of n
                r[1] = bit.bor(r[1],x) -- set lsb of r to n[i]
                if r:_ge_u(d) then
                    r = r - d
                    q = q:_or( __LONG_INT__(1,0):_shl( __LONG_INT__(i,0) ) ) -- set q[i] = 1
                end
            end

            return q
        end,
        _rem_s = function(a,b)
            error("divide nyi")
        end,
        _rem_u = function(a,b)
            error("divide nyi")
        end,
        _lt_u = function(a,b)
            if __UNSIGNED__(a[2]) == __UNSIGNED__(b[2]) then
                return __UNSIGNED__(a[1]) < __UNSIGNED__(b[1])
            else
                return __UNSIGNED__(a[2]) < __UNSIGNED__(b[2])
            end
        end,
        _le_u = function(a,b)
            if __UNSIGNED__(a[2]) == __UNSIGNED__(b[2]) then
                return __UNSIGNED__(a[1]) <= __UNSIGNED__(b[1])
            else
                return __UNSIGNED__(a[2]) <= __UNSIGNED__(b[2])
            end
        end,
        _gt_u = function(a,b)
            if __UNSIGNED__(a[2]) == __UNSIGNED__(b[2]) then
                return __UNSIGNED__(a[1]) > __UNSIGNED__(b[1])
            else
                return __UNSIGNED__(a[2]) > __UNSIGNED__(b[2])
            end
        end,
        _ge_u = function(a,b)
            if __UNSIGNED__(a[2]) == __UNSIGNED__(b[2]) then
                return __UNSIGNED__(a[1]) >= __UNSIGNED__(b[1])
            else
                return __UNSIGNED__(a[2]) >= __UNSIGNED__(b[2])
            end
        end,
        _shl = function(a,b)
            local shift = bit.band(b[1],63)

            local low, high
            if shift < 32 then
                high = bit.bor( bit.lshift(a[2],shift), shift == 0 and 0 or bit.rshift(a[1], 32-shift) )
                low = bit.lshift(a[1],shift)
            else
                low = 0
                high = bit.lshift(a[1],shift-32)
            end

            return __LONG_INT__(low,high)
        end,
        _shr_u = function(a,b)
            local shift = bit.band(b[1],63)

            local low, high
            if shift < 32 then
                low = bit.bor( bit.rshift(a[1],shift), shift == 0 and 0 or bit.lshift(a[2], 32-shift) )
                high = bit.rshift(a[2],shift)
            else
                low = bit.rshift(a[2],shift-32)
                high = 0
            end

            return __LONG_INT__(low,high)
        end,
        _shr_s = function(a,b)
            local shift = bit.band(b[1],63)

            local low, high
            if shift < 32 then
                low = bit.bor( bit.rshift(a[1],shift), shift == 0 and 0 or bit.lshift(a[2], 32-shift) )
                high = bit.arshift(a[2],shift)
            else
                low = bit.arshift(a[2],shift-32)
                high = bit.arshift(a[2],31)
            end

            return __LONG_INT__(low,high)
        end,
        _rotr = function(a,b)
            local shift = bit.band(b[1],63)
            local short_shift = bit.band(shift,31)

            local res1, res2
            if short_shift == 0 then
                -- Need this special case because shifts of 32 aren't valid :(
                res1 = a[1]
                res2 = a[2]
            else
                res1 = bit.bor( bit.rshift(a[1],short_shift), bit.lshift(a[2], 32-short_shift) )
                res2 = bit.bor( bit.rshift(a[2],short_shift), bit.lshift(a[1], 32-short_shift) )
            end

            if shift < 32 then
                return __LONG_INT__(res1,res2)
            else
                return __LONG_INT__(res2,res1)
            end
        end,
        _rotl = function(a,b)
            local shift = bit.band(b[1],63)
            local short_shift = bit.band(shift,31)

            local res1, res2
            if short_shift == 0 then
                -- Need this special case because shifts of 32 aren't valid :(
                res1 = a[1]
                res2 = a[2]
            else
                res1 = bit.bor( bit.lshift(a[1],short_shift), bit.rshift(a[2], 32-short_shift) )
                res2 = bit.bor( bit.lshift(a[2],short_shift), bit.rshift(a[1], 32-short_shift) )
            end

            if shift < 32 then
                return __LONG_INT__(res1,res2)
            else
                return __LONG_INT__(res2,res1)
            end
        end,
        _or = function(a,b)
            return __LONG_INT__(bit.bor(a[1],b[1]), bit.bor(a[2],b[2]))
        end,
        _and = function(a,b)
            return __LONG_INT__(bit.band(a[1],b[1]), bit.band(a[2],b[2]))
        end,
        _xor = function(a,b)
            return __LONG_INT__(bit.bxor(a[1],b[1]), bit.bxor(a[2],b[2]))
        end,
        _clz = function(a)
            local result = (a[2] ~= 0) and __CLZ__(a[2]) or 32 + __CLZ__(a[1])
            return __LONG_INT__(result,0)
        end,
        _ctz = function(a)
            local result = (a[1] ~= 0) and __CTZ__(a[1]) or 32 + __CTZ__(a[2])
            return __LONG_INT__(result,0)
        end,
        _popcnt = function(a)
            return __LONG_INT__( __POPCNT__(a[1]) + __POPCNT__(a[2]), 0)
        end,
    }
}
