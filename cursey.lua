local C = require "curses"
local repr = require 'repr'
local REGULAR, INVERTED, HIGHLIGHTED, RED
local run_debugger, cursey
local AUTO = -1

-- Return the callstack index of the code that actually caused an error and the max index
local function callstack_range()
    local min, max = 0, -1
    for i=1,999 do
        if debug.getinfo(i,'f').func == run_debugger then
            min = i+2
            break
        end
    end
    for i=min,999 do
        if debug.getinfo(i,'f').func == cursey then
            max = i-3
            break
        end
    end
    return min, max
end

local Pad = setmetatable({
    select = function(self, i)
        if i == self.selected then return end
        if i then
            i = math.max(1, math.min(#self.lines, i))
        end
        if self.selected then
            local j = self.selected
            local attr = j % 2 == 0 and INVERTED or REGULAR
            self.chstrs[j]:set_str(0, self.lines[j], attr)
            self.chstrs[j]:set_str(#self.lines[j], ' ', attr, self.chstrs[j]:len()-#self.lines[j])
            self._pad:mvaddchstr(j-1+1,0+1,self.chstrs[j])
        end

        if i then
            self.chstrs[i]:set_str(0, self.lines[i], HIGHLIGHTED)
            self.chstrs[i]:set_str(#self.lines[i], ' ', HIGHLIGHTED, self.chstrs[i]:len()-#self.lines[i])
            self._pad:mvaddchstr(i-1+1,0+1,self.chstrs[i])
        end

        self.selected = i

        if self.selected then
            if self.offset + self.height-1 < self.selected then
                self.offset = math.min(self.selected - (self.height-1), #self.lines-self.height)
            elseif self.offset + 1 > self.selected then
                self.offset = self.selected - 1
            end
        end
        self:refresh()
        if self.on_select then self:on_select(self.selected) end
    end,
    refresh = function(self)
        self._pad:border(C.ACS_VLINE, C.ACS_VLINE,
            C.ACS_HLINE, C.ACS_HLINE,
            C.ACS_ULCORNER, C.ACS_URCORNER,
            C.ACS_LLCORNER, C.ACS_LRCORNER)
        self._pad:pnoutrefresh(self.offset,0,self.y,self.x,self.y+self.height,self.x+self.width)
    end,
    add_line = function(self, line, attr)
        self:erase()
        self._height = 2 + #self.lines + 1
        if self.resize_height then
            self.height = self._height
        end
        self._width = math.max(self._width, #line+2)
        if self.resize_width then
            self.width = self._width
        end
        table.insert(self.lines, line)
        local i = #self.lines
        local chstr = C.new_chstr(self.width-2)
        attr = attr or (i % 2 == 0 and INVERTED or REGULAR)
        self.chstrs[i] = chstr
        chstr:set_str(0, line, attr)
        chstr:set_str(#line+0, ' ', attr, chstr:len()-#line)
        self._pad:mvaddchstr(i-1+1,0+1,chstr)
        self._pad:resize(self._height, self._width)
        if self.on_resize then self:on_resize() end
    end,
    add_lines = function(self, lines)
        for i,line in ipairs(lines) do
            self:add_line(line)
        end
    end,
    erase = function(self)
        self._pad:erase()
        self._pad:pnoutrefresh(self.offset,0,self.y,self.x,self.y+self.height,self.x+self.width)
    end,
    clear = function(self)
        self:erase()
        self.lines = {}
        self.chstrs = {}
        self._height = 2
        if self.resize_height then
            self.height = self._height
        end
        self._width = 2
        if self.resize_width then
            self.width = self._width
        end
        self._pad:resize(self._height, self._width)
        self.selected = nil
        self.offset = 0
        self:refresh()
    end,
    scroll = function(self, delta)
        self:select(self.selected and (self.selected + delta) or 1)
    end,
}, {
    __call = function(Pad, y, x, height, width)
        local pad = setmetatable({
            x = x, y = y, width = width, height = height,
            offset = 0, selected = nil,
            chstrs = {}, lines = {},
        }, Pad)
        if height == AUTO then
            pad.resize_height = true
            pad.height = 2
        end
        if width == AUTO then
            pad.resize_width = true
            pad.width = 2
        end
        pad._height = pad.height
        pad._width = pad.width

        pad._pad = C.newpad(pad.height, pad.width)
        pad._pad:scrollok(true)
        return pad
    end,
})
Pad.__index = Pad

run_debugger = function(err_msg)
    local initial_index = 1
    ::restart::
    local stdscr = C.initscr()
    local SCREEN_H, SCREEN_W = stdscr:getmaxyx()

    C.cbreak()
    C.echo(false)
    C.nl(false)
    C.curs_set(0)
    C.start_color()
    C.use_default_colors()

    stdscr:clear()
    stdscr:refresh()
    stdscr:keypad(true)

    local _
    _, REGULAR = C.init_pair(1, -1, -1), C.color_pair(1)
    _, INVERTED = C.init_pair(2, -1, C.COLOR_BLACK), C.color_pair(2)
    _, HIGHLIGHTED = C.init_pair(3, C.COLOR_BLACK, C.COLOR_YELLOW), C.color_pair(3)
    _, RED = C.init_pair(4, C.COLOR_RED, -1), C.color_pair(4) | C.A_BOLD

    local stack_names = {}
    local stack_locations = {}
    local max_filename = 0
    local stack_min, stack_max = callstack_range()
    for i=stack_min,stack_max do
        local info = debug.getinfo(i)
        if not info then break end
        table.insert(stack_names, info.name or "???")
        local filename = info.short_src..":"..info.currentline
        table.insert(stack_locations, filename)
        max_filename = math.max(max_filename, #filename)
    end
    local callstack = {}
    for i=1,#stack_names do
        callstack[i] = stack_locations[i]..(" "):rep(max_filename-#stack_locations[i]).." | "..stack_names[i].." "
    end

    local err_pad = Pad(0,0,AUTO,SCREEN_W)
    err_pad._pad:attrset(RED)
    for line in err_msg:gmatch("[^\n]*") do
        local buff = ""
        for word in line:gmatch("%S%S*%s*") do
            if #buff + #word > SCREEN_W - 4 then
                err_pad:add_line(" "..buff, RED)
                buff = word
            else
                buff = buff .. word
            end
        end
        err_pad:add_line(" "..buff, RED)
    end
    err_pad:refresh()

    local stack_pad = Pad(err_pad.height,0,AUTO,50)
    stack_pad:add_lines(callstack)
    local var_names = Pad(err_pad.height,stack_pad.x+stack_pad.width,10,AUTO)
    local var_values = Pad(err_pad.height,var_names.x+var_names.width,10,AUTO)
    function stack_pad:on_resize()
        var_names:erase()
        var_names.x = self.x+self.width
        var_names:refresh()
        var_names:on_resize(var_names.height, var_names.width)
    end
    function var_names:on_resize()
        var_values:erase()
        var_values.x = self.x+self.width
        var_values.width = SCREEN_W - (self.x+self.width)
        var_values:refresh()
    end

    function stack_pad:on_select(i)
        var_names:clear()
        var_values:clear()
        local callstack_min, _ = callstack_range()
        for loc=1,999 do
            local name, value = debug.getlocal(callstack_min+i-1, loc)
            if value == nil then break end
            var_names:add_line(tostring(name))
            if type(value) == 'function' then
                local info = debug.getinfo(value, 'nS')
                --var_values:add_line(("function: %s @ %s:%s"):format(info.name or '???', info.short_src, info.linedefined))
                var_values:add_line(repr(info))
            else
                var_values:add_line(repr(value))
            end
        end
        var_names:refresh()
        var_values:refresh()
    end
    stack_pad:select(initial_index)

    while true do
        C.doupdate()
        local c = stdscr:getch()
        local old_index = index
        if ({[C.KEY_DOWN]=1, [C.KEY_SF]=1, [("j"):byte()]=1})[c] then
            stack_pad:scroll(1)
        elseif ({[C.KEY_UP]=1, [C.KEY_SR]=1, [("k"):byte()]=1})[c] then
            stack_pad:scroll(-1)
        elseif c == ('n'):byte() then
            var_names.offset = var_names.offset + 1
            var_names:refresh()
            --var_names:scroll(1)
        elseif c == ('m'):byte() then
            var_names.offset = var_names.offset - 1
            var_names:refresh()
            --var_names:scroll(-1)
        elseif c == ('J'):byte() then
            stack_pad:scroll(10)
        elseif c == ('K'):byte() then
            stack_pad:scroll(-10)
        elseif c == ('o'):byte() then
            local file = stack_locations[stack_pad.selected]
            local filename,line_no = file:match("([^:]*):(.*)")
            -- Launch system editor and then redraw everything
            C.endwin()
            os.execute((os.getenv("EDITOR") or "nano").." +"..line_no.." "..filename)
            initial_index = stack_pad.selected
            goto restart
        end

        if c == ('q'):byte() or c == ("Q"):byte() then
            break
        end
    end
    C.endwin()
end

cursey = function(fn, ...)
    -- To display Lua errors, we must close curses to return to
    -- normal terminal mode, and then write the error to stdout.
    local function err(err)
        C.endwin()
        print "Caught an error:"
        print(debug.traceback(err, 2))
        os.exit(2)
    end

    return xpcall(fn, function(err_msg)
        xpcall(run_debugger, err, err_msg)
    end, ...)
end

return cursey
