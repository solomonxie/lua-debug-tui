C = require "curses"
repr = require 'repr'
COLORS = {}
local run_debugger, guard, stdscr
AUTO = -1
log = io.open("output.log", "w")

-- Return the callstack index of the code that actually caused an error and the max index
callstack_range = ->
    min, max = 0, -1
    for i=1,999 do
        info = debug.getinfo(i, 'f')
        if not info
            min = i-1
            break
        if info.func == run_debugger
            min = i+1
            break
    for i=min,999
        info = debug.getinfo(i, 'f')
        if not info or info.func == guard
            max = i-3
            break
    return min, max


wrap_text = (text, width)->
    lines = {}
    for line in text\gmatch("[^\n]*")
        while #line > width
            table.insert(lines, line\sub(1,width))
            line = line\sub(width+1,-1)
        if #line > 0
            table.insert(lines, line)
    return lines

default_colors = {
}

class Pad
    new: (@y,@x,@height,@width,@lines,@label,@colors=default_colors)=>
        if @colors and @colors != default_colors
            setmetatable(@colors, __index:default_colors)
        @scroll_y, @scroll_x = 0, 0
        @selected = nil

        if @width == AUTO
            @width = 2
            for x in *@lines do @width = math.max(@width, #x+2)
        @_width = @width

        if @height == AUTO
            @height = #@lines + 2
        @_height = @height

        @_pad = C.newpad(@_height, @_width)
        @_pad\scrollok(true)
        @set_active false

        @chstrs = {}
        for i, line in ipairs(@lines)
            attr = (i % 2 == 0) and @colors.even_row or @colors.odd_row
            chstr = C.new_chstr(@width-2)
            @chstrs[i] = chstr
            if #line >= chstr\len!
                line = line\sub(1, chstr\len!)
            else
                line ..= (" ")\rep(chstr\len!-#line)
            chstr\set_str(0, line, attr)
            @_pad\mvaddchstr(i-1+1,0+1,chstr)
        @refresh!
    
    set_active: (active)=>
        return if active == @active
        @active = active
        @_pad\attrset(active and @colors.active_frame or @colors.inactive_frame)
    
    select: (i)=>
        if i == @selected or #@lines == 0 then return @selected
        if i != nil
            i = math.max(1, math.min(#@lines, i))
        if @selected
            j = @selected
            attr = (j % 2 == 0) and @colors.even_row or @colors.odd_row
            @chstrs[j]\set_str(0, @lines[j], attr)
            @chstrs[j]\set_str(#@lines[j], ' ', attr, @chstrs[j]\len!-#@lines[j])
            @_pad\mvaddchstr(j-1+1,0+1,@chstrs[j])

        if i
            attr = @active and @colors.active or @colors.highlight
            @chstrs[i]\set_str(0, @lines[i], attr)
            @chstrs[i]\set_str(#@lines[i], ' ', attr, @chstrs[i]\len!-#@lines[i])
            @_pad\mvaddchstr(i-1+1,0+1,@chstrs[i])

        @selected = i

        if @selected
            if @scroll_y + @height-1 < @selected
                @scroll_y = math.min(@selected - (@height-1), #@lines-@height)
            elseif @scroll_y + 1 > @selected
                @scroll_y = @selected - 1
        @refresh!
        if @on_select then @on_select(@selected)
        return @selected
    
    scroll: (delta)=>
        if @selected == nil
            return @select 1
        @select(@selected + delta)
    
    refresh: =>
        @_pad\border(C.ACS_VLINE, C.ACS_VLINE,
            C.ACS_HLINE, C.ACS_HLINE,
            C.ACS_ULCORNER, C.ACS_URCORNER,
            C.ACS_LLCORNER, C.ACS_LRCORNER)
        if @label
            @_pad\mvaddstr(0, math.floor((@width-#@label-2)/2), " #{@label} ")
        @_pad\pnoutrefresh(@scroll_y,@scroll_x,@y,@x,@y+@height+1,@x+@width)
    
    erase: =>
        @_pad\erase!
        @_pad\pnoutrefresh(@scroll_y,@scroll_x,@y,@x,@y+@height,@x+@width)
    
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
        @scroll_y, @scroll_x = 0, 0
        @refresh!
    

ok, to_lua = pcall -> require('moonscript.base').to_lua
if not ok then to_lua = -> nil
file_cache = setmetatable({}, {__index:(filename)=>
    file = io.open(filename)
    if not file then return nil
    contents = file\read("*a")
    @[filename] = contents
    return contents
})
line_tables = setmetatable({}, {__index:(filename)=>
    file = file_cache[filename]
    if not file
        return nil
    ok, line_table = to_lua(file)
    if ok
        @[filename] = line_table
        return line_table
})

run_debugger = (err_msg)->
    export stdscr, SCREEN_H, SCREEN_W
    stdscr = C.initscr!
    SCREEN_H, SCREEN_W = stdscr\getmaxyx!

    C.cbreak!
    C.echo(false)
    C.nl(false)
    C.curs_set(0)
    C.start_color!
    C.use_default_colors!

    _, COLORS.REGULAR = C.init_pair(1, C.COLOR_WHITE, -1), C.color_pair(1)
    _, COLORS.INVERTED = C.init_pair(2, C.COLOR_WHITE, C.COLOR_BLACK), C.color_pair(2)
    _, COLORS.YELLOW_BG = C.init_pair(3, C.COLOR_BLACK, C.COLOR_YELLOW), C.color_pair(3)
    _, COLORS.RED = C.init_pair(4, C.COLOR_RED, -1), C.color_pair(4)
    _, COLORS.BLUE = C.init_pair(5, C.COLOR_BLUE, -1), C.color_pair(5) | C.A_BOLD
    _, COLORS.WHITE = C.init_pair(6, C.COLOR_WHITE, -1), C.color_pair(6)
    _, COLORS.WHITE_BG = C.init_pair(7, C.COLOR_BLACK, C.COLOR_WHITE), C.color_pair(7)
    _, COLORS.BROWN = C.init_pair(8, C.COLOR_BLACK, -1), C.color_pair(8) | C.A_BOLD
    _, COLORS.RED_BG = C.init_pair(9, C.COLOR_YELLOW, C.COLOR_RED), C.color_pair(9) | C.A_BOLD | C.A_DIM
    _, COLORS.GREEN = C.init_pair(10, C.COLOR_GREEN, -1), C.color_pair(10)
    export default_colors
    default_colors = {
        active_frame: COLORS.BLUE,
        inactive_frame: COLORS.BROWN,
        odd_row: COLORS.REGULAR,
        even_row: COLORS.INVERTED,
        highlight: COLORS.WHITE_BG,
        active: COLORS.YELLOW_BG,
    }

    stdscr\clear!
    stdscr\refresh!

    pads = {}

    do -- Err pad
        err_msg_lines = wrap_text(err_msg, SCREEN_W - 4)
        for i,line in ipairs(err_msg_lines)
            err_msg_lines[i] = (" ")\rep(math.floor((SCREEN_W-2-#line)/2))..line
        pads.err = Pad(0,0,AUTO,SCREEN_W, err_msg_lines, "Error Message", {
            even_row: COLORS.RED | C.A_BOLD, odd_row: COLORS.RED | C.A_BOLD,
            inactive_frame: COLORS.RED | C.A_DIM
        })

    do -- Stack pad
        stack_names = {}
        stack_locations = {}
        max_filename = 0
        stack_min, stack_max = callstack_range!
        for i=stack_min,stack_max
            info = debug.getinfo(i)
            if not info then break
            table.insert(stack_names, info.name or "<unnamed function>")
            if not info.short_src
                continue
            line_table = line_tables[info.short_src]
            line = if line_table
                char = line_table[info.currentline]
                line_num = 1
                file = file_cache[info.short_src]
                for _ in file\sub(1,char)\gmatch("\n") do line_num += 1
                "#{info.short_src}:#{line_num}"
            else
                info.short_src..":"..info.currentline
            table.insert(stack_locations, line)
            max_filename = math.max(max_filename, #line)
        callstack = {}
        for i=1,#stack_names do
            callstack[i] = stack_locations[i]..(" ")\rep(max_filename-#stack_locations[i]).." | "..stack_names[i].." "

        pads.stack = Pad(pads.err.height,0,math.max(#callstack+2, 20),AUTO, callstack, "(C)allstack")
        pads.stack\set_active(true)
        pads.stack\refresh!
    
    show_src = (filename, line_no)->
        file = file_cache[filename]
        src_lines = {}
        selected = nil
        if file
            i = 0
            for line in file\gmatch("[^\n]*")
                i += 1
                if i < line_no-(pads.stack.height-2)/2
                    continue
                table.insert src_lines, line
                if i == line_no
                    selected = #src_lines
                if #src_lines >= pads.stack.height-2
                    break
        else
            table.insert(src_lines, "<no source code found>")

        if pads.src
            pads.src\erase!
        pads.src = Pad(pads.err.height,pads.stack.x+pads.stack.width,
            pads.stack.height,SCREEN_W-pads.stack.x-pads.stack.width-0, src_lines, "(S)ource Code", {
                highlight: COLORS.RED_BG,
                inactive_frame: COLORS.GREEN | C.A_BOLD,
            })
        pads.src\select(selected)
    
    show_vars = (stack_index)->
        if pads.vars
            pads.vars\erase!
        if pads.values
            pads.values\erase!
        callstack_min, _ = callstack_range!
        var_names, values = {}, {}
        for loc=1,999
            name, value = debug.getlocal(callstack_min+stack_index-1, loc)
            if value == nil then break
            table.insert(var_names, tostring(name))
            if type(value) == 'function'
                info = debug.getinfo(value, 'nS')
                --values\add_line(("function: %s @ %s:%s")\format(info.name or '???', info.short_src, info.linedefined))
                table.insert(values, repr(info))
            else
                table.insert(values, repr(value))
        
        var_y = pads.stack.y + pads.stack.height
        var_x = 0
        pads.vars = Pad(var_y,var_x,math.min(2+#var_names, SCREEN_H-pads.err.height-pads.stack.height),AUTO,var_names,"(V)ars")

        pads.vars.on_select = (var_index)=>
            value_x = pads.vars.x+pads.vars.width
            value_w = SCREEN_W-(value_x)
            -- Show single value:
            if var_index
                pads.values = Pad(var_y,value_x,pads.vars.height,value_w,wrap_text(values[var_index], value_w-2), "Values")
            else
                pads.values = Pad(var_y,value_x,pads.vars.height,value_w,values, "Values")

        pads.vars\select(1)

    pads.stack.on_select = (stack_index)=>
        filename, line_no = pads.stack.lines[stack_index]\match("([^:]*):(%d*).*")
        line_no = tonumber(line_no)
        show_src(filename, line_no)
        show_vars(stack_index)

    pads.stack\select(1)
    pads.stack\set_active(true)
    selected_pad = pads.stack

    select_pad = (pad)->
        if selected_pad != pad
            selected_pad\set_active(false)
            selected_pad\refresh!
            selected_pad = pad
            selected_pad\set_active(true)
            selected_pad\refresh!

    while true
        C.doupdate!
        c = stdscr\getch!
        switch c
            when C.KEY_DOWN, C.KEY_SF, ("j")\byte!
                selected_pad\scroll(1)

            when C.KEY_UP, C.KEY_SR, ("k")\byte!
                selected_pad\scroll(-1)

            when ('J')\byte!
                selected_pad\scroll(10)

            when ('K')\byte!
                selected_pad\scroll(-10)

            when ('c')\byte!
                select_pad(pads.stack) -- (C)allstack

            when ('s')\byte!
                select_pad(pads.src) -- (S)ource Code

            when ('v')\byte!
                select_pad(pads.vars) -- (V)ars

            when ('o')\byte!
                file = stack_locations[pads.stack.selected]
                filename,line_no = file\match("([^:]*):(.*)")
                -- Launch system editor and then redraw everything
                --C.endwin!
                -- Uh.... this is only mildly broken.
                os.execute((os.getenv("EDITOR") or "nano").." +"..line_no.." "..filename)
                --return main_loop(err_msg,pads.stack.selected,var_index)

            when ('q')\byte!, ("Q")\byte!
                break

    C.endwin!


guard = (fn, ...)->
    err_hand = (err)->
        C.endwin!
        print "Caught an error:"
        print(debug.traceback(err, 2))
        os.exit(2)

    return xpcall(fn, ((err_msg)-> xpcall(run_debugger, err_hand, err_msg)), ...)

breakpoint = ->
    err_hand = (err)->
        C.endwin!
        print "Caught an error:"
        print(debug.traceback(err, 2))
        os.exit(2)

    return xpcall(run_debugger, err_hand, "Breakpoint triggered!")

return {:guard, :breakpoint}
