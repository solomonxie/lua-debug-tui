C = require "curses"
repr = require 'repr'
local REGULAR, INVERTED, HIGHLIGHTED, RED, SCREEN_H, SCREEN_W
local run_debugger, cursed, stdscr, main_loop
AUTO = -1
log = io.open("output.log", "w")

-- Return the callstack index of the code that actually caused an error and the max index
callstack_range = ->
    min, max = 0, -1
    for i=1,999 do
        info = debug.getinfo(i, 'f')
        if not info
            error("Could not find info at level #{i}")
        continue unless info
        if info.func == main_loop
            min = i+2
            break
    for i=min,999
        info = debug.getinfo(i, 'f')
        continue unless info
        if info.func == cursed then
            max = i-3
            break
    return min, max

alternating_colors = setmetatable({}, {__index:(i)=> if i % 2 == 0 then INVERTED else REGULAR})
class Pad
    new: (@y,@x,@height,@width,@lines,@attrs=alternating_colors)=>
        --log\write("New Pad:\n  #{table.concat @lines, "\n  "}\n")
        @offset = 0
        @selected = nil

        @_height = #@lines + 2
        @_width = 2
        for x in *@lines do @_width = math.max(@_width, #x+2)

        if @height == AUTO
            @height = @_height
        if @width == AUTO
            @width = @_width

        --log\write("#lines = #{#@lines}, height = #{@_height}, width = #{@_width}\n")
        @_pad = C.newpad(@_height, @_width)
        @_pad\scrollok(true)

        @chstrs = {}
        for i, line in ipairs(@lines)
            attr = @attrs[i]
            chstr = C.new_chstr(@width-2)
            @chstrs[i] = chstr
            chstr\set_str(0, line, attr)
            chstr\set_str(#line+0, ' ', attr, chstr\len!-#line)
            @_pad\mvaddchstr(i-1+1,0+1,chstr)
        @refresh!
    
    select: (i)=>
        if i == @selected or #@lines == 0 then return
        if i != nil
            i = math.max(1, math.min(#@lines, i))
        if @selected
            j = @selected
            @chstrs[j]\set_str(0, @lines[j], @attrs[j])
            @chstrs[j]\set_str(#@lines[j], ' ', @attrs[j], @chstrs[j]\len!-#@lines[j])
            @_pad\mvaddchstr(j-1+1,0+1,@chstrs[j])

        if i
            assert(@chstrs[i], "DIDN'T FIND CHSTR: #{i}/#{#@chstrs} (#{#@lines})")
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
        @_pad\pnoutrefresh(@offset,0,@y,@x,@y+@height+1,@x+@width)
    
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


main_loop = (err_msg, stack_index=1, var_index)->
    SCREEN_H, SCREEN_W = stdscr\getmaxyx!

    stdscr\clear!
    stdscr\refresh!

    stack_names = {}
    stack_locations = {}
    max_filename = 0
    stack_min, stack_max = callstack_range!
    for i=stack_min,stack_max
        info = debug.getinfo(i)
        if not info then break
        table.insert(stack_names, info.name or "<unnamed function>")
        filename = info.short_src..":"..info.currentline
        table.insert(stack_locations, filename)
        max_filename = math.max(max_filename, #filename)
    callstack = {}
    for i=1,#stack_names do
        callstack[i] = stack_locations[i]..(" ")\rep(max_filename-#stack_locations[i]).." | "..stack_names[i].." "

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
    err_pad = Pad(0,0,AUTO,SCREEN_W, err_msg_lines,setmetatable({}, __index:->RED))
    err_pad._pad\attrset(RED)

    stack_pad = Pad(err_pad.height,0,AUTO,AUTO, callstack)
    stack_pad\select(stack_index)

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
    
    var_names = Pad(err_pad.height,stack_pad.x+stack_pad.width,10,AUTO,_var_names)
    var_values = Pad(err_pad.height,var_names.x+var_names.width,10,AUTO,_var_values)
    if var_index and #_var_names > 0
        var_names\select(var_index)
        var_values\select(var_index)

    while true
        C.doupdate!
        c = stdscr\getch!
        switch c
            when C.KEY_DOWN, C.KEY_SF, ("j")\byte!
                if var_index
                    var_names\scroll(1)
                    return main_loop(err_msg,stack_pad.selected,var_names.selected)
                else
                    stack_pad\scroll(1)
                    return main_loop(err_msg,stack_pad.selected,nil)

            when C.KEY_UP, C.KEY_SR, ("k")\byte!
                if var_index
                    var_names\scroll(-1)
                    return main_loop(err_msg,stack_pad.selected,var_names.selected)
                else
                    stack_pad\scroll(-1)
                    return main_loop(err_msg,stack_pad.selected,nil)

            when ('J')\byte!
                if var_index
                    var_names\scroll(10)
                    return main_loop(err_msg,stack_pad.selected,var_names.selected)
                else
                    stack_pad\scroll(10)
                    return main_loop(err_msg,stack_pad.selected,nil)

            when ('K')\byte!
                if var_index
                    var_names\scroll(-10)
                    return main_loop(err_msg,stack_pad.selected,var_names.selected)
                else
                    stack_pad\scroll(-10)
                    return main_loop(err_msg,stack_pad.selected,nil)

            when C.KEY_RIGHT, ("l")\byte!
                if var_index == nil
                    return main_loop(err_msg,stack_pad.selected,1)

            when C.KEY_LEFT, ("h")\byte!
                if var_index != nil
                    return main_loop(err_msg,stack_pad.selected,nil)

            when ('o')\byte!
                file = stack_locations[stack_pad.selected]
                filename,line_no = file\match("([^:]*):(.*)")
                -- Launch system editor and then redraw everything
                C.endwin!
                os.execute((os.getenv("EDITOR") or "nano").." +"..line_no.." "..filename)
                initial_index = stack_pad.selected
                return main_loop(err_msg,stack_pad.selected,var_index)

            when ('q')\byte!, ("Q")\byte!
                break

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

    export REGULAR, INVERTED, HIGHLIGHTED, RED
    _, REGULAR = C.init_pair(1, -1, -1), C.color_pair(1)
    _, INVERTED = C.init_pair(2, -1, C.COLOR_BLACK), C.color_pair(2)
    _, HIGHLIGHTED = C.init_pair(3, C.COLOR_BLACK, C.COLOR_YELLOW), C.color_pair(3)
    _, RED = C.init_pair(4, C.COLOR_RED, -1), C.color_pair(4) | C.A_BOLD

    return main_loop(err_msg)


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
