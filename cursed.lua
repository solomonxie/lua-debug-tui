local C = require("curses")
local repr = require('repr')
local REGULAR, INVERTED, HIGHLIGHTED, RED, BLUE, SCREEN_H, SCREEN_W
local run_debugger, guard, stdscr, main_loop
local AUTO = -1
local log = io.open("output.log", "w")
local callstack_range
callstack_range = function()
  local min, max = 0, -1
  for i = 1, 999 do
    local info = debug.getinfo(i, 'f')
    if not info then
      min = i - 1
      break
    end
    if info.func == main_loop then
      min = i + 1
      break
    end
  end
  for i = min, 999 do
    local info = debug.getinfo(i, 'f')
    if not info or info.func == guard then
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
local alternating_colors = setmetatable({ }, {
  __index = function(self, i)
    if i % 2 == 0 then
      return INVERTED
    else
      return REGULAR
    end
  end
})
local Pad
do
  local _class_0
  local _base_0 = {
    select = function(self, i)
      if i == self.selected or #self.lines == 0 then
        return self.selected
      end
      if i ~= nil then
        i = math.max(1, math.min(#self.lines, i))
      end
      if self.selected then
        local j = self.selected
        self.chstrs[j]:set_str(0, self.lines[j], self.attrs[j])
        self.chstrs[j]:set_str(#self.lines[j], ' ', self.attrs[j], self.chstrs[j]:len() - #self.lines[j])
        self._pad:mvaddchstr(j - 1 + 1, 0 + 1, self.chstrs[j])
      end
      if i then
        assert(self.chstrs[i], "DIDN'T FIND CHSTR: " .. tostring(i) .. "/" .. tostring(#self.chstrs) .. " (" .. tostring(#self.lines) .. ")")
        self.chstrs[i]:set_str(0, self.lines[i], HIGHLIGHTED)
        self.chstrs[i]:set_str(#self.lines[i], ' ', HIGHLIGHTED, self.chstrs[i]:len() - #self.lines[i])
        self._pad:mvaddchstr(i - 1 + 1, 0 + 1, self.chstrs[i])
      end
      self.selected = i
      if self.selected then
        if self.offset + self.height - 1 < self.selected then
          self.offset = math.min(self.selected - (self.height - 1), #self.lines - self.height)
        elseif self.offset + 1 > self.selected then
          self.offset = self.selected - 1
        end
      end
      self:refresh()
      if self.on_select then
        self:on_select(self.selected)
      end
      return self.selected
    end,
    refresh = function(self)
      self._pad:border(C.ACS_VLINE, C.ACS_VLINE, C.ACS_HLINE, C.ACS_HLINE, C.ACS_ULCORNER, C.ACS_URCORNER, C.ACS_LLCORNER, C.ACS_LRCORNER)
      return self._pad:pnoutrefresh(self.offset, 0, self.y, self.x, self.y + self.height + 1, self.x + self.width)
    end,
    erase = function(self)
      self._pad:erase()
      return self._pad:pnoutrefresh(self.offset, 0, self.y, self.x, self.y + self.height, self.x + self.width)
    end,
    clear = function(self)
      self:erase()
      self.lines = { }
      self.chstrs = { }
      self:set_internal_size(2, 2)
      if self.resize_height then
        self:set_size(self._height, self.width)
      end
      if self.resize_width then
        self:set_size(self.height, self._width)
      end
      self.selected = nil
      self.offset = 0
      return self:refresh()
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function(self, y, x, height, width, lines, attrs, pad_attr)
      if attrs == nil then
        attrs = alternating_colors
      end
      if pad_attr == nil then
        pad_attr = 0
      end
      self.y, self.x, self.height, self.width, self.lines, self.attrs = y, x, height, width, lines, attrs
      self.offset = 0
      self.selected = nil
      self._height = #self.lines + 2
      self._width = self.width == AUTO and 2 or self.width
      local _list_0 = self.lines
      for _index_0 = 1, #_list_0 do
        local x = _list_0[_index_0]
        self._width = math.max(self._width, #x + 2)
      end
      if self.height == AUTO then
        self.height = self._height
      end
      if self.width == AUTO then
        self.width = self._width
      end
      self._pad = C.newpad(self._height, self._width)
      self._pad:scrollok(true)
      self._pad:attrset(pad_attr)
      self.chstrs = { }
      for i, line in ipairs(self.lines) do
        local attr = self.attrs[i]
        local chstr = C.new_chstr(self.width - 2)
        self.chstrs[i] = chstr
        chstr:set_str(0, line, attr)
        chstr:set_str(#line + 0, ' ', attr, chstr:len() - #line)
        self._pad:mvaddchstr(i - 1 + 1, 0 + 1, chstr)
      end
      return self:refresh()
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
local err_pad, stack_pad, var_names, var_values = nil, nil, nil, nil
main_loop = function(err_msg, stack_index, var_index, value_index)
  local stack_names = { }
  local stack_locations = { }
  local max_filename = 0
  local stack_min, stack_max = callstack_range()
  for i = stack_min, stack_max do
    local _continue_0 = false
    repeat
      local info = debug.getinfo(i)
      if not info then
        break
      end
      table.insert(stack_names, info.name or "<unnamed function>")
      if not info.short_src then
        _continue_0 = true
        break
      end
      local line_table = line_tables[info.short_src]
      local line
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
      table.insert(stack_locations, line)
      max_filename = math.max(max_filename, #line)
      _continue_0 = true
    until true
    if not _continue_0 then
      break
    end
  end
  local callstack = { }
  for i = 1, #stack_names do
    callstack[i] = stack_locations[i] .. (" "):rep(max_filename - #stack_locations[i]) .. " | " .. stack_names[i] .. " "
  end
  if not err_pad then
    local err_msg_lines = wrap_text(err_msg, SCREEN_W - 4)
    err_pad = Pad(0, 0, AUTO, SCREEN_W, err_msg_lines, setmetatable({ }, {
      __index = function()
        return RED
      end
    }), RED)
  end
  if not stack_pad then
    stack_pad = Pad(err_pad.height, 0, AUTO, SCREEN_W, callstack, nil, BLUE)
  end
  stack_index = stack_pad:select(stack_index)
  if var_names then
    var_names:erase()
  end
  if var_values then
    var_values:erase()
  end
  local callstack_min, _ = callstack_range()
  local _var_names, _var_values = { }, { }
  for loc = 1, 999 do
    local name, value = debug.getlocal(callstack_min + stack_index - 1, loc)
    if value == nil then
      break
    end
    table.insert(_var_names, tostring(name))
    if type(value) == 'function' then
      local info = debug.getinfo(value, 'nS')
      table.insert(_var_values, repr(info))
    else
      table.insert(_var_values, repr(value))
    end
  end
  local var_y = stack_pad.y + stack_pad.height
  local var_x = 0
  var_names = Pad(var_y, var_x, AUTO, AUTO, _var_names, nil, BLUE)
  if var_index and #_var_names > 0 then
    var_index = var_names:select(var_index)
  end
  local value_x = var_names.x + var_names.width
  local value_w = SCREEN_W - (value_x)
  if value_index then
    var_values = Pad(var_y, value_x, AUTO, value_w, wrap_text(_var_values[var_index], value_w - 2), nil, BLUE)
    value_index = var_values:select(value_index)
  else
    var_values = Pad(var_y, value_x, AUTO, value_w, _var_values, nil, BLUE)
  end
  while true do
    C.doupdate()
    local c = stdscr:getch()
    local _exp_0 = c
    if C.KEY_DOWN == _exp_0 or C.KEY_SF == _exp_0 or ("j"):byte() == _exp_0 then
      if value_index then
        value_index = value_index + 1
      elseif var_index then
        var_index = var_index + 1
      else
        stack_index = stack_index + 1
      end
      return main_loop(err_msg, stack_index, var_index, value_index)
    elseif C.KEY_UP == _exp_0 or C.KEY_SR == _exp_0 or ("k"):byte() == _exp_0 then
      if value_index then
        value_index = value_index - 1
      elseif var_index then
        var_index = var_index - 1
      else
        stack_index = stack_index - 1
      end
      return main_loop(err_msg, stack_index, var_index, value_index)
    elseif ('J'):byte() == _exp_0 then
      if value_index then
        value_index = value_index + 10
      elseif var_index then
        var_index = var_index + 10
      else
        stack_index = stack_index + 10
      end
      return main_loop(err_msg, stack_index, var_index, value_index)
    elseif ('K'):byte() == _exp_0 then
      if value_index then
        value_index = value_index - 10
      elseif var_index then
        var_index = var_index - 10
      else
        stack_index = stack_index - 10
      end
      return main_loop(err_msg, stack_index, var_index, value_index)
    elseif C.KEY_RIGHT == _exp_0 or ("l"):byte() == _exp_0 then
      if var_index == nil then
        var_index = 1
      elseif value_index == nil then
        value_index = 1
      end
      return main_loop(err_msg, stack_index, var_index, value_index)
    elseif C.KEY_LEFT == _exp_0 or ("h"):byte() == _exp_0 then
      if value_index then
        value_index = nil
      elseif var_index then
        var_index = nil
      end
      return main_loop(err_msg, stack_index, var_index, value_index)
    elseif ('o'):byte() == _exp_0 then
      local file = stack_locations[stack_pad.selected]
      local filename, line_no = file:match("([^:]*):(.*)")
      C.endwin()
      err_pad, stack_pad, var_names, var_values = nil, nil, nil, nil
      os.execute((os.getenv("EDITOR") or "nano") .. " +" .. line_no .. " " .. filename)
      local initial_index = stack_pad.selected
      return main_loop(err_msg, stack_pad.selected, var_index)
    elseif ('q'):byte() == _exp_0 or ("Q"):byte() == _exp_0 then
      break
    end
  end
  err_pad, stack_pad, var_names, var_values = nil, nil, nil, nil
  return C.endwin()
end
run_debugger = function(err_msg)
  stdscr = C.initscr()
  SCREEN_H, SCREEN_W = stdscr:getmaxyx()
  C.cbreak()
  C.echo(false)
  C.nl(false)
  C.curs_set(0)
  C.start_color()
  C.use_default_colors()
  local _
  _, REGULAR = C.init_pair(1, -1, -1), C.color_pair(1)
  _, INVERTED = C.init_pair(2, -1, C.COLOR_BLACK), C.color_pair(2)
  _, HIGHLIGHTED = C.init_pair(3, C.COLOR_BLACK, C.COLOR_YELLOW), C.color_pair(3)
  _, RED = C.init_pair(4, C.COLOR_RED, -1), C.color_pair(4) | C.A_BOLD
  _, BLUE = C.init_pair(5, C.COLOR_BLUE, -1), C.color_pair(5) | C.A_BOLD
  stdscr:clear()
  stdscr:refresh()
  return main_loop(err_msg, 1)
end
guard = function(fn, ...)
  local err_hand
  err_hand = function(err)
    C.endwin()
    print("Caught an error:")
    print(debug.traceback(err, 2))
    return os.exit(2)
  end
  return xpcall(fn, (function(err_msg)
    return xpcall(run_debugger, err_hand, err_msg)
  end), ...)
end
local breakpoint
breakpoint = function()
  local err_hand
  err_hand = function(err)
    C.endwin()
    print("Caught an error:")
    print(debug.traceback(err, 2))
    return os.exit(2)
  end
  return xpcall(run_debugger, err_hand, "Breakpoint triggered!")
end
return {
  guard = guard,
  breakpoint = breakpoint
}
