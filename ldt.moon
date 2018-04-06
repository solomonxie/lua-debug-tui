C = require "curses"
re = require 're'
local ldb
AUTO = {} -- Singleton
PARENT = {} -- Singleton

_error = error
_assert = assert

log = io.open('output.log','w')
toggle = (field, bit)->
    if field & bit != 0
        log\write(("%x ~ %x -> %x\n")\format(field, bit, field & ~bit))
        field & ~bit
    else
        log\write(("%x ~ %x -> %x\n")\format(field, bit, field | bit))
        field | bit

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


local Color
do
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
        attr <- "blink" / "bold" / "dim" / "invis" / "normal" / "protect" / "reverse" / "standout" / "underline" / "altcharset"
        color <- "black" / "blue" / "cyan" / "green" / "magenta" / "red" / "white" / "yellow" / "default"
    ]]
    C.COLOR_DEFAULT = -1
    Color = (s="default")->
        t = _assert(color_lang\match(s), "Invalid color: #{s}")
        if t.fg then t.fg = C["COLOR_"..t.fg\upper!]
        if t.bg then t.bg = C["COLOR_"..t.bg\upper!]
        c = make_color(t.fg, t.bg)
        for a in *t.attrs
            c |= C["A_"..a\upper!]
        return c


class Pad
    new: (@label,@y,@x,height,width,...)=>
        @scroll_y, @scroll_x = 1, 1
        @selected = nil

        @columns = {}
        @column_widths = {}
        @active_frame = Color("yellow bold")
        @inactive_frame = Color("blue dim")
        @colors = {}
        for i=1,select('#',...)-1,2
            col = select(i, ...)
            table.insert(@columns, col)
            w = 0
            for chunk in *col do w = math.max(w, #chunk)
            table.insert(@column_widths, w)
            color_fn = select(i+1,...) or ((i)=>Color())
            _assert(type(color_fn) == 'function', "Invalid color function type: #{type color_fn}")
            table.insert(@colors, color_fn)

        @configure_size height, width
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
        chstr = _assert(@chstrs[i], "Failed to find chstrs[#{i}]")
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
                chstr\set_ch(x, C.ACS_VLINE, Color("black bold"))
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
            @scroll_y = math.max(1, math.min(@_height, @scroll_y))

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
            @scroll_y = math.max(1, math.min(@_height-(@height-2-1), @scroll_y+(dy or 0)))
        @scroll_x = math.max(1, math.min(@_width-(@width-2-1), @scroll_x+(dx or 0)))
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

    keypress: (c)=>
        switch c
            when C.KEY_DOWN, C.KEY_SR, ("j")\byte!
                @scroll(1,0)
            when ('J')\byte!
                @scroll(10,0)

            when C.KEY_UP, C.KEY_SF, ("k")\byte!
                @scroll(-1,0)
            when ('K')\byte!
                @scroll(-10,0)

            when C.KEY_RIGHT, ("l")\byte!
                @scroll(0,1)
            when ("L")\byte!
                @scroll(0,10)

            when C.KEY_LEFT, ("h")\byte!
                @scroll(0,-1)
            when ("H")\byte!
                @scroll(0,-10)
    
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
        cols = {line_nums, ((i)=> i == @selected and Color() or Color("yellow")), ...}
        super @label, @y, @x, height, width, unpack(cols)


line_matcher = re.compile('lines<-{|(line "\n")* line|} line<-{[^\n]*}')
expansions = {}
KEY = {}
VALUE = {}
TOP_LOCATION = {}
locations = {}
Location = (old_loc, kind, key)->
    if old_loc == nil
        return TOP_LOCATION
    unless locations[old_loc]
        locations[old_loc] = {}
    unless locations[old_loc][kind]
        locations[old_loc][kind] = {}
    unless locations[old_loc][kind][key]
        locations[old_loc][kind][key] = {:old_loc, :kind, :key}
    return locations[old_loc][kind][key]

expand = (kind, key, location)->
    expansions[Location(location, kind, key)] = true
collapse = (kind, key, location)->
    expansions[Location(location, kind, key)] = nil
is_key_expanded = (location, key)->
    expansions[Location(location, KEY, key)]
is_value_expanded = (location, key)->
    expansions[Location(location, VALUE, key)]

TYPE_COLORS = setmetatable({}, {__index: 0})

colored_repr = (x, width, depth=2)->
    depth -= 1
    x_type = type(x)
    if x_type == 'table' then
        if next(x) == nil
            return {"{}", TYPE_COLORS.table}
        if depth == 0
            return {"{", TYPE_COLORS.table, "...", Color('white'), "}", TYPE_COLORS.table}
        ret = {"{", TYPE_COLORS.table}
        i = 1
        for k, v in pairs(x)
            if k == i
                for s in *colored_repr(x[i], width, depth) do ret[#ret+1] = s
                i = i + 1
            else
                for s in *colored_repr(k, width, depth) do ret[#ret+1] = s
                ret[#ret+1] = ' = '
                ret[#ret+1] = Color('white')
                for s in *colored_repr(v, width, depth) do ret[#ret+1] = s
            ret[#ret+1] = ', '
            ret[#ret+1] = Color('white')
        if #ret > 2
            ret[#ret] = nil
            ret[#ret] = nil
        len = 0
        for i=1,#ret-1,2 do len += #ret[i]
        for i=#ret-1,3,-2
            if len <= width-1
                break
            if ret[i+2]
                ret[i+2], ret[i+3] = nil, nil
            ret[i] = '...'
            ret[i+1] = Color('white')
        ret[#ret+1] = '}'
        ret[#ret+1] = TYPE_COLORS.table
        return ret
    elseif x_type == 'string'
        ret = {(x\match('^[^\n]*')), TYPE_COLORS.string}
        for line in x\gmatch('\n([^\n]*)')
            ret[#ret+1] = '\\n'
            ret[#ret+1] = Color('white on black')
            ret[#ret+1] = line
            ret[#ret+1] = TYPE_COLORS.string
        len = 0
        for i=1,#ret-1,2 do len += #ret[i]
        for i=#ret-1,1,-2
            if len <= width then break
            if ret[i+2]
                ret[i+2], ret[i+3] = nil, nil
            len -= #ret[i]
            if len <= width
                ret[i] = ret[i]\sub(1, width-len-3)
                ret[i+2] = '...'
                ret[i+3] = Color('blue')
                break
        return ret
    else
        s = tostring(x)
        return if #s > width
            {s\sub(1,width-3), TYPE_COLORS[type(x)], '...', Color('blue')}
        else
            {s, TYPE_COLORS[type(x)]}

make_lines = (location, x, width)->
    -- Return a list of {location=location, text1, color1, text2, color2, ...}
    switch type(x)
        when 'string'
            lines = {}
            for line in *line_matcher\match(x)
                wrapped = wrap_text(line, width-1)
                for i,subline in ipairs(wrapped)
                    _line = {location:location}
                    if i > 1
                        table.insert(_line, C.ACS_BULLET)
                        table.insert(_line, Color('black bold altcharset'))
                    table.insert(_line, subline)
                    table.insert(_line, Color('blue on black'))
                    table.insert(lines, _line)
            if #lines == 0
                table.insert lines, {:location, "''", Color('blue')}
            return lines
        when 'table'
            prepend = (line, ...)->
                for i=1,select('#', ...)
                    table.insert(line, i, (select(i, ...)))
            lines = {}
            for k,v in pairs(x)
                if is_key_expanded(location, k) and is_value_expanded(location, k)
                    table.insert lines, {
                        location:Location(location,KEY,k), 'key', Color('green bold'),
                        '/', Color!, 'value', Color('blue bold'), ':', Color('white')}
                    key_lines = make_lines(Location(location, KEY, k), k, width-1)
                    for i,key_line in ipairs(key_lines)
                        if i == 1
                            prepend(key_line, ' ', Color!, C.ACS_DIAMOND, Color('green bold'), ' ', Color!)
                        else
                            prepend(key_line, '   ', Color!)
                        table.insert(lines, key_line)
                    value_lines = make_lines(Location(location, VALUE, k), v, width-2)
                    for i,value_line in ipairs(value_lines)
                        if i == 1
                            prepend(value_line, ' ', Color!, C.ACS_DIAMOND, Color('blue bold'), ' ', Color!)
                        else
                            prepend(value_line, '   ', Color!)
                        table.insert(lines, value_line)
                elseif is_value_expanded(location, k)
                    k_str = colored_repr(k,width-1)
                    table.insert lines, {
                        location:Location(location, KEY, k),
                        '-', Color('red'), unpack(k_str)
                    }

                    v_lines = make_lines(Location(location, VALUE, k), v, width-1)
                    prepend(v_lines[1], '  ', Color!)
                    for i=2,#v_lines
                        prepend(v_lines[i], '  ', Color!)
                    for v_line in *v_lines do table.insert(lines, v_line)
                elseif is_key_expanded(location, k)
                    k_lines = make_lines(Location(location, KEY, k), k, width-4)
                    for i=1,#k_lines
                        prepend(k_lines[i], '    ', Color!)
                    for k_line in *k_lines do table.insert(lines, k_line)

                    v_str = colored_repr(v,width-2)
                    table.insert(lines, {location:Location(location, VALUE, k), '  ', Color!, unpack(v_str)})
                else
                    k_space = math.floor((width-4)/3)
                    k_str = colored_repr(k,k_space)
                    v_space = (width-4)-#k_str
                    v_str = colored_repr(v,v_space)
                    line = {
                        location:Location(location, VALUE, k),
                        '+', Color('green'),
                        unpack(k_str)
                    }
                    table.insert line, ' = '
                    table.insert line, Color('white')
                    for s in *v_str do table.insert(line, s)
                    table.insert(lines, line)
            if #lines == 0
                table.insert lines, {:location, '{}', TYPE_COLORS.table}
            return lines
        else
            str = tostring(x)
            if #str > width
                str = str\sub(1,width-3)..'...'
            return {{:location, str, TYPE_COLORS[type(x)]}}


class DataViewer extends Pad
    new: (@data,@label,@y,@x,height,width)=>
        @scroll_y, @scroll_x = 1, 1
        @selected = nil

        @active_frame = Color("yellow bold")
        @inactive_frame = Color("blue dim")

        @expansions = {}
        @full_refresh = ->
            old_location = @selected and @chstr_locations and @chstr_locations[@selected]
            @chstrs, @chstr_locations = {}, {}
            line_matcher = re.compile('lines<-{|(line "\n")* line|} line<-{[^\n]*}')
            W = width-3
            lines = make_lines(TOP_LOCATION, @data, W)
            for i,line in ipairs(lines)
                chstr = C.new_chstr(W)
                if i == @selected
                    chstr\set_ch(0, C.ACS_RARROW, Color('yellow bold'))
                else
                    chstr\set_str(0, ' ', Color('yellow bold'))
                offset = 1
                for j=1,#line-1,2
                    chunk, attrs = line[j], line[j+1]
                    if type(chunk) == 'number'
                        chstr\set_ch(offset, chunk, attrs)
                        offset += 1
                    else
                        chstr\set_str(offset, chunk, attrs)
                        offset += #chunk
                if offset < W
                    chstr\set_str(offset, ' ', attrs, W-offset)
                table.insert @chstrs, chstr
                table.insert @chstr_locations, line.location

            @_height, @_width = #@chstrs, @width-2
            @_pad\resize(@_height, @_width)
            for i,chstr in ipairs(@chstrs)
                @_pad\mvaddchstr(i-1,0,chstr)
            @dirty = true
            if old_location
                for i,loc in ipairs(@chstr_locations)
                    if loc == old_location
                        @select(i)
                        break

        @height, @width = height, width
        @_frame = C.newwin(@height, @width, @y, @x)
        @_frame\immedok(true)
        @_pad = C.newpad(@height-2, @width-2)
        @_pad\scrollok(true)
        @set_active false
        
        @full_refresh!
        @select 1

    setup_chstr:(i)=>

    configure_size: (@height, @width)=>
        @_height, @_width = #@chstrs, @width-2

    select:(i)=>
        if #@chstrs == 0 then i = nil
        if i == @selected then return @selected
        old_y, old_x = @scroll_y, @scroll_x
        if i != nil
            i = math.max(1, math.min(#@chstrs, i))
        
        old_selected,@selected = @selected,i

        if old_selected and @chstrs[old_selected]
            @chstrs[old_selected]\set_str(0, ' ', Color('yellow bold'))
            @_pad\mvaddchstr(old_selected-1,0,@chstrs[old_selected])

        if @selected
            @chstrs[@selected]\set_ch(0, C.ACS_RARROW, Color('yellow bold'))
            @_pad\mvaddchstr(@selected-1,0,@chstrs[@selected])

            scrolloff = 3
            if @selected > @scroll_y + (@height-2) - scrolloff
                @scroll_y = @selected - (@height-2) + scrolloff
            elseif @selected < @scroll_y + scrolloff
                @scroll_y = @selected - scrolloff
            @scroll_y = math.max(1, math.min(@_height, @scroll_y))

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

    keypress: (c)=>
        switch c
            when C.KEY_DOWN, C.KEY_SR, ("j")\byte!
                @scroll(1,0)
            when ('J')\byte!
                @scroll(10,0)

            when C.KEY_UP, C.KEY_SF, ("k")\byte!
                @scroll(-1,0)
            when ('K')\byte!
                @scroll(-10,0)

            when C.KEY_RIGHT, ("l")\byte!
                expansions[@chstr_locations[@selected]] = true
                @full_refresh!
            when ("L")\byte!
                expansions[@chstr_locations[@selected]] = true
                @full_refresh!

            when C.KEY_LEFT, ("h")\byte!
                loc = @chstr_locations[@selected]
                if expansions[loc] == nil
                    loc = Location(loc.old_loc, (loc.kind == KEY and VALUE or KEY), loc.key)
                while loc and expansions[loc] == nil
                    loc = loc.old_loc
                if loc
                    expansions[loc] = nil
                @full_refresh!
                if loc and @chstr_locations[@selected] != loc
                    for i,chstr_loc in ipairs(@chstr_locations)
                        if chstr_loc == loc
                            @select(i)
                            break
                elseif not loc
                    @select(1)

            when ("H")\byte!
                loc = @chstr_locations[@selected]
                if expansions[loc] == nil
                    loc = Location(loc.old_loc, (loc.kind == KEY and VALUE or KEY), loc.key)
                while loc and expansions[loc] == nil
                    loc = loc.old_loc
                if loc
                    expansions[loc] = nil
                @full_refresh!
                if loc and @chstr_locations[@selected] != loc
                    for i,chstr_loc in ipairs(@chstr_locations)
                        if chstr_loc == loc
                            @select(i)
                            break
                elseif not loc
                    @select(1)

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
        err_msg or= ''
        stdscr = C.initscr!
        SCREEN_H, SCREEN_W = stdscr\getmaxyx!
        C.cbreak!
        C.echo(false)
        C.nl(false)
        C.curs_set(0)
        C.start_color!
        C.use_default_colors!
        with TYPE_COLORS
            .string = Color('blue on black')
            .number = Color('magenta')
            .boolean = Color('cyan')
            .nil = Color('cyan')
            .table = Color('yellow')
            .function = Color('green')
            .userdata = Color('cyan bold')
            .thread = Color('blue')

        do -- Fullscreen flash
            stdscr\wbkgd(Color"yellow on red bold")
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

        stdscr\keypad!
        stdscr\wbkgd(Color!)
        stdscr\clear!
        stdscr\refresh!

        pads = {}

        do -- Err pad
            err_msg_lines = wrap_text(err_msg, SCREEN_W - 4)
            for i,line in ipairs(err_msg_lines)
                err_msg_lines[i] = (" ")\rep(2)..line
            pads.err = Pad("Error Message", 0,0,AUTO,SCREEN_W, err_msg_lines, (i)=> Color("red bold"))
            pads.err._frame\attrset(Color("red"))
            pads.err\refresh!

        stack_locations = {}
        err_lines = {}
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
                err_lines[line] = true
                table.insert(stack_locations, line)
                max_filename = math.max(max_filename, #line)
                max_fn_name = math.max(max_fn_name, #fn_name)
            max_fn_name, max_filename = 0, 0
            for i=1,#stack_names do
                max_fn_name = math.max(max_fn_name, #stack_names[i])
                max_filename = math.max(max_filename, #stack_locations[i])

            stack_h = math.max(#stack_names+2, math.floor(2/3*SCREEN_H))
            stack_w = math.min(max_fn_name + 3 + max_filename, math.floor(1/3*SCREEN_W))
            pads.stack = Pad "(C)allstack",pads.err.height,SCREEN_W-stack_w,stack_h,stack_w,
                stack_names, ((i)=> (i == @selected) and Color("black on green") or Color("green bold")),
                stack_locations, ((i)=> (i == @selected) and Color("black on cyan") or Color("cyan bold"))
        
        show_src = (filename, line_no)->
            if pads.src
                if pads.src.filename == filename
                    pads.src\select(line_no)
                    pads.src.colors[2] = (i)=>
                        return if i == line_no and i == @selected then Color("yellow on red bold")
                        elseif i == line_no then Color("yellow on red")
                        elseif err_lines["#{filename}:#{i}"] == true then Color("red on black bold")
                        elseif i == @selected then Color("reverse")
                        else Color()
                    for line,_ in pairs(err_lines)
                        _filename, i = line\match("([^:]*):(%d*).*")
                        if _filename == filename and tonumber(i)
                            pads.src\setup_chstr(tonumber(i))
                    pads.src\select(line_no)
                    return
                else
                    pads.src\erase!
            file = file_cache[filename]
            if file
                src_lines = {}
                for line in (file..'\n')\gmatch("([^\n]*)\n")
                    table.insert src_lines, line
                pads.src = NumberedPad "(S)ource Code", pads.err.height,0,
                    pads.stack.height,pads.stack.x, src_lines, (i)=>
                        return if i == line_no and i == @selected then Color("yellow on red bold")
                        elseif i == line_no then Color("yellow on red")
                        elseif err_lines["#{filename}:#{i}"] == true then Color("red on black bold")
                        elseif i == @selected then Color("reverse")
                        else Color()
                pads.src\select(line_no)
            else
                lines = {}
                for i=1,math.floor(pads.stack.height/2)-1 do table.insert(lines, "")
                s = "<no source code found>"
                s = (" ")\rep(math.floor((pads.stack.x-2-#s)/2))..s
                table.insert(lines, s)
                pads.src = Pad "(S)ource Code", pads.err.height,0,pads.stack.height,pads.stack.x,lines, ->Color("red")
            pads.src.filename = filename
        
        local stack_env
        show_vars = (stack_index)->
            if pads.vars
                pads.vars\erase!
            if pads.values
                pads.values\erase!
            callstack_min, _ = callstack_range!
            var_names, values = {}, {}
            stack_env = setmetatable({}, {__index:_G})
            for loc=1,999
                name, value = debug.getlocal(callstack_min+stack_index-1, loc)
                if name == nil then break
                table.insert(var_names, tostring(name))
                table.insert(values, value)
                stack_env[name] = value
            
            var_y = pads.stack.y + pads.stack.height
            var_x = 0
            --height = math.min(2+#var_names, SCREEN_H-pads.err.height-pads.stack.height)
            height = SCREEN_H-(pads.err.height+pads.stack.height)
            pads.vars = Pad "(V)ars", var_y,var_x,height,AUTO,var_names, ((i)=> i == @selected and Color('reverse') or Color())

            pads.vars.on_select = (var_index)=>
                if var_index == nil then return
                value_x = pads.vars.x+pads.vars.width
                value_w = SCREEN_W-(value_x)
                value = values[var_index]
                type_str = type(value)
                -- Show single value:
                pads.values = DataViewer value, "(D)ata [#{type_str}]", var_y,value_x,pads.vars.height,value_w
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
                p\refresh!
            s = " press 'q' to quit "
            stdscr\mvaddstr(math.floor(SCREEN_H - 1), math.floor((SCREEN_W-#s)), s)
            --C.doupdate!
            c = stdscr\getch!
            switch c
                when (':')\byte!, ('>')\byte!, ('?')\byte!
                    C.echo(true)
                    print_nil = false
                    code = ''
                    if c == ('?')\byte!
                        stdscr\mvaddstr(SCREEN_H-1, 0, "? "..(' ')\rep(SCREEN_W-1))
                        stdscr\move(SCREEN_H-1, 2)
                        code = 'return '..stdscr\getstr!
                        print_nil = true
                    elseif c == (':')\byte! or c == ('>')\byte!
                        numlines = 1
                        stdscr\mvaddstr(SCREEN_H-1, 0, "> "..(' ')\rep(SCREEN_W-1))
                        stdscr\move(SCREEN_H-1, 2)
                        while true
                            line = stdscr\getstr!
                            if line == '' then break
                            code ..= line..'\n'
                            numlines += 1
                            stdscr\mvaddstr(SCREEN_H-numlines, 0, "> "..((' ')\rep(SCREEN_W)..'\n')\rep(numlines))
                            stdscr\mvaddstr(SCREEN_H-numlines, 2, code)
                            stdscr\mvaddstr(SCREEN_H-1, 0, (' ')\rep(SCREEN_W))
                            stdscr\move(SCREEN_H-1, 0)
                    C.echo(false)
                    output = ""
                    if not stack_env
                        stack_env = setmetatable({},  {__index:_G})
                    stack_env.print = (...)->
                        for i=1,select('#',...)
                            if i > 1 then output ..= '\t'
                            output ..= tostring(select(i, ...))
                        output ..= "\n"

                    for _,p in pairs(pads)
                        p\refresh(true)

                    run_fn, err_msg = load(code, 'user input', 't', stack_env)
                    if not run_fn
                        stdscr\addstr(err_msg)
                    else
                        ret = run_fn!
                        if ret != nil or print_nil
                            output ..= '= '
                            bits = colored_repr(ret, SCREEN_W-2, 4)
                            for i=1,#bits-1,2
                                output ..= bits[i]
                            output ..= '\n'
                        numlines = 0
                        for nl in output\gmatch('\n') do numlines += 1
                        stdscr\mvaddstr(SCREEN_H-numlines, 0, output)


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
                    for _,pad in pairs(pads) do pad\refresh(true)
                
                when C.KEY_RESIZE
                    SCREEN_H, SCREEN_W = stdscr\getmaxyx!
                    stdscr\clear!
                    stdscr\refresh!
                    for _,pad in pairs(pads) do pad\refresh(true)
                    C.doupdate!

                when ('q')\byte!, ("Q")\byte!
                    pads = {}
                    C.endwin!
                    return

                when ('c')\byte!
                    select_pad(pads.stack) -- (C)allstack

                when ('s')\byte!
                    select_pad(pads.src) -- (S)ource Code

                when ('v')\byte!
                    select_pad(pads.vars) -- (V)ars

                when ('d')\byte!
                    select_pad(pads.values) -- (D)ata
                
                else
                    selected_pad\keypress(c)

        C.endwin!

    guard: (fn, ...)->
        handler = (err_msg)->
            xpcall(ldb.run_debugger, err_hand, err_msg)
            print(debug.traceback(err_msg, 2))
        return xpcall(fn, handler, ...)

    breakpoint: ->
        return xpcall(ldb.run_debugger, err_hand, "Breakpoint triggered!")

    hijack: ->
        export error, assert
        error = (err_msg)->
            xpcall(ldb.run_debugger, err_hand, err_msg)
            print(debug.traceback(err_msg, 2))
            os.exit(2)

        assert = (condition, err_msg)->
            if not condition
                err_msg or= 'Assertion failed!'
                xpcall(ldb.run_debugger, err_hand, err_msg)
                print(debug.traceback(err_msg, 2))
                os.exit(2)
            return condition

}
return ldb
