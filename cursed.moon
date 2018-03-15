C = require "curses"
repr = require 'repr'
COLORS = {}
local run_debugger, guard, stdscr
AUTO = {}
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
            max = i-0
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
        @scroll_y, @scroll_x = 1, 1
        @selected = nil

        @_height = #@lines
        if @height == AUTO
            @height = @_height + 2

        @_width = 0
        for x in *@lines do @_width = math.max(@_width, #x+2)
        if @width == AUTO
            @width = @_width + 2

        @_frame = C.newwin(@height, @width, @y, @x)

        @_pad = C.newpad(@_height, @_width)
        @_pad\scrollok(true)
        @set_active false

        @chstrs = {}
        for i, line in ipairs(@lines)
            attr = @colors.line_colors[i]
            chstr = C.new_chstr(@_width)
            @chstrs[i] = chstr
            if #line >= chstr\len!
                line = line\sub(1, chstr\len!)
            else
                line ..= (" ")\rep(chstr\len!-#line)
            chstr\set_str(0, line, attr)
            @_pad\mvaddchstr(i-1,0,chstr)
        @refresh!
    
    set_active: (active)=>
        return if active == @active
        @active = active
        @_frame\attrset(active and @colors.active_frame or @colors.inactive_frame)
    
    select: (i)=>
        if #@lines == 0 then i = nil
        if i == @selected then return @selected
        if i != nil
            i = math.max(1, math.min(#@lines, i))
        if @selected
            j = @selected
            attr = @colors.line_colors[j]
            @chstrs[j]\set_str(0, @lines[j], attr)
            @chstrs[j]\set_str(#@lines[j], ' ', attr, @chstrs[j]\len!-#@lines[j])
            @_pad\mvaddchstr(j-1,0,@chstrs[j])

        if i
            attr = @active and @colors.active or @colors.highlight
            @chstrs[i]\set_str(0, @lines[i], attr)
            @chstrs[i]\set_str(#@lines[i], ' ', attr, @chstrs[i]\len!-#@lines[i])
            @_pad\mvaddchstr(i-1,0,@chstrs[i])

            scrolloff = 3
            if i > @scroll_y + (@height-2) - scrolloff
                @scroll_y = i - (@height-2) + scrolloff
            elseif i < @scroll_y + scrolloff
                @scroll_y = i - scrolloff
            @scroll_y = math.max(1, math.min(#@lines, @scroll_y))

        @selected = i
        @refresh!
        if @on_select then @on_select(@selected)
        return @selected
    
    scroll: (dy,dx)=>
        if @selected != nil
            @select(@selected + (dy or 0))
        else
            @scroll_y = math.max(1, math.min(@_height-@height, @scroll_y+(dy or 0)))
        @scroll_x = math.max(1, math.min(@_width-@width, @scroll_x+(dx or 0)))
        @refresh!
    
    refresh: =>
        @_frame\border(C.ACS_VLINE, C.ACS_VLINE,
            C.ACS_HLINE, C.ACS_HLINE,
            C.ACS_ULCORNER, C.ACS_URCORNER,
            C.ACS_LLCORNER, C.ACS_LRCORNER)
        if @label
            @_frame\mvaddstr(0, math.floor((@width-#@label-2)/2), " #{@label} ")
        @_frame\refresh!
        h,w = math.min(@height-2,@_height),math.min(@width-2,@_width)
        @_pad\pnoutrefresh(@scroll_y-1,@scroll_x-1,@y+1,@x+1,@y+h,@x+w)
    
    erase: =>
        @_frame\erase!
        @_frame\refresh!
    
    __gc: =>
        @_frame\close!
        @_pad\close!

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
    log\write(err_msg.."\n\n")
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
        line_colors: setmetatable({}, __index:(i)=> (i % 2 == 0 and COLORS.INVERTED or COLORS.REGULAR))
        highlight: COLORS.WHITE_BG,
        active: COLORS.YELLOW_BG,
    }

    do -- Fullscreen flash
        stdscr\wbkgd(COLORS.RED_BG)
        stdscr\clear!
        stdscr\refresh!
        lines = wrap_text("ERROR!\n \n "..err_msg.."\n \npress any key...", math.floor(SCREEN_W/2))
        for i, line in ipairs(lines)
            stdscr\mvaddstr(math.floor(SCREEN_H/2 - #lines/2)+i, math.floor((SCREEN_W-#line)/2), line)
        stdscr\refresh!
        C.doupdate!
        stdscr\getch!

    stdscr\wbkgd(COLORS.REGULAR)
    stdscr\clear!
    stdscr\refresh!

    pads = {}

    do -- Err pad
        err_msg_lines = wrap_text(err_msg, SCREEN_W - 4)
        for i,line in ipairs(err_msg_lines)
            err_msg_lines[i] = (" ")\rep(math.floor((SCREEN_W-2-#line)/2))..line
        pads.err = Pad(0,0,AUTO,SCREEN_W, err_msg_lines, "Error Message", {
            line_colors: setmetatable({}, __index:->COLORS.RED | C.A_BOLD)
            inactive_frame: COLORS.RED | C.A_DIM
        })

    stack_locations = {}
    do -- Stack pad
        stack_names = {}
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
        err_line = nil
        if file
            i = 0
            for line in file\gmatch("[^\n]*")
                i += 1
                --if i < line_no-(pads.stack.height-2)/2
                --    continue
                table.insert src_lines, line
                if i == line_no
                    err_line = #src_lines
                --if #src_lines >= pads.stack.height-2
                --    break
            while #src_lines < pads.stack.height
                table.insert(src_lines, "")
        else
            table.insert(src_lines, "<no source code found>")

        if pads.src
            pads.src\erase!
        pads.src = Pad(pads.err.height,pads.stack.x+pads.stack.width,
            pads.stack.height,SCREEN_W-pads.stack.x-pads.stack.width-0, src_lines, "(S)ource Code", {
                line_colors:setmetatable({[err_line or -1]:COLORS.RED_BG}, {__index:(i)=> (i % 2 == 0) and INVERTED or REGULAR})
            })
        pads.src\select(err_line)
    
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
            collectgarbage()
            collectgarbage()

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
                selected_pad\scroll(1,0)
            when ('J')\byte!
                selected_pad\scroll(10,0)

            when C.KEY_UP, C.KEY_SR, ("k")\byte!
                selected_pad\scroll(-1,0)
            when ('K')\byte!
                selected_pad\scroll(-10,0)

            when C.KEY_RIGHT, ("l")\byte!
                selected_pad\scroll(0,1)
            when ("L")\byte!
                selected_pad\scroll(0,10)

            when C.KEY_LEFT, ("h")\byte!
                selected_pad\scroll(0,-1)
            when ("H")\byte!
                selected_pad\scroll(0,-10)

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
                C.endwin!
                os.execute((os.getenv("EDITOR") or "nano").." +"..line_no.." "..filename)
                stdscr = C.initscr!
                C.cbreak!
                C.echo(false)
                C.nl(false)
                C.curs_set(0)
                C.start_color!
                C.use_default_colors!
                stdscr\clear!
                stdscr\refresh!
                for _,pad in pairs(pads) do pad\refresh!

            when ('q')\byte!, ("Q")\byte!
                pads = {}
                C.endwin!
                return

    C.endwin!


guard = (fn, ...)->
    err_hand = (err)->
        log\write(err.."\n\n\n")
        C.endwin!
        print "Caught an error:"
        print(debug.traceback(err, 2))
        os.exit(2)

    return xpcall(fn, ((err_msg)-> xpcall(run_debugger, err_hand, err_msg)), ...)

breakpoint = ->
    err_hand = (err)->
        log\write(err.."\n\n\n")
        C.endwin!
        print "Caught an error:"
        print(debug.traceback(err, 2))
        os.exit(2)

    return xpcall(run_debugger, err_hand, "Breakpoint triggered!")

return {:guard, :breakpoint}
