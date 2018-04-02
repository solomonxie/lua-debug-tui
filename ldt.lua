local C = require("curses")
local re = require('re')
local repr = require('repr')
local ldb
local AUTO = { }
local PARENT = { }
local _error = error
local _assert = assert
local log = io.open('output.log', 'w')
local toggle
toggle = function(field, bit)
  if field & bit ~= 0 then
    log:write(("%x ~ %x -> %x\n"):format(field, bit, field & ~bit))
    return field & ~bit
  else
    log:write(("%x ~ %x -> %x\n"):format(field, bit, field | bit))
    return field | bit
  end
end
local callstack_range
callstack_range = function()
  local min, max = 0, -1
  for i = 1, 999 do
    local info = debug.getinfo(i, 'f')
    if not info then
      min = i - 1
      break
    end
    if info.func == ldb.run_debugger then
      min = i + 2
      break
    end
  end
  for i = min, 999 do
    local info = debug.getinfo(i, 'f')
    if not info or info.func == ldb.guard then
      max = i - 3
      break
    end
  end
  return min, max
end
local wrap_text
wrap_text = function(text, width)
  local lines = { }
  for line in text:gmatch("[^\n]*") do
    while #line > width do
      table.insert(lines, line:sub(1, width))
      line = line:sub(width + 1, -1)
    end
    if #line > 0 then
      table.insert(lines, line)
    end
  end
  return lines
end
local Color
do
  local color_index = 0
  local existing = { }
  local make_color
  make_color = function(fg, bg)
    if fg == nil then
      fg = -1
    end
    if bg == nil then
      bg = -1
    end
    local key = tostring(fg) .. "," .. tostring(bg)
    if not (existing[key]) then
      color_index = color_index + 1
      C.init_pair(color_index, fg, bg)
      existing[key] = C.color_pair(color_index)
    end
    return existing[key]
  end
  local color_lang = re.compile([[        x <- {|
            {:attrs: {| {attr} (" " {attr})* |} :}
            / (
                ({:bg: "on " {color} :} / ({:fg: color :} (" on " {:bg: color :})?))
                {:attrs: {| (" " {attr})* |} :})
        |}
        attr <- "blink" / "bold" / "dim" / "invis" / "normal" / "protect" / "reverse" / "standout" / "underline" / "altcharset"
        color <- "black" / "blue" / "cyan" / "green" / "magenta" / "red" / "white" / "yellow" / "default"
    ]])
  C.COLOR_DEFAULT = -1
  Color = function(s)
    if s == nil then
      s = "default"
    end
    local t = _assert(color_lang:match(s), "Invalid color: " .. tostring(s))
    if t.fg then
      t.fg = C["COLOR_" .. t.fg:upper()]
    end
    if t.bg then
      t.bg = C["COLOR_" .. t.bg:upper()]
    end
    local c = make_color(t.fg, t.bg)
    local _list_0 = t.attrs
    for _index_0 = 1, #_list_0 do
      local a = _list_0[_index_0]
      c = c | C["A_" .. a:upper()]
    end
    return c
  end
end
local Pad
do
  local _class_0
  local _base_0 = {
    configure_size = function(self, height, width)
      self.height, self.width = height, width
      self._height = math.max(#self.columns[1], 1)
      if self.height == AUTO then
        self.height = self._height + 2
      end
      self._width = #self.columns - 1
      for i, col in ipairs(self.columns) do
        local col_width = 0
        for _index_0 = 1, #col do
          local chunk = col[_index_0]
          col_width = math.max(col_width, #chunk)
        end
        self._width = self._width + col_width
      end
      self._width = math.max(self._width, 1)
      if self.width == AUTO then
        self.width = self._width + 2
      end
    end,
    setup_chstr = function(self, i)
      local chstr = _assert(self.chstrs[i], "Failed to find chstrs[" .. tostring(repr(i)) .. "]")
      local x = 0
      for c = 1, #self.columns do
        local attr = self.colors[c](self, i)
        local chunk = self.columns[c][i]
        chstr:set_str(x, chunk, attr)
        x = x + #chunk
        if #chunk < self.column_widths[c] then
          chstr:set_str(x, " ", attr, self.column_widths[c] - #chunk)
          x = x + (self.column_widths[c] - #chunk)
        end
        if c < #self.columns then
          chstr:set_ch(x, C.ACS_VLINE, Color("black bold"))
          x = x + 1
        end
      end
      self._pad:mvaddchstr(i - 1, 0, chstr)
      self.dirty = true
    end,
    set_active = function(self, active)
      if active == self.active then
        return 
      end
      self.active = active
      self._frame:attrset(active and self.active_frame or self.inactive_frame)
      self.dirty = true
    end,
    select = function(self, i)
      if #self.columns[1] == 0 then
        i = nil
      end
      if i == self.selected then
        return self.selected
      end
      local old_y, old_x = self.scroll_y, self.scroll_x
      if i ~= nil then
        i = math.max(1, math.min(#self.columns[1], i))
      end
      local old_selected
      old_selected, self.selected = self.selected, i
      if old_selected then
        self:setup_chstr(old_selected)
      end
      if self.selected then
        self:setup_chstr(self.selected)
        local scrolloff = 3
        if self.selected > self.scroll_y + (self.height - 2) - scrolloff then
          self.scroll_y = self.selected - (self.height - 2) + scrolloff
        elseif self.selected < self.scroll_y + scrolloff then
          self.scroll_y = self.selected - scrolloff
        end
        self.scroll_y = math.max(1, math.min(self._height, self.scroll_y))
      end
      if self.scroll_y == old_y then
        local w = math.min(self.width - 2, self._width)
        if old_selected and self.scroll_y <= old_selected and old_selected <= self.scroll_y + self.height - 2 then
          self._pad:pnoutrefresh(old_selected - 1, self.scroll_x - 1, self.y + 1 + (old_selected - self.scroll_y), self.x + 1, self.y + 1 + (old_selected - self.scroll_y) + 1, self.x + w)
        end
        if self.selected and self.scroll_y <= self.selected and self.selected <= self.scroll_y + self.height - 2 then
          self._pad:pnoutrefresh(self.selected - 1, self.scroll_x - 1, self.y + 1 + (self.selected - self.scroll_y), self.x + 1, self.y + 1 + (self.selected - self.scroll_y) + 1, self.x + w)
        end
      else
        self.dirty = true
      end
      if self.on_select then
        self:on_select(self.selected)
      end
      return self.selected
    end,
    scroll = function(self, dy, dx)
      local old_y, old_x = self.scroll_y, self.scroll_x
      if self.selected ~= nil then
        self:select(self.selected + (dy or 0))
      else
        self.scroll_y = math.max(1, math.min(self._height - (self.height - 2 - 1), self.scroll_y + (dy or 0)))
      end
      self.scroll_x = math.max(1, math.min(self._width - (self.width - 2 - 1), self.scroll_x + (dx or 0)))
      if self.scroll_y ~= old_y or self.scroll_x ~= old_x then
        self.dirty = true
      end
    end,
    refresh = function(self, force)
      if force == nil then
        force = false
      end
      if not force and not self.dirty then
        return 
      end
      self._frame:border(C.ACS_VLINE, C.ACS_VLINE, C.ACS_HLINE, C.ACS_HLINE, C.ACS_ULCORNER, C.ACS_URCORNER, C.ACS_LLCORNER, C.ACS_LRCORNER)
      if self.label then
        self._frame:mvaddstr(0, math.floor((self.width - #self.label - 2) / 2), " " .. tostring(self.label) .. " ")
      end
      self._frame:refresh()
      local h, w = math.min(self.height - 2, self._height), math.min(self.width - 2, self._width)
      self._pad:pnoutrefresh(self.scroll_y - 1, self.scroll_x - 1, self.y + 1, self.x + 1, self.y + h, self.x + w)
      self.dirty = false
    end,
    keypress = function(self, c)
      local _exp_0 = c
      if C.KEY_DOWN == _exp_0 or C.KEY_SR == _exp_0 or ("j"):byte() == _exp_0 then
        return self:scroll(1, 0)
      elseif ('J'):byte() == _exp_0 then
        return self:scroll(10, 0)
      elseif C.KEY_UP == _exp_0 or C.KEY_SF == _exp_0 or ("k"):byte() == _exp_0 then
        return self:scroll(-1, 0)
      elseif ('K'):byte() == _exp_0 then
        return self:scroll(-10, 0)
      elseif C.KEY_RIGHT == _exp_0 or ("l"):byte() == _exp_0 then
        return self:scroll(0, 1)
      elseif ("L"):byte() == _exp_0 then
        return self:scroll(0, 10)
      elseif C.KEY_LEFT == _exp_0 or ("h"):byte() == _exp_0 then
        return self:scroll(0, -1)
      elseif ("H"):byte() == _exp_0 then
        return self:scroll(0, -10)
      end
    end,
    erase = function(self)
      self.dirty = true
      self._frame:erase()
      return self._frame:refresh()
    end,
    __gc = function(self)
      self._frame:close()
      return self._pad:close()
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function(self, label, y, x, height, width, ...)
      self.label, self.y, self.x = label, y, x
      self.scroll_y, self.scroll_x = 1, 1
      self.selected = nil
      self.columns = { }
      self.column_widths = { }
      self.active_frame = Color("yellow bold")
      self.inactive_frame = Color("blue dim")
      self.colors = { }
      for i = 1, select('#', ...) - 1, 2 do
        local col = select(i, ...)
        table.insert(self.columns, col)
        local w = 0
        for _index_0 = 1, #col do
          local chunk = col[_index_0]
          w = math.max(w, #chunk)
        end
        table.insert(self.column_widths, w)
        local color_fn = select(i + 1, ...) or (function(self, i)
          return Color()
        end)
        _assert(type(color_fn) == 'function', "Invalid color function type: " .. tostring(type(color_fn)))
        table.insert(self.colors, color_fn)
      end
      self:configure_size(height, width)
      self._frame = C.newwin(self.height, self.width, self.y, self.x)
      self._frame:immedok(true)
      self._pad = C.newpad(self._height, self._width)
      self._pad:scrollok(true)
      self:set_active(false)
      self.chstrs = { }
      for i = 1, #self.columns[1] do
        self.chstrs[i] = C.new_chstr(self._width)
        self:setup_chstr(i)
      end
      self.dirty = true
    end,
    __base = _base_0,
    __name = "Pad"
  }, {
    __index = _base_0,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  Pad = _class_0
end
local NumberedPad
do
  local _class_0
  local _parent_0 = Pad
  local _base_0 = { }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self, label, y, x, height, width, ...)
      self.label, self.y, self.x = label, y, x
      local col1 = select(1, ...)
      local fmt = "%" .. tostring(#tostring(#col1)) .. "d"
      local line_nums
      do
        local _accum_0 = { }
        local _len_0 = 1
        for i = 1, #col1 do
          _accum_0[_len_0] = fmt:format(i)
          _len_0 = _len_0 + 1
        end
        line_nums = _accum_0
      end
      local cols = {
        line_nums,
        (function(self, i)
          return i == self.selected and Color() or Color("yellow")
        end),
        ...
      }
      return _class_0.__parent.__init(self, self.label, self.y, self.x, height, width, unpack(cols))
    end,
    __base = _base_0,
    __name = "NumberedPad",
    __parent = _parent_0
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  NumberedPad = _class_0
end
local line_matcher = re.compile('lines<-{|(line "\n")* line|} line<-{[^\n]*}')
local expansions = { }
local KEY = { }
local VALUE = { }
local TOP_LOCATION = { }
local locations = { }
local Location
Location = function(old_loc, kind, key)
  if not (locations[old_loc]) then
    locations[old_loc] = { }
  end
  if not (locations[old_loc][kind]) then
    locations[old_loc][kind] = { }
  end
  if not (locations[old_loc][kind][key]) then
    locations[old_loc][kind][key] = { }
  end
  return locations[old_loc][kind][key]
end
local expand
expand = function(kind, key, location)
  expansions[Location(location, kind, key)] = true
end
local collapse
collapse = function(kind, key, location)
  expansions[Location(location, kind, key)] = nil
end
local is_key_expanded
is_key_expanded = function(location, key)
  return expansions[Location(location, KEY, key)]
end
local is_value_expanded
is_value_expanded = function(location, key)
  return expansions[Location(location, VALUE, key)]
end
local make_lines
make_lines = function(location, x, width)
  local type_colors = {
    string = Color('blue on black'),
    number = Color('magenta'),
    boolean = Color('yellow'),
    ["nil"] = Color('cyan'),
    table = Color('white bold'),
    ["function"] = Color('green'),
    userdata = Color('cyan bold'),
    thread = Color('blue')
  }
  setmetatable(type_colors, {
    __index = function()
      return Color('red bold')
    end
  })
  local _exp_0 = type(x)
  if 'string' == _exp_0 then
    local lines = { }
    local _list_0 = line_matcher:match(x)
    for _index_0 = 1, #_list_0 do
      local line = _list_0[_index_0]
      local wrapped = wrap_text(line, width - 1)
      for i, subline in ipairs(wrapped) do
        local _line = {
          location = location
        }
        if i > 1 then
          table.insert(_line, C.ACS_BULLET)
          table.insert(_line, Color('black bold altcharset'))
        end
        table.insert(_line, subline)
        table.insert(_line, Color('blue on black'))
        table.insert(lines, _line)
      end
    end
    return lines
  elseif 'table' == _exp_0 then
    local prepend
    prepend = function(line, ...)
      for i = 1, select('#', ...) do
        table.insert(line, i, (select(i, ...)))
      end
    end
    local lines = { }
    for k, v in pairs(x) do
      if is_key_expanded(location, k) and is_value_expanded(location, k) then
        table.insert(lines, {
          location = Location(location, KEY, k),
          'key',
          Color('green bold'),
          '/',
          Color(),
          'value',
          Color('blue bold'),
          ':',
          Color('white')
        })
        local key_lines = make_lines(Location(location, KEY, k), k, width - 1)
        for i, key_line in ipairs(key_lines) do
          for j = 2, #key_line, 2 do
            key_line[j] = toggle(key_line[j], C.A_REVERSE)
          end
          if i == 1 then
            prepend(key_line, C.ACS_DIAMOND, Color('green bold'), ' ', Color())
          else
            prepend(key_line, '  ', Color())
          end
          table.insert(lines, key_line)
        end
        local value_lines = make_lines(Location(location, VALUE, k), v, width - 2)
        for i, value_line in ipairs(value_lines) do
          if i == 1 then
            prepend(value_line, C.ACS_DIAMOND, Color('blue bold'), ' ', Color())
          else
            prepend(value_line, '  ', Color())
          end
          table.insert(lines, value_line)
        end
      elseif is_value_expanded(location, k) then
        local k_str = type(k) == 'string' and k:gsub('\n', '\\n') or repr(k, 2)
        if #k_str > width then
          k_str = k_str:sub(1, width - 3) .. '...'
        end
        table.insert(lines, {
          location = Location(location, KEY, k),
          k_str,
          toggle(type_colors[type(k)], C.A_REVERSE)
        })
        local v_lines = make_lines(Location(location, VALUE, k), v, width - 1)
        prepend(v_lines[1], C.ACS_LLCORNER, Color())
        for i = 2, #v_lines do
          prepend(v_lines[i], ' ', Color())
        end
        for _index_0 = 1, #v_lines do
          local v_line = v_lines[_index_0]
          table.insert(lines, v_line)
        end
      elseif is_key_expanded(location, k) then
        local k_lines = make_lines(Location(location, KEY, k), k, width - 1)
        for _index_0 = 1, #k_lines do
          local k_line = k_lines[_index_0]
          for i = 2, #k_line, 2 do
            k_line[i] = toggle(k_line[i], C.A_REVERSE)
          end
        end
        for i = 1, #k_lines - 1 do
          prepend(k_lines[i], ' ', Color())
        end
        prepend(k_lines[#k_lines - 1], C.ACS_ULCORNER, Color())
        for _index_0 = 1, #k_lines do
          local k_line = k_lines[_index_0]
          table.insert(lines, k_line)
        end
        local v_str = type(v) == 'string' and v:gsub('\n', '\\n') or repr(v, 2)
        if #v_str > width then
          v_str = v_str:sub(1, width - 3) .. '...'
        end
        table.insert(lines, {
          location = Location(location, VALUE, k),
          v_str,
          type_colors[type(v)]
        })
      else
        local k_space = math.floor((width - 3) / 3)
        local k_str = type(k) == 'string' and k:gsub('\n', '\\n') or repr(k, 2)
        if #k_str > k_space then
          k_str = k_str:sub(1, k_space - 3) .. '...'
        end
        local v_space = (width - 3) - #k_str
        local v_str = type(v) == 'string' and v:gsub('\n', '\\n') or repr(v, 2)
        if #v_str > v_space then
          v_str = v_str:sub(1, v_space - 3) .. '...'
        end
        table.insert(lines, {
          location = Location(location, VALUE, k),
          k_str,
          toggle(type_colors[type(k)], C.A_REVERSE),
          ' = ',
          Color(),
          v_str,
          type_colors[type(v)]
        })
      end
    end
    return lines
  else
    local str = repr(x, 2)
    if #str > width then
      str = str:sub(1, width - 3) .. '...'
    end
    return {
      {
        location = location,
        str,
        type_colors[type(x)]
      }
    }
  end
end
local DataViewer
do
  local _class_0
  local _parent_0 = Pad
  local _base_0 = {
    setup_chstr = function(self, i) end,
    configure_size = function(self, height, width)
      self.height, self.width = height, width
      self._height, self._width = #self.chstrs, self.width - 2
    end,
    select = function(self, i)
      if #self.chstrs == 0 then
        i = nil
      end
      if i == self.selected then
        return self.selected
      end
      local old_y, old_x = self.scroll_y, self.scroll_x
      if i ~= nil then
        i = math.max(1, math.min(#self.chstrs, i))
      end
      local old_selected
      old_selected, self.selected = self.selected, i
      if old_selected and self.chstrs[old_selected] then
        self.chstrs[old_selected]:set_str(0, ' ')
        self._pad:mvaddchstr(old_selected - 1, 0, self.chstrs[old_selected])
      end
      if self.selected then
        self.chstrs[self.selected]:set_ch(0, C.ACS_RARROW, Color('green bold'))
        self._pad:mvaddchstr(self.selected - 1, 0, self.chstrs[self.selected])
        local scrolloff = 3
        if self.selected > self.scroll_y + (self.height - 2) - scrolloff then
          self.scroll_y = self.selected - (self.height - 2) + scrolloff
        elseif self.selected < self.scroll_y + scrolloff then
          self.scroll_y = self.selected - scrolloff
        end
        self.scroll_y = math.max(1, math.min(self._height, self.scroll_y))
      end
      if self.scroll_y == old_y then
        local w = math.min(self.width - 2, self._width)
        if old_selected and self.scroll_y <= old_selected and old_selected <= self.scroll_y + self.height - 2 then
          self._pad:pnoutrefresh(old_selected - 1, self.scroll_x - 1, self.y + 1 + (old_selected - self.scroll_y), self.x + 1, self.y + 1 + (old_selected - self.scroll_y) + 1, self.x + w)
        end
        if self.selected and self.scroll_y <= self.selected and self.selected <= self.scroll_y + self.height - 2 then
          self._pad:pnoutrefresh(self.selected - 1, self.scroll_x - 1, self.y + 1 + (self.selected - self.scroll_y), self.x + 1, self.y + 1 + (self.selected - self.scroll_y) + 1, self.x + w)
        end
      else
        self.dirty = true
      end
      if self.on_select then
        self:on_select(self.selected)
      end
      return self.selected
    end,
    keypress = function(self, c)
      local _exp_0 = c
      if C.KEY_DOWN == _exp_0 or C.KEY_SR == _exp_0 or ("j"):byte() == _exp_0 then
        return self:scroll(1, 0)
      elseif ('J'):byte() == _exp_0 then
        return self:scroll(10, 0)
      elseif C.KEY_UP == _exp_0 or C.KEY_SF == _exp_0 or ("k"):byte() == _exp_0 then
        return self:scroll(-1, 0)
      elseif ('K'):byte() == _exp_0 then
        return self:scroll(-10, 0)
      elseif C.KEY_RIGHT == _exp_0 or ("l"):byte() == _exp_0 then
        expansions[self.chstr_locations[self.selected]] = true
        return self:full_refresh()
      elseif ("L"):byte() == _exp_0 then
        expansions[self.chstr_locations[self.selected]] = true
        return self:full_refresh()
      elseif C.KEY_LEFT == _exp_0 or ("h"):byte() == _exp_0 then
        expansions[self.chstr_locations[self.selected]] = nil
        return self:full_refresh()
      elseif ("H"):byte() == _exp_0 then
        expansions[self.chstr_locations[self.selected]] = nil
        return self:full_refresh()
      end
    end
  }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self, data, label, y, x, height, width)
      self.data, self.label, self.y, self.x = data, label, y, x
      self.scroll_y, self.scroll_x = 1, 1
      self.selected = nil
      self.active_frame = Color("yellow bold")
      self.inactive_frame = Color("blue dim")
      self.expansions = { }
      self.full_refresh = function()
        local old_location = self.selected and self.chstr_locations and self.chstr_locations[self.selected]
        self.chstrs, self.chstr_locations = { }, { }
        line_matcher = re.compile('lines<-{|(line "\n")* line|} line<-{[^\n]*}')
        local W = width - 3
        local lines = make_lines(TOP_LOCATION, self.data, W)
        for i, line in ipairs(lines) do
          local chstr = C.new_chstr(W)
          local offset = 1
          for j = 1, #line - 1, 2 do
            local chunk, attrs = line[j], line[j + 1]
            if type(chunk) == 'number' then
              chstr:set_ch(offset, chunk, attrs)
              offset = offset + 1
            else
              chstr:set_str(offset, chunk, attrs)
              offset = offset + #chunk
            end
          end
          if offset < W then
            chstr:set_str(offset, ' ', attrs, W - offset)
          end
          table.insert(self.chstrs, chstr)
          table.insert(self.chstr_locations, line.location)
        end
        self._height, self._width = #self.chstrs, self.width - 2
        self._pad:resize(self._height, self._width)
        for i, chstr in ipairs(self.chstrs) do
          self._pad:mvaddchstr(i - 1, 0, chstr)
        end
        self.dirty = true
        if old_location then
          for i, loc in ipairs(self.chstr_locations) do
            if loc == old_location then
              self:select(i)
              break
            end
          end
        end
      end
      self.height, self.width = height, width
      self._frame = C.newwin(self.height, self.width, self.y, self.x)
      self._frame:immedok(true)
      self._pad = C.newpad(self.height - 2, self.width - 2)
      self._pad:scrollok(true)
      self:set_active(false)
      self:full_refresh()
      return self:select(1)
    end,
    __base = _base_0,
    __name = "DataViewer",
    __parent = _parent_0
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  DataViewer = _class_0
end
local ok, to_lua = pcall(function()
  return require('moonscript.base').to_lua
end)
if not ok then
  to_lua = function()
    return nil
  end
end
local file_cache = setmetatable({ }, {
  __index = function(self, filename)
    local file = io.open(filename)
    if not file then
      return nil
    end
    local contents = file:read("*a")
    self[filename] = contents
    return contents
  end
})
local line_tables = setmetatable({ }, {
  __index = function(self, filename)
    local file = file_cache[filename]
    if not file then
      return nil
    end
    local line_table
    ok, line_table = to_lua(file)
    if ok then
      self[filename] = line_table
      return line_table
    end
  end
})
local err_hand
err_hand = function(err)
  C.endwin()
  print("Error in debugger.")
  print(debug.traceback(err, 2))
  return os.exit(2)
end
ldb = {
  run_debugger = function(err_msg)
    err_msg = err_msg or ''
    local stdscr = C.initscr()
    local SCREEN_H, SCREEN_W = stdscr:getmaxyx()
    C.cbreak()
    C.echo(false)
    C.nl(false)
    C.curs_set(0)
    C.start_color()
    C.use_default_colors()
    do
      stdscr:wbkgd(Color("yellow on red bold"))
      stdscr:clear()
      stdscr:refresh()
      local lines = wrap_text("ERROR!\n \n " .. err_msg .. "\n \npress any key...", math.floor(SCREEN_W / 2))
      local max_line = 0
      for _index_0 = 1, #lines do
        local line = lines[_index_0]
        max_line = math.max(max_line, #line)
      end
      for i, line in ipairs(lines) do
        if i == 1 or i == #lines then
          stdscr:mvaddstr(math.floor(SCREEN_H / 2 - #lines / 2) + i, math.floor((SCREEN_W - #line) / 2), line)
        else
          stdscr:mvaddstr(math.floor(SCREEN_H / 2 - #lines / 2) + i, math.floor((SCREEN_W - max_line) / 2), line)
        end
      end
      stdscr:refresh()
      C.doupdate()
      stdscr:getch()
    end
    stdscr:keypad()
    stdscr:wbkgd(Color())
    stdscr:clear()
    stdscr:refresh()
    local pads = { }
    do
      local err_msg_lines = wrap_text(err_msg, SCREEN_W - 4)
      for i, line in ipairs(err_msg_lines) do
        err_msg_lines[i] = (" "):rep(2) .. line
      end
      pads.err = Pad("Error Message", 0, 0, AUTO, SCREEN_W, err_msg_lines, function(self, i)
        return Color("red bold")
      end)
      pads.err._frame:attrset(Color("red"))
      pads.err:refresh()
    end
    local stack_locations = { }
    local err_lines = { }
    do
      local stack_names = { }
      local max_filename, max_fn_name = 0, 0
      local stack_min, stack_max = callstack_range()
      for i = stack_min, stack_max do
        local info = debug.getinfo(i)
        if not info then
          break
        end
        local fn_name = info.name or "<unnamed function>"
        table.insert(stack_names, fn_name)
        local line
        if info.short_src then
          local line_table = line_tables[info.short_src]
          if line_table then
            local char = line_table[info.currentline]
            local line_num = 1
            local file = file_cache[info.short_src]
            for _ in file:sub(1, char):gmatch("\n") do
              line_num = line_num + 1
            end
            line = tostring(info.short_src) .. ":" .. tostring(line_num)
          else
            line = info.short_src .. ":" .. info.currentline
          end
        else
          line = "???"
        end
        err_lines[line] = true
        table.insert(stack_locations, line)
        max_filename = math.max(max_filename, #line)
        max_fn_name = math.max(max_fn_name, #fn_name)
      end
      max_fn_name, max_filename = 0, 0
      for i = 1, #stack_names do
        max_fn_name = math.max(max_fn_name, #stack_names[i])
        max_filename = math.max(max_filename, #stack_locations[i])
      end
      local stack_h = math.max(#stack_names + 2, math.floor(2 / 3 * SCREEN_H))
      local stack_w = math.min(max_fn_name + 3 + max_filename, math.floor(1 / 3 * SCREEN_W))
      pads.stack = Pad("(C)allstack", pads.err.height, SCREEN_W - stack_w, stack_h, stack_w, stack_names, (function(self, i)
        return (i == self.selected) and Color("black on green") or Color("green bold")
      end), stack_locations, (function(self, i)
        return (i == self.selected) and Color("black on cyan") or Color("cyan bold")
      end))
    end
    local show_src
    show_src = function(filename, line_no)
      if pads.src then
        if pads.src.filename == filename then
          pads.src:select(line_no)
          pads.src.colors[2] = function(self, i)
            if i == line_no and i == self.selected then
              return Color("yellow on red bold")
            elseif i == line_no then
              return Color("yellow on red")
            elseif err_lines[tostring(filename) .. ":" .. tostring(i)] == true then
              return Color("red on black bold")
            elseif i == self.selected then
              return Color("reverse")
            else
              return Color()
            end
          end
          for line, _ in pairs(err_lines) do
            local _filename, i = line:match("([^:]*):(%d*).*")
            if _filename == filename and tonumber(i) then
              pads.src:setup_chstr(tonumber(i))
            end
          end
          pads.src:select(line_no)
          return 
        else
          pads.src:erase()
        end
      end
      local file = file_cache[filename]
      if file then
        local src_lines = { }
        for line in (file .. '\n'):gmatch("([^\n]*)\n") do
          table.insert(src_lines, line)
        end
        pads.src = NumberedPad("(S)ource Code", pads.err.height, 0, pads.stack.height, pads.stack.x, src_lines, function(self, i)
          if i == line_no and i == self.selected then
            return Color("yellow on red bold")
          elseif i == line_no then
            return Color("yellow on red")
          elseif err_lines[tostring(filename) .. ":" .. tostring(i)] == true then
            return Color("red on black bold")
          elseif i == self.selected then
            return Color("reverse")
          else
            return Color()
          end
        end)
        pads.src:select(line_no)
      else
        local lines = { }
        for i = 1, math.floor(pads.stack.height / 2) - 1 do
          table.insert(lines, "")
        end
        local s = "<no source code found>"
        s = (" "):rep(math.floor((pads.stack.x - 2 - #s) / 2)) .. s
        table.insert(lines, s)
        pads.src = Pad("(S)ource Code", pads.err.height, 0, pads.stack.height, pads.stack.x, lines, function()
          return Color("red")
        end)
      end
      pads.src.filename = filename
    end
    local stack_env
    local show_vars
    show_vars = function(stack_index)
      if pads.vars then
        pads.vars:erase()
      end
      if pads.values then
        pads.values:erase()
      end
      local callstack_min, _ = callstack_range()
      local var_names, values = { }, { }
      stack_env = setmetatable({ }, {
        __index = _G
      })
      for loc = 1, 999 do
        local name, value = debug.getlocal(callstack_min + stack_index - 1, loc)
        if name == nil then
          break
        end
        table.insert(var_names, tostring(name))
        table.insert(values, value)
        stack_env[name] = value
        _ = [[                if type(value) == 'function'
                    info = debug.getinfo(value, 'nS')
                    --values\add_line(("function: %s @ %s:%s")\format(info.name or '???', info.short_src, info.linedefined))
                    table.insert(values, repr(info))
                else
                    table.insert(values, repr(value))
                    ]]
      end
      local var_y = pads.stack.y + pads.stack.height
      local var_x = 0
      local height = SCREEN_H - (pads.err.height + pads.stack.height)
      pads.vars = Pad("(V)ars", var_y, var_x, height, AUTO, var_names, (function(self, i)
        return i == self.selected and Color('reverse') or Color()
      end))
      pads.vars.on_select = function(self, var_index)
        if var_index == nil then
          return 
        end
        local value_x = pads.vars.x + pads.vars.width
        local value_w = SCREEN_W - (value_x)
        local value = values[var_index]
        local type_str = type(value)
        pads.values = DataViewer(value, "(D)ata [" .. tostring(type_str) .. "]", var_y, value_x, pads.vars.height, value_w)
        collectgarbage()
        return collectgarbage()
      end
      return pads.vars:select(1)
    end
    pads.stack.on_select = function(self, stack_index)
      local filename, line_no = pads.stack.columns[2][stack_index]:match("([^:]*):(%d*).*")
      line_no = tonumber(line_no)
      show_src(filename, line_no)
      return show_vars(stack_index)
    end
    pads.stack:select(1)
    local selected_pad = nil
    local select_pad
    select_pad = function(pad)
      if selected_pad ~= pad then
        if selected_pad then
          selected_pad:set_active(false)
          selected_pad:refresh()
        end
        selected_pad = pad
        selected_pad:set_active(true)
        return selected_pad:refresh()
      end
    end
    select_pad(pads.src)
    while true do
      for _, p in pairs(pads) do
        p:refresh()
      end
      local s = " press 'q' to quit "
      stdscr:mvaddstr(math.floor(SCREEN_H - 1), math.floor((SCREEN_W - #s)), s)
      local c = stdscr:getch()
      local _exp_0 = c
      if (':'):byte() == _exp_0 or ('>'):byte() == _exp_0 or ('?'):byte() == _exp_0 then
        C.echo(true)
        local code = ''
        if c == ('?'):byte() then
          stdscr:mvaddstr(SCREEN_H - 1, 0, "? " .. (' '):rep(SCREEN_W - 1))
          stdscr:move(SCREEN_H - 1, 2)
          code = 'return ' .. stdscr:getstr()
        elseif c == (':'):byte() or c == ('>'):byte() then
          local numlines = 1
          stdscr:mvaddstr(SCREEN_H - 1, 0, "> " .. (' '):rep(SCREEN_W - 1))
          stdscr:move(SCREEN_H - 1, 2)
          while true do
            local line = stdscr:getstr()
            if line == '' then
              break
            end
            code = code .. (line .. '\n')
            numlines = numlines + 1
            stdscr:mvaddstr(SCREEN_H - numlines, 0, "> " .. ((' '):rep(SCREEN_W) .. '\n'):rep(numlines))
            stdscr:mvaddstr(SCREEN_H - numlines, 2, code)
            stdscr:mvaddstr(SCREEN_H - 1, 0, (' '):rep(SCREEN_W))
            stdscr:move(SCREEN_H - 1, 0)
          end
        end
        C.echo(false)
        local output = ""
        if not stack_env then
          stack_env = setmetatable({ }, {
            __index = _G
          })
        end
        stack_env.print = function(...)
          for i = 1, select('#', ...) do
            if i > 1 then
              output = output .. '\t'
            end
            output = output .. tostring(select(i, ...))
          end
          output = output .. "\n"
        end
        for _, p in pairs(pads) do
          p:refresh(true)
        end
        local run_fn
        run_fn, err_msg = load(code, 'user input', 't', stack_env)
        if not run_fn then
          stdscr:addstr(err_msg)
        else
          local ret = run_fn()
          if ret ~= nil then
            output = output .. ('= ' .. repr(ret) .. '\n')
          end
          local numlines = 0
          for nl in output:gmatch('\n') do
            numlines = numlines + 1
          end
          stdscr:mvaddstr(SCREEN_H - numlines, 0, output)
        end
      elseif ('o'):byte() == _exp_0 then
        local file = stack_locations[pads.stack.selected]
        local filename, line_no = file:match("([^:]*):(.*)")
        line_no = tostring(pads.src.selected)
        C.endwin()
        os.execute((os.getenv("EDITOR") or "nano") .. " +" .. line_no .. " " .. filename)
        stdscr = C.initscr()
        C.cbreak()
        C.echo(false)
        C.nl(false)
        C.curs_set(0)
        C.start_color()
        C.use_default_colors()
        stdscr:clear()
        stdscr:refresh()
        for _, pad in pairs(pads) do
          pad:refresh()
        end
      elseif C.KEY_RESIZE == _exp_0 then
        SCREEN_H, SCREEN_W = stdscr:getmaxyx()
        stdscr:clear()
        stdscr:refresh()
        for _, pad in pairs(pads) do
          pad:refresh(true)
        end
        C.doupdate()
      elseif ('q'):byte() == _exp_0 or ("Q"):byte() == _exp_0 then
        pads = { }
        C.endwin()
        return 
      elseif ('c'):byte() == _exp_0 then
        select_pad(pads.stack)
      elseif ('s'):byte() == _exp_0 then
        select_pad(pads.src)
      elseif ('v'):byte() == _exp_0 then
        select_pad(pads.vars)
      elseif ('d'):byte() == _exp_0 then
        select_pad(pads.values)
      else
        selected_pad:keypress(c)
      end
    end
    return C.endwin()
  end,
  guard = function(fn, ...)
    return xpcall(fn, (function(err_msg)
      return xpcall(ldb.run_debugger, err_hand, err_msg)
    end), ...)
  end,
  breakpoint = function()
    return xpcall(ldb.run_debugger, err_hand, "Breakpoint triggered!")
  end,
  hijack = function()
    error = function(err_msg)
      xpcall(ldb.run_debugger, err_hand, err_msg)
      print(debug.traceback(err_msg, 2))
      return os.exit(2)
    end
    assert = function(condition, err_msg)
      if not condition then
        err_msg = err_msg or 'Assertion failed!'
        xpcall(ldb.run_debugger, err_hand, err_msg)
        print(debug.traceback(err_msg, 2))
        os.exit(2)
      end
      return condition
    end
  end
}
return ldb
