local curses = require "curses"
local REGULAR, INVERTED, HIGHLIGHTED, RED
local run_debugger, cursey

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
            if self.offset + self.height-5 < self.selected then
                self.offset = math.min(self.selected - (self.height-5), #self.lines-self.height)
            elseif self.offset + 5 > self.selected then
                self.offset = self.selected - 5
            end
        end
        self:refresh()
        if self.on_select then self:on_select(self.selected) end
    end,
    refresh = function(self)
        self._pad:border(curses.ACS_VLINE, curses.ACS_VLINE,
            curses.ACS_HLINE, curses.ACS_HLINE,
            curses.ACS_ULCORNER, curses.ACS_URCORNER,
            curses.ACS_LLCORNER, curses.ACS_LRCORNER)
        self._pad:pnoutrefresh(self.offset,0,self.y,self.x,self.height+self.y,self.width+self.x)
    end,
    add_line = function(self, line, attr)
        self.height = self.height + 1
        self._pad:resize(self.height, self.width)
        table.insert(self.lines, line)
        local i = #self.lines
        local chstr = curses.new_chstr(self.width-2)
        attr = attr or (i % 2 == 0 and INVERTED or REGULAR)
        self.chstrs[i] = chstr
        chstr:set_str(0, line, attr)
        chstr:set_str(#line+0, ' ', attr, chstr:len()-#line)
        self._pad:mvaddchstr(i-1+1,0+1,chstr)
    end,
    add_lines = function(self, lines)
        for i,line in ipairs(lines) do
            self:add_line(line)
        end
    end,
    clear = function(self)
        self._pad:erase()
        self._pad:pnoutrefresh(self.offset,0,self.y,self.x,self.height+self.y,self.width+self.x)
        self.lines = {}
        self.chstrs = {}
        self.height = 2
        self.selected = nil
        self.offset = 0
        self._pad:resize(self.height, self.width)
        self:refresh()
    end,
    scroll = function(self, delta)
        self:select(self.selected + delta)
    end,
}, {
    __call = function(Pad, y, x, height, width)
        local pad = setmetatable({
            x = x, y = y, width = width, height = height, offset = 0, selected = nil,
            chstrs = {}, lines = {},
        }, Pad)

        pad._pad = curses.newpad(pad.height, pad.width)
        pad._pad:scrollok(true)
        return pad
    end,
})
Pad.__index = Pad

local function make_pad(y,x,lines)
    local width = 0
    for _, v in ipairs(lines) do width = math.max(width, #v) end
    local pad = setmetatable({
        x = x, y = y, width = width + 2, height = 2, offset = 0, selected = nil,
        chstrs = {}, lines = {},
    }, {__index=pad_methods})

    pad._pad = curses.newpad(pad.height, pad.width)
    pad._pad:scrollok(true)
    for i, line in ipairs(lines) do
        pad:add_line(line)
    end
    return pad
end

run_debugger = function(err_msg)
    local stdscr = curses.initscr()
    local SCREEN_H, SCREEN_W = stdscr:getmaxyx()

    curses.cbreak()
    curses.echo(false)	-- not noecho !
    curses.nl(false)	-- not nonl !
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()

    local _
    _, REGULAR = curses.init_pair(1, -1, -1), curses.color_pair(1)
    _, INVERTED = curses.init_pair(2, -1, curses.COLOR_BLACK), curses.color_pair(2)
    _, HIGHLIGHTED = curses.init_pair(3, curses.COLOR_BLACK, curses.COLOR_YELLOW), curses.color_pair(3)
    _, RED = curses.init_pair(4, curses.COLOR_RED, -1), curses.color_pair(4) | curses.A_BOLD

    stdscr:clear()
    stdscr:refresh()
    stdscr:keypad(true)

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

    local err_pad = Pad(0,0,2,SCREEN_W)
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

    local stack_pad = Pad(err_pad.height,0,2,50)
    stack_pad:add_lines(callstack)
    local var_names = Pad(err_pad.height,stack_pad.x+stack_pad.width,2,25)
    local var_values = Pad(err_pad.height,var_names.x+var_names.width,2,SCREEN_W-(var_names.x+var_names.width))

    function stack_pad:on_select(i)
        var_names:clear()
        var_values:clear()
        local callstack_min, _ = callstack_range()
        for loc=1,999 do
            local name, value = debug.getlocal(callstack_min+i-1, loc)
            if value == nil then break end
            var_names:add_line(tostring(name))
            var_values:add_line(tostring(value))
        end
        var_names:refresh()
        var_values:refresh()
    end
    stack_pad:select(1)

    while true do
        curses.doupdate()
        local c = stdscr:getch()
        if c < 256 then c = string.char(c) end
        local old_index = index
        if ({[curses.KEY_DOWN]=1, [curses.KEY_SF]=1, j=1})[c] then
            stack_pad:scroll(1)
        elseif ({[curses.KEY_UP]=1, [curses.KEY_SR]=1, k=1})[c] then
            stack_pad:scroll(-1)
        elseif c == 'J' then
            stack_pad:scroll(10)
        elseif c == 'K' then
            stack_pad:scroll(-10)
        end

        if c == 'q' or c == "Q" then
            break
        end
    end
    curses.endwin()
end

cursey = function(fn, ...)
    -- To display Lua errors, we must close curses to return to
    -- normal terminal mode, and then write the error to stdout.
    local function err(err)
        curses.endwin()
        print "Caught an error:"
        print(debug.traceback(err, 2))
        os.exit(2)
    end

    return xpcall(fn, function(err_msg)
        xpcall(run_debugger, err, err_msg)
    end, ...)
end

return cursey
