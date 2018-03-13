local re = require 're'
local _quote_state = {}
local max = math.max
local _quote_patt = re.compile("(({'\n' / '\"' / \"'\" / '\\'}->mark_char) / (']' ({'='*}->mark_eq) (']' / !.)) / .)*",
    {mark_char=function(q)
        if q == "\n" or q == "\\" then
            _quote_state["'"] = false
            _quote_state['"'] = false
            if _quote_state.min_eq == nil then
                _quote_state.min_eq = 0
            end
        elseif q == "'" then
            _quote_state["'"] = false
        elseif q == '"' then
            _quote_state['"'] = false
        end
    end,
    mark_eq=function(eq)
        _quote_state.min_eq = max(_quote_state.min_eq or 0, #eq+1)
    end})
local function repr(x, depth)
    -- Create a string representation of the object that is close to the lua code that will
    -- reproduce the object (similar to Python's "repr" function)
    depth = depth or 10
    if depth == 0 then return "..." end
    depth = depth - 1
    local x_type = type(x)
    if x_type == 'table' then
        if getmetatable(x) then
            -- If this object has a weird metatable, then don't pretend like it's a regular table
            return tostring(x)
        else
            local ret = {}
            local i = 1
            for k, v in pairs(x) do
                if k == i then
                    ret[#ret+1] = repr(x[i], depth)
                    i = i + 1
                elseif type(k) == 'string' and k:match("[_a-zA-Z][_a-zA-Z0-9]*") then
                    ret[#ret+1] = k.."= "..repr(v,depth)
                else
                    ret[#ret+1] = "["..repr(k,depth).."]= "..repr(v,depth)
                end
            end
            return "{"..table.concat(ret, ", ").."}"
        end
    elseif x_type == 'string' then
        if x == "\n" then
            return "'\\n'"
        end
        _quote_state = {}
        _quote_patt:match(x)
        if _quote_state["'"] ~= false then
            return "\'" .. x .. "\'"
        elseif _quote_state['"'] ~= false then
            return "\"" .. x .. "\""
        else
            local eq = ("="):rep(_quote_state.min_eq or 0)
            -- BEWARE!!!
            -- Lua's parser and syntax are dumb, so Lua interprets x[[=[asdf]=]] as
            -- a function call to x (i.e. x("=[asdf]=")), instead of indexing x
            -- (i.e. x["asdf"]), which it obviously should be. This can be fixed by
            -- slapping spaces or parens around the [=[asdf]=].
            if x:sub(1, 1) == "\n" then
                return "["..eq.."[\n"..x.."]"..eq.."]"
            else
                return "["..eq.."["..x.."]"..eq.."]"
            end
        end
    else
        return tostring(x)
    end
end
return repr
