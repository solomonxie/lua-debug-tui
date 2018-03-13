C = require "curses"
repr = require 'repr'
local REGULAR, INVERTED, HIGHLIGHTED, RED
local run_debugger, cursed
AUTO = -1

-- Return the callstack index of the code that actually caused an error and the max index
callstack_range = ->
    min, max = 0, -1
    for i=1,999 do
        if debug.getinfo(i,'f').func == run_debugger
            min = i+2
            break
    for i=min,999
        if debug.getinfo(i,'f').func == cursed then
            max = i-3
            break
    return min, max

class Pad
    new: (@y,@x,@height,@width)=>
        @offset = 0
        @selected = nil
        @chstrs = {}
        @lines = {}
        if @height == AUTO
            @resize_height = true
            @height = 2
        if @width == AUTO
            @resize_width = true
            @width = 2
        @_width, @_height = 2, 2
        @_pad = C.newpad(@_height, @_width)
        @_pad\scrollok(true)
    
    move_to: (y, x)=>
        --@erase!
        @y = y
        @x = x
        @refresh!
        if @on_move then @on_move!
    
    set_size: (h, w)=>
        @height = h
        @width = w
        @refresh!
        if @on_resize then @on_resize!
    
    set_internal_size: (h, w)=>
        @_height = h
        @_width = w
        @refresh!
        if @on_resize then @on_resize!
    
    select: (i)=>
        return if i == @selected
        if i != nil
            i = math.max(1, math.min(#@lines, i))
        if @selected
            j = @selected
            attr = j % 2 == 0 and INVERTED or REGULAR
            @chstrs[j]\set_str(0, @lines[j], attr)
            @chstrs[j]\set_str(#@lines[j], ' ', attr, @chstrs[j]\len!-#@lines[j])
            @_pad\mvaddchstr(j-1+1,0+1,@chstrs[j])

        if i
            @chstrs[i]\set_str(0, @lines[i], HIGHLIGHTED)
            @chstrs[i]\set_str(#@lines[i], ' ', HIGHLIGHTED, @chstrs[i]\len!-#@lines[i])
            @_pad\mvaddchstr(i-1+1,0+1,@chstrs[i])

        @selected = i

        if @selected
            if @offset + @height-1 < @selected
                @offset = math.min(@selected - (@height-1), #@lines-@height)
            elseif @offset + 1 > @selected
                @offset = @selected - 1
        @refresh!
        if @on_select then @on_select(@selected)
    
    refresh: =>
        @_pad\border(C.ACS_VLINE, C.ACS_VLINE,
            C.ACS_HLINE, C.ACS_HLINE,
            C.ACS_ULCORNER, C.ACS_URCORNER,
            C.ACS_LLCORNER, C.ACS_LRCORNER)
        @_pad\pnoutrefresh(@offset,0,@y,@x,@y+@height,@x+@width)
    
    set_lines: (lines, attrs)=>
        attrs = attrs or setmetatable({}, {__index:(i)=> if i % 2 == 0 then INVERTED else REGULAR})
        @lines = {}
        @attrs = {}
        @chstrs = {}
        max_width = 0
        for i, line in ipairs(lines)
            max_width = math.max(max_width, #line)
        @_width = max_width + 2
        if @resize_width
            @width = @_width
        @_height = #lines + 2
        if @resize_height
            @height = @_height
        @_pad\resize(@_height, @_width)
        
        for i, line in ipairs(lines)
            @lines[i] = line
            attr = attrs[i]
            @attrs[i] = attr
            chstr = C.new_chstr(@width-2)
            @chstrs[i] = chstr
            chstr\set_str(0, line, attr)
            chstr\set_str(#line+0, ' ', attr, chstr\len!-#line)
            @_pad\mvaddchstr(i-1+1,0+1,chstr)
        @refresh!
    
    erase: =>
        @_pad\erase!
        @_pad\pnoutrefresh(@offset,0,@y,@x,@y+@height,@x+@width)
    
    clear: =>
        @erase!
        @lines = {}
        @chstrs = {}
        @set_internal_size(2,2)
        if @resize_height
            @set_size(@_height, @width)
        if @resize_width
            @set_size(@height, @_width)
        @selected = nil
        @offset = 0
        @refresh!
    
    scroll: (delta)=>
        @select(@selected and (@selected + delta) or 1)


run_debugger = (err_msg)->
    initial_index = 1
    stdscr = C.initscr!
    SCREEN_H, SCREEN_W = stdscr\getmaxyx!

    C.cbreak!
    C.echo(false)
    C.nl(false)
    C.curs_set(0)
    C.start_color!
    C.use_default_colors!

    stdscr\clear!
    stdscr\refresh!
    stdscr\keypad(true)

    export REGULAR, INVERTED, HIGHLIGHTED, RED
    _, REGULAR = C.init_pair(1, -1, -1), C.color_pair(1)
    _, INVERTED = C.init_pair(2, -1, C.COLOR_BLACK), C.color_pair(2)
    _, HIGHLIGHTED = C.init_pair(3, C.COLOR_BLACK, C.COLOR_YELLOW), C.color_pair(3)
    _, RED = C.init_pair(4, C.COLOR_RED, -1), C.color_pair(4) | C.A_BOLD

    stack_names = {}
    stack_locations = {}
    max_filename = 0
    stack_min, stack_max = callstack_range!
    for i=stack_min,stack_max
        info = debug.getinfo(i)
        if not info then break
        table.insert(stack_names, info.name or "???")
        filename = info.short_src..":"..info.currentline
        table.insert(stack_locations, filename)
        max_filename = math.max(max_filename, #filename)
    callstack = {}
    for i=1,#stack_names do
        callstack[i] = stack_locations[i]..(" ")\rep(max_filename-#stack_locations[i]).." | "..stack_names[i].." "

    err_pad = Pad(0,0,AUTO,SCREEN_W)
    err_pad._pad\attrset(RED)
    err_msg_lines = {}
    for line in err_msg\gmatch("[^\n]*")
        buff = ""
        for word in line\gmatch("%S%S*%s*")
            if #buff + #word > SCREEN_W - 4
                table.insert(err_msg_lines, " "..buff)
                buff = word
            else
                buff = buff .. word
        table.insert(err_msg_lines, " "..buff)
    err_pad\set_lines(err_msg_lines, setmetatable({}, __index:->RED))

    stack_pad = Pad(err_pad.height,0,AUTO,50)
    stack_pad\set_lines(callstack)
    var_names = Pad(err_pad.height,stack_pad.x+stack_pad.width,10,AUTO)
    var_values = Pad(err_pad.height,var_names.x+var_names.width,10,AUTO)

    stack_pad.on_resize = =>
        var_names\erase!
        var_names.x = self.x+self.width
        var_names\refresh!
        var_names\on_resize(var_names.height, var_names.width)

    var_names.on_resize = =>
        var_values\erase!
        var_values.x = self.x+self.width
        var_values.width = SCREEN_W - (self.x+self.width)
        var_values\refresh!

    stack_pad.on_select = (i)=>
        var_names\clear!
        var_values\clear!
        callstack_min, _ = callstack_range!
        _var_names, _var_values = {}, {}
        for loc=1,999
            name, value = debug.getlocal(callstack_min+i-1, loc)
            if value == nil then break
            table.insert(_var_names, tostring(name))
            if type(value) == 'function'
                info = debug.getinfo(value, 'nS')
                --var_values\add_line(("function: %s @ %s:%s")\format(info.name or '???', info.short_src, info.linedefined))
                table.insert(_var_values, repr(info))
            else
                table.insert(_var_values, repr(value))
        var_names\set_lines(_var_names)
        var_values\set_lines(_var_values)
    
    stack_pad\select(initial_index)

    while true
        C.doupdate!
        c = stdscr\getch!
        old_index = index
        if ({[C.KEY_DOWN]:1, [C.KEY_SF]:1, [("j")\byte!]:1})[c]
            stack_pad\scroll(1)
        elseif ({[C.KEY_UP]:1, [C.KEY_SR]:1, [("k")\byte!]:1})[c]
            stack_pad\scroll(-1)
        elseif c == ('n')\byte!
            var_names.offset = var_names.offset + 1
            var_names\refresh!
            --var_names\scroll(1)
        elseif c == ('m')\byte!
            var_names.offset = var_names.offset - 1
            var_names\refresh!
            --var_names\scroll(-1)
        elseif c == ('J')\byte!
            stack_pad\scroll(10)
        elseif c == ('K')\byte!
            stack_pad\scroll(-10)
        elseif c == ('o')\byte!
            file = stack_locations[stack_pad.selected]
            filename,line_no = file\match("([^:]*):(.*)")
            -- Launch system editor and then redraw everything
            C.endwin!
            os.execute((os.getenv("EDITOR") or "nano").." +"..line_no.." "..filename)
            initial_index = stack_pad.selected
            -- TODO: improve this
            return run_debugger(err_msg)

        if c == ('q')\byte! or c == ("Q")\byte!
            break

    C.endwin!
    return

cursed = (fn, ...)->
    -- To display Lua errors, we must close curses to return to
    -- normal terminal mode, and then write the error to stdout.
    err_hand = (err)->
        C.endwin!
        print "Caught an error:"
        print(debug.traceback(err, 2))
        os.exit(2)

    return xpcall(fn, ((err_msg)-> xpcall(run_debugger, err_hand, err_msg)), ...)

return cursed
