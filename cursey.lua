local curses = require "curses"
local REGULAR, INVERTED, HIGHLIGHTED, RED
local run_debugger
local function callstack_offset()
    for i=1,999 do
        if debug.getinfo(i,'f').func == run_debugger then return i+2 end
    end
    error("Couldn't find debugger")
end

local pad_methods = {
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
    add_line = function(self, line)
        self.height = self.height + 1
        self._pad:resize(self.height, self.width)
        table.insert(self.lines, line)
        local i = #self.lines
        local chstr = curses.new_chstr(self.width-2)
        local attr = i % 2 == 0 and INVERTED or REGULAR
        self.chstrs[i] = chstr
        chstr:set_str(0, line, attr)
        chstr:set_str(#line+0, ' ', attr, chstr:len()-#line)
        self._pad:mvaddchstr(i-1+1,0+1,chstr)
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
}

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
    local i = callstack_offset()
    local max_filename = 0
    while true do
        local info = debug.getinfo(i)
        if not info then break end
        table.insert(stack_names, info.name or "???")
        local filename = info.short_src..":"..info.currentline
        table.insert(stack_locations, filename)
        max_filename = math.max(max_filename, #filename)
        i = i + 1
    end
    local callstack = {}
    for i=1,#stack_names do
        callstack[i] = stack_locations[i]..(" "):rep(max_filename-#stack_locations[i]).." | "..stack_names[i].." "
    end

    do
        local err_win = curses.newwin(3,#err_msg+4,0,0)
        local _, max_x = err_win:getmaxyx()
        err_win:scrollok(true)
        err_win:attrset(RED)
        local chstr = curses.new_chstr(max_x)
        chstr:set_str(0, ' '..err_msg, RED)
        chstr:set_str(#err_msg+1, ' ', RED, max_x-#err_msg-3)
        err_win:mvaddchstr(1,1,chstr)
        err_win:border(curses.ACS_VLINE, curses.ACS_VLINE,
            curses.ACS_HLINE, curses.ACS_HLINE,
            curses.ACS_ULCORNER, curses.ACS_URCORNER,
            curses.ACS_LLCORNER, curses.ACS_LRCORNER)
        err_win:refresh()
    end

    local stack_pad = make_pad(3,0,callstack)
    local var_names = make_pad(3,stack_pad.x+stack_pad.width, {"<variable names>"})
    local var_values = make_pad(3,var_names.x+var_names.width, {(" "):rep(SCREEN_W-(var_names.x+var_names.width+2))})

    function stack_pad:on_select(i)
        var_names:clear()
        var_values:clear()
        for loc=1,999 do
            local name, value = debug.getlocal(callstack_offset()+i-1, loc)
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

return function(fn, ...)
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
