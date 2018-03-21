C = require "curses"
re = require 're'
repr = require 'repr'
local ldb, stdscr
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
        if info.func == ldb.run_debugger
            min = i+2
            break
    for i=min,999
        info = debug.getinfo(i, 'f')
        if not info or info.func == ldb.guard
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


class Pad
    new: (@label,@y,@x,height,width,...)=>
        @scroll_y, @scroll_x = 1, 1
        @selected = nil

        @columns = {}
        @column_widths = {}
        @active_frame = color("white bold")
        @inactive_frame = color("blue dim")
        @colors = {}
        for i=1,select('#',...)-1,2
            col = select(i, ...)
            table.insert(@columns, col)
            w = 0
            for chunk in *col do w = math.max(w, #chunk)
            table.insert(@column_widths, w)
            color_fn = select(i+1,...) or ((i)=>color())
            assert(type(color_fn) == 'function', "Invalid color function type: #{type color_fn}")
            table.insert(@colors, color_fn)

        @configure_size height, width
        log\write("New pad: #{@height},#{@width}  #{@_height},#{@_width}\n")
        @_frame = C.newwin(@height, @width, @y, @x)
        @_frame\immedok(true)
        @_pad = C.newpad(@_height, @_width)
        @_pad\scrollok(true)
        @set_active false
        @chstrs = {}
        for i=1,#@columns[1]
            @chstrs[i] = C.new_chstr(@_width)
            @setup_chstr(i)
        @dirty = true
    
    configure_size: (@height, @width)=>
        @_height = math.max(#@columns[1], 1)
        if @height == AUTO
            @height = @_height + 2

        @_width = #@columns-1
        for i,col in ipairs(@columns)
            col_width = 0
            for chunk in *col do col_width = math.max(col_width, #chunk)
            @_width += col_width
        @_width = math.max(@_width, 1)
        if @width == AUTO
            @width = @_width + 2

    setup_chstr: (i)=>
        chstr = @chstrs[i]
        x = 0
        for c=1,#@columns
            attr = @colors[c](@, i)
            chunk = @columns[c][i]
            chstr\set_str(x, chunk, attr)
            x += #chunk
            if #chunk < @column_widths[c]
                chstr\set_str(x, " ", attr, @column_widths[c]-#chunk)
                x += @column_widths[c]-#chunk
            if c < #@columns
                chstr\set_ch(x, C.ACS_VLINE, color("black bold"))
                x += 1
        @_pad\mvaddchstr(i-1,0,chstr)
        @dirty = true
    
    set_active: (active)=>
        return if active == @active
        @active = active
        @_frame\attrset(active and @active_frame or @inactive_frame)
        @dirty = true
    
    select: (i)=>
        if #@columns[1] == 0 then i = nil
        if i == @selected then return @selected
        old_y, old_x = @scroll_y, @scroll_x
        if i != nil
            i = math.max(1, math.min(#@columns[1], i))
        
        old_selected,@selected = @selected,i

        if old_selected
            @setup_chstr(old_selected)

        if @selected
            @setup_chstr(@selected)

            scrolloff = 3
            if @selected > @scroll_y + (@height-2) - scrolloff
                @scroll_y = @selected - (@height-2) + scrolloff
            elseif @selected < @scroll_y + scrolloff
                @scroll_y = @selected - scrolloff
            @scroll_y = math.max(1, math.min(#@columns[1], @scroll_y))

        if @scroll_y == old_y
            w = math.min(@width-2,@_width)
            if old_selected and @scroll_y <= old_selected and old_selected <= @scroll_y + @height-2
                @_pad\pnoutrefresh(old_selected-1,@scroll_x-1,@y+1+(old_selected-@scroll_y),@x+1,@y+1+(old_selected-@scroll_y)+1,@x+w)
            if @selected and @scroll_y <= @selected and @selected <= @scroll_y + @height-2
                @_pad\pnoutrefresh(@selected-1,@scroll_x-1,@y+1+(@selected-@scroll_y),@x+1,@y+1+(@selected-@scroll_y)+1,@x+w)
        else
            @dirty = true

        if @on_select then @on_select(@selected)
        return @selected
    
    scroll: (dy,dx)=>
        old_y, old_x = @scroll_y, @scroll_x
        if @selected != nil
            @select(@selected + (dy or 0))
        else
            @scroll_y = math.max(1, math.min(@_height-@height, @scroll_y+(dy or 0)))
        @scroll_x = math.max(1, math.min(@_width-@width, @scroll_x+(dx or 0)))
        if @scroll_y != old_y or @scroll_x != old_x
            @dirty = true
    
    refresh: (force=false)=>
        return if not force and not @dirty
        @_frame\border(C.ACS_VLINE, C.ACS_VLINE,
            C.ACS_HLINE, C.ACS_HLINE,
            C.ACS_ULCORNER, C.ACS_URCORNER,
            C.ACS_LLCORNER, C.ACS_LRCORNER)
        if @label
            @_frame\mvaddstr(0, math.floor((@width-#@label-2)/2), " #{@label} ")
        @_frame\refresh!
        --@_frame\prefresh(0,0,@y,@x,@y+@height-1,@x+@width-1)
        h,w = math.min(@height-2,@_height),math.min(@width-2,@_width)
        @_pad\pnoutrefresh(@scroll_y-1,@scroll_x-1,@y+1,@x+1,@y+h,@x+w)
        @dirty = false
    
    erase: =>
        @dirty = true
        @_frame\erase!
        @_frame\refresh!
    
    __gc: =>
        @_frame\close!
        @_pad\close!

class NumberedPad extends Pad
    new: (@label,@y,@x,height,width,...)=>
        col1 = select(1, ...)
        fmt = "%#{#tostring(#col1)}d"
        line_nums = [fmt\format(i) for i=1,#col1]
        cols = {line_nums, ((i)=> i == @selected and color("white bold") or color("yellow")), ...}
        super @label, @y, @x, height, width, unpack(cols)

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


-- Cleanup curses and print the error to stdout like regular
err_hand = (err)->
    C.endwin!
    print "Error in debugger."
    print(debug.traceback(err, 2))
    os.exit(2)

ldb = {
    run_debugger: (err_msg)->
        export stdscr, SCREEN_H, SCREEN_W
        stdscr = C.initscr!
        SCREEN_H, SCREEN_W = stdscr\getmaxyx!

        C.cbreak!
        C.echo(false)
        C.nl(false)
        C.curs_set(0)
        C.start_color!
        C.use_default_colors!

        color_index = 0
        existing = {}
        make_color = (fg=-1, bg=-1)->
            key = "#{fg},#{bg}"
            unless existing[key]
                color_index += 1
                C.init_pair(color_index, fg, bg)
                existing[key] = C.color_pair(color_index)
            return existing[key]
        color_lang = re.compile[[
            x <- {|
                {:attrs: {| {attr} (" " {attr})* |} :}
                / (
                    ({:bg: "on " {color} :} / ({:fg: color :} (" on " {:bg: color :})?))
                    {:attrs: {| (" " {attr})* |} :})
            |}
            attr <- "blink" / "bold" / "dim" / "invis" / "normal" / "protect" / "reverse" / "standout" / "underline"
            color <- "black" / "blue" / "cyan" / "green" / "magenta" / "red" / "white" / "yellow" / "default"
        ]]
        C.COLOR_DEFAULT = -1
        export color
        color = (s="default")->
            t = assert(color_lang\match(s), "Invalid color: #{s}")
            if t.fg then t.fg = C["COLOR_"..t.fg\upper!]
            if t.bg then t.bg = C["COLOR_"..t.bg\upper!]
            c = make_color(t.fg, t.bg)
            for a in *t.attrs
                c |= C["A_"..a\upper!]
            return c

        do -- Fullscreen flash
            stdscr\wbkgd(color"yellow on red bold")
            stdscr\clear!
            stdscr\refresh!
            lines = wrap_text("ERROR!\n \n "..err_msg.."\n \npress any key...", math.floor(SCREEN_W/2))
            max_line = 0
            for line in *lines do max_line = math.max(max_line, #line)
            for i, line in ipairs(lines)
                if i == 1 or i == #lines
                    stdscr\mvaddstr(math.floor(SCREEN_H/2 - #lines/2)+i, math.floor((SCREEN_W-#line)/2), line)
                else
                    stdscr\mvaddstr(math.floor(SCREEN_H/2 - #lines/2)+i, math.floor((SCREEN_W-max_line)/2), line)
            stdscr\refresh!
            C.doupdate!
            stdscr\getch!

        stdscr\wbkgd(color!)
        stdscr\clear!
        stdscr\refresh!

        pads = {}

        do -- Err pad
            err_msg_lines = wrap_text(err_msg, SCREEN_W - 4)
            for i,line in ipairs(err_msg_lines)
                err_msg_lines[i] = (" ")\rep(2)..line
            pads.err = Pad("Error Message", 0,0,AUTO,SCREEN_W, err_msg_lines, (i)=> color("red bold"))
            pads.err._frame\attrset(color("red"))
            pads.err\refresh!

        stack_locations = {}
        do -- Stack pad
            stack_names = {}
            max_filename, max_fn_name = 0, 0
            stack_min, stack_max = callstack_range!
            for i=stack_min,stack_max
                info = debug.getinfo(i)
                if not info then break
                fn_name = info.name or "<unnamed function>"
                table.insert(stack_names, fn_name)
                line = if info.short_src
                    line_table = line_tables[info.short_src]
                    if line_table
                        char = line_table[info.currentline]
                        line_num = 1
                        file = file_cache[info.short_src]
                        for _ in file\sub(1,char)\gmatch("\n") do line_num += 1
                        "#{info.short_src}:#{line_num}"
                    else
                        info.short_src..":"..info.currentline
                else
                    "???"
                table.insert(stack_locations, line)
                max_filename = math.max(max_filename, #line)
                max_fn_name = math.max(max_fn_name, #fn_name)
            callstack = {}
            max_fn_name, max_filename = 0, 0
            for i=1,#stack_names do
                fn_name = stack_names[i]
                callstack[i] = {fn_name, stack_locations[i]}
                max_fn_name = math.max(max_fn_name, #fn_name)
                max_filename = math.max(max_filename, #stack_locations[i])

            stack_h = math.max(#callstack+2, math.floor(2/3*SCREEN_H))
            stack_w = max_fn_name + 1 + max_filename
            pads.stack = Pad "(C)allstack",pads.err.height,SCREEN_W-stack_w,stack_h,stack_w,
                stack_names, ((i)=> (i == @selected) and color("black on green") or color("green bold")),
                stack_locations, ((i)=> (i == @selected) and color("black on cyan") or color("cyan bold"))
        
        show_src = (filename, line_no)->
            if pads.src
                pads.src\erase!
            file = file_cache[filename]
            if file
                src_lines = {}
                for line in (file..'\n')\gmatch("([^\n]*)\n")
                    table.insert src_lines, line
                pads.src = NumberedPad "(S)ource Code", pads.err.height,0,
                    pads.stack.height,pads.stack.x, src_lines, (i)=>
                        if i == line_no and i == @selected then return color("yellow on red bold")
                        elseif i == @selected then return color("black on white")
                        elseif i == line_no then return color("red on black bold")
                        return color("white")
                pads.src\select(line_no)
            else
                lines = {}
                for i=1,math.floor(pads.stack.height/2)-1 do table.insert(lines, "")
                s = "<no source code found>"
                s = (" ")\rep(math.floor((pads.stack.x-2-#s)/2))..s
                table.insert(lines, s)
                pads.src = Pad "(S)ource Code", pads.err.height,0,pads.stack.height,pads.stack.x,lines, ->color("red")
        
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
            --height = math.min(2+#var_names, SCREEN_H-pads.err.height-pads.stack.height)
            height = SCREEN_H-(pads.err.height+pads.stack.height)
            pads.vars = Pad "(V)ars", var_y,var_x,height,AUTO,var_names, ((i)=> i == @selected and color('reverse') or color())

            pads.vars.on_select = (var_index)=>
                value_x = pads.vars.x+pads.vars.width
                value_w = SCREEN_W-(value_x)
                -- Show single value:
                if var_index
                    pads.values = Pad "(D)ata",var_y,value_x,pads.vars.height,value_w,wrap_text(values[var_index], value_w-2), (i)=>color()
                else
                    pads.values = Pad "(D)ata",var_y,value_x,pads.vars.height,value_w,{}, (i)=>color()
                collectgarbage()
                collectgarbage()

            pads.vars\select(1)

        pads.stack.on_select = (stack_index)=>
            filename,line_no = pads.stack.columns[2][stack_index]\match("([^:]*):(%d*).*")
            --filename, line_no = pads.stack.lines[stack_index]\match("[^|]*| ([^:]*):(%d*).*")
            line_no = tonumber(line_no)
            show_src(filename, line_no)
            show_vars(stack_index)

        pads.stack\select(1)

        selected_pad = nil
        select_pad = (pad)->
            if selected_pad != pad
                if selected_pad
                    selected_pad\set_active(false)
                    selected_pad\refresh!
                selected_pad = pad
                selected_pad\set_active(true)
                selected_pad\refresh!
        
        select_pad(pads.src)

        while true
            for _,p in pairs(pads)
                if p.dirty
                    p\refresh!
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

                when ('d')\byte!
                    select_pad(pads.values) -- (D)ata

                when ('o')\byte!
                    file = stack_locations[pads.stack.selected]
                    filename,line_no = file\match("([^:]*):(.*)")
                    line_no = tostring(pads.src.selected)
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

    guard: (fn, ...)->
        return xpcall(fn, ((err_msg)-> xpcall(ldb.run_debugger, err_hand, err_msg)), ...)

    breakpoint: ->
        return xpcall(ldb.run_debugger, err_hand, "Breakpoint triggered!")

    hijack_error: ->
        export error
        error = (err_msg)->
            return xpcall(ldb.run_debugger, err_hand, err_msg)
}
return ldb