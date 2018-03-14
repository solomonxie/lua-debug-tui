C = require "curses"
repr = require 'repr'
COLORS = {}
local run_debugger, guard, stdscr, main_loop
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
        if info.func == main_loop
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

err_pad, stack_pad, src_pad, var_names, var_values = nil, nil, nil, nil, nil

main_loop = (err_msg, stack_index, var_index, value_index)->
    export err_pad, stack_pad, var_names, var_values
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

    if not err_pad
        err_msg_lines = wrap_text(err_msg, SCREEN_W - 4)
        for i,line in ipairs(err_msg_lines)
            err_msg_lines[i] = (" ")\rep(math.floor((SCREEN_W-2-#line)/2))..line
        err_pad = Pad(0,0,AUTO,SCREEN_W, err_msg_lines, "Error Message", {
            even_row: COLORS.RED | C.A_BOLD, odd_row: COLORS.RED | C.A_BOLD,
            inactive_frame: COLORS.RED | C.A_DIM
        })

    if not stack_pad
        stack_pad = Pad(err_pad.height,0,math.max(#callstack+2, 20),AUTO, callstack, "Callstack")
        stack_pad.label = "Callstack"
        stack_pad\set_active(true)
        stack_pad\refresh!

        stack_pad.on_select = (stack_index)=>
            filename, line_no = stack_pad.lines[stack_index]\match("([^:]*):(%d*).*")
            line_no = tonumber(line_no)
            file = file_cache[filename]
            src_lines = {}
            selected = nil
            i = 0
            for line in file\gmatch("[^\n]*")
                i += 1
                if i < line_no-(@height-2)/2
                    continue
                table.insert src_lines, line
                if i == line_no
                    selected = #src_lines
                if #src_lines >= @height-2
                    break
            export src_pad
            if src_pad
                src_pad\erase!
            src_pad = Pad(err_pad.height,stack_pad.x+stack_pad.width,
                stack_pad.height,SCREEN_W-stack_pad.x-stack_pad.width-0, src_lines, "Source Code", {
                    highlight: COLORS.RED_BG,
                    inactive_frame: COLORS.GREEN | C.A_BOLD,
                })
            src_pad\select(selected)

    stack_index = stack_pad\select(stack_index)

    if var_names
        var_names\erase!
    if var_values
        var_values\erase!

    callstack_min, _ = callstack_range!
    _var_names, _var_values = {}, {}
    for loc=1,999
        name, value = debug.getlocal(callstack_min+stack_index-1, loc)
        if value == nil then break
        table.insert(_var_names, tostring(name))
        if type(value) == 'function'
            info = debug.getinfo(value, 'nS')
            --var_values\add_line(("function: %s @ %s:%s")\format(info.name or '???', info.short_src, info.linedefined))
            table.insert(_var_values, repr(info))
        else
            table.insert(_var_values, repr(value))
    
    var_y = stack_pad.y + stack_pad.height
    var_x = 0
    var_names = Pad(var_y,var_x,math.min(2+#_var_names, SCREEN_H-err_pad.height-stack_pad.height),AUTO,_var_names,"Vars")
    if var_index and #_var_names > 0
        var_names\set_active(value_index == nil)
        stack_pad\set_active(false)
        stack_pad\refresh!
        var_index = var_names\select(var_index)
    else
        stack_pad\set_active(true)
        stack_pad\refresh!

    value_x = var_names.x+var_names.width
    value_w = SCREEN_W-(value_x)
    if value_index
        var_values = Pad(var_y,value_x,var_names.height,value_w,wrap_text(_var_values[var_index], value_w-2), "Values")
        var_values\set_active(true)
        value_index = var_values\select(value_index)
    else
        var_values = Pad(var_y,value_x,var_names.height,value_w,_var_values, "Values")
        var_values\set_active(false)

    while true
        C.doupdate!
        c = stdscr\getch!
        switch c
            when C.KEY_DOWN, C.KEY_SF, ("j")\byte!
                if value_index
                    value_index += 1
                elseif var_index
                    var_index += 1
                else
                    stack_index += 1
                return main_loop(err_msg,stack_index,var_index,value_index)

            when C.KEY_UP, C.KEY_SR, ("k")\byte!
                if value_index
                    value_index -= 1
                elseif var_index
                    var_index -= 1
                else
                    stack_index -= 1
                return main_loop(err_msg,stack_index,var_index,value_index)

            when ('J')\byte!
                if value_index
                    value_index += 10
                elseif var_index
                    var_index += 10
                else
                    stack_index += 10
                return main_loop(err_msg,stack_index,var_index,value_index)

            when ('K')\byte!
                if value_index
                    value_index -= 10
                elseif var_index
                    var_index -= 10
                else
                    stack_index -= 10
                return main_loop(err_msg,stack_index,var_index,value_index)

            when C.KEY_RIGHT, ("l")\byte!
                if var_index == nil
                    var_index = 1
                elseif value_index == nil
                    value_index = 1
                return main_loop(err_msg,stack_index,var_index,value_index)

            when C.KEY_LEFT, ("h")\byte!
                if value_index
                    value_index = nil
                elseif var_index
                    var_index = nil
                return main_loop(err_msg,stack_index,var_index,value_index)

            when ('o')\byte!
                file = stack_locations[stack_pad.selected]
                filename,line_no = file\match("([^:]*):(.*)")
                -- Launch system editor and then redraw everything
                err_pad, stack_pad, src_pad, var_names, var_values = nil, nil, nil, nil, nil
                C.endwin!
                os.execute((os.getenv("EDITOR") or "nano").." +"..line_no.." "..filename)
                initial_index = stack_pad.selected
                return main_loop(err_msg,stack_pad.selected,var_index)

            when ('q')\byte!, ("Q")\byte!
                break

    err_pad, stack_pad, src_pad, var_names, var_values = nil, nil, nil, nil, nil
    C.endwin!

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

    return main_loop(err_msg, 1)


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
