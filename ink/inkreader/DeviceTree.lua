local DeviceTree = {}

local function is_space(ch)
  return ch ~= nil and ch:match("%s") ~= nil
end

local function is_structural(ch)
  return ch == "{" or ch == "}" or ch == ";" or ch == ":" or ch == "=" or ch == "<" or ch == ">" or ch == "," or ch == "[" or ch == "]" or ch == "&" or ch == '"'
end

local function tokenize(text)
  local tokens = {}
  local i = 1
  local len = #text

  local function push(kind, value, pos)
    tokens[#tokens + 1] = { kind = kind, value = value, pos = pos }
  end

  while i <= len do
    local ch = text:sub(i, i)

    if is_space(ch) then
      i = i + 1

    elseif text:sub(i, i + 1) == "//" then
      local nl = text:find("\n", i + 2, true)
      if not nl then
        break
      end
      i = nl + 1

    elseif text:sub(i, i + 1) == "/*" then
      local close = text:find("*/", i + 2, true)
      if not close then
        error("unterminated block comment")
      end
      i = close + 2

    elseif ch == '"' then
      local pos = i
      i = i + 1
      local parts = {}
      while i <= len do
        local current = text:sub(i, i)
        if current == "\\" then
          local escape = text:sub(i + 1, i + 1)
          local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\" }
          parts[#parts + 1] = map[escape] or escape
          i = i + 2
        elseif current == '"' then
          i = i + 1
          break
        else
          parts[#parts + 1] = current
          i = i + 1
        end
      end
      if i > len + 1 then
        error("unterminated string literal")
      end
      push("STRING", table.concat(parts), pos)

    elseif ch == "{" or ch == "}" or ch == ";" or ch == ":" or ch == "=" or ch == "<" or ch == ">" or ch == "," or ch == "[" or ch == "]" then
      local map = { ["{"] = "LBRACE", ["}"] = "RBRACE", [";"] = "SEMI", [":"] = "COLON", ["="] = "EQUAL", ["<"] = "LT", [">"] = "GT", [","] = "COMMA", ["["] = "LBRACKET", ["]"] = "RBRACKET" }
      push(map[ch], ch, i)
      i = i + 1

    elseif ch == "&" then
      push("AMP", ch, i)
      i = i + 1

    else
      local start = i
      while i <= len do
        local current = text:sub(i, i)
        if is_space(current) or is_structural(current) or text:sub(i, i + 1) == "//" or text:sub(i, i + 1) == "/*" then
          break
        end
        i = i + 1
      end
      local raw = text:sub(start, i - 1)
      if raw:match("^0x[%da-fA-F]+$") or raw:match("^[%+%-]?%d+$") then
        push("NUMBER", raw, start)
      else
        push("WORD", raw, start)
      end
    end
  end

  push("EOF", "", len + 1)
  return tokens
end

local Parser = {}
Parser.__index = Parser

function Parser.new(text)
  return setmetatable({ tokens = tokenize(text), index = 1 }, Parser)
end

function Parser:peek(offset)
  offset = offset or 0
  local index = self.index + offset
  if index > #self.tokens then
    index = #self.tokens
  end
  return self.tokens[index]
end

function Parser:advance()
  local token = self.tokens[self.index]
  self.index = self.index + 1
  return token
end

function Parser:expect(kind)
  local token = self:advance()
  if token.kind ~= kind then
    error(string.format("expected %s at %d, got %s", kind, token.pos, token.kind))
  end
  return token
end

function Parser:peek_kind(kind, offset)
  return self:peek(offset).kind == kind
end

function Parser:skip_directive()
  local token = self:peek()
  if token.kind ~= "WORD" or token.value == "/" or token.value:sub(1, 1) ~= "/" then
    return false
  end
  self:advance()
  while not self:peek_kind("SEMI") and not self:peek_kind("EOF") do
    self:advance()
  end
  if self:peek_kind("SEMI") then
    self:advance()
  end
  return true
end

function Parser:parse_labels()
  local labels = {}
  while self:peek_kind("WORD") and self:peek_kind("COLON", 1) do
    labels[#labels + 1] = self:advance().value
    self:expect("COLON")
  end
  return labels
end

function Parser:parse_node_name()
  local token = self:advance()
  if token.kind ~= "WORD" and token.kind ~= "SLASH" then
    error(string.format("expected node name at %d", token.pos))
  end
  return token.value
end

function Parser:looks_like_node()
  local token = self:peek()
  local next_token = self:peek(1)
  if (token.kind == "WORD" or token.kind == "SLASH") and next_token.kind == "LBRACE" then
    return true
  end
  if token.kind == "WORD" and next_token.kind == "COLON" then
    return true
  end
  return false
end

function Parser:is_root_node(container)
  local token = self:peek()
  return container.name == "/" and token.kind == "WORD" and token.value == "/" and container.label == nil
end

function Parser:parse_value()
  local token = self:peek()
  if token.kind == "STRING" then
    return self:advance().value
  elseif token.kind == "NUMBER" then
    local raw = self:advance().value
    return tonumber(raw)
  elseif token.kind == "AMP" then
    self:advance()
    return "&" .. self:expect("WORD").value
  elseif token.kind == "WORD" then
    return self:advance().value
  elseif token.kind == "LT" then
    return self:parse_angle_list()
  elseif token.kind == "LBRACKET" then
    return self:parse_byte_list()
  end
  error(string.format("unexpected token %s at %d", token.kind, token.pos))
end

function Parser:parse_angle_list()
  self:expect("LT")
  local values = {}
  while not self:peek_kind("GT") do
    if self:peek_kind("COMMA") then
      self:advance()
    elseif self:peek_kind("AMP") then
      self:advance()
      values[#values + 1] = "&" .. self:expect("WORD").value
    else
      local token = self:advance()
      if token.kind == "NUMBER" then
        values[#values + 1] = tonumber(token.value)
      elseif token.kind == "WORD" then
        values[#values + 1] = token.value
      else
        error(string.format("unexpected token %s in <...> at %d", token.kind, token.pos))
      end
    end
  end
  self:expect("GT")
  return values
end

function Parser:parse_byte_list()
  self:expect("LBRACKET")
  local values = {}
  while not self:peek_kind("RBRACKET") do
    local token = self:advance()
    if token.kind == "WORD" then
      values[#values + 1] = tonumber(token.value, 16)
    elseif token.kind == "NUMBER" then
      values[#values + 1] = tonumber(token.value)
    elseif token.kind == "COMMA" then
    else
      error(string.format("unexpected token %s in [..] at %d", token.kind, token.pos))
    end
  end
  self:expect("RBRACKET")
  return values
end

function Parser:parse_value_list()
  local values = { self:parse_value() }
  while self:peek_kind("COMMA") do
    self:advance()
    values[#values + 1] = self:parse_value()
  end
  if #values == 1 then
    return values[1]
  end
  return values
end

function Parser:parse_property(container)
  local name = self:expect("WORD").value
  if self:peek_kind("EQUAL") then
    self:advance()
    container.properties[name] = self:parse_value_list()
    self:expect("SEMI")
  else
    self:expect("SEMI")
    container.properties[name] = true
  end
end

function Parser:parse_entry(container)
  local labels = self:parse_labels()
  local token = self:peek()
  if token.kind == "EOF" or token.kind == "RBRACE" then
    return false
  end
  if self:looks_like_node() then
    if self:is_root_node(container) then
      self:parse_node_into(container, labels)
    else
      container.children[#container.children + 1] = self:parse_node(labels)
    end
  else
    self:parse_property(container)
  end
  return true
end

function Parser:parse_node(labels)
  local node = {
    name = self:parse_node_name(),
    label = labels[1],
    properties = {},
    children = {},
  }
  self:expect("LBRACE")
  self:parse_block(node, "RBRACE")
  if self:peek_kind("SEMI") then
    self:advance()
  end
  return node
end

function Parser:parse_node_into(container, labels)
  self:parse_node_name()
  if #labels > 0 and container.label == nil then
    container.label = labels[#labels]
  end
  self:expect("LBRACE")
  self:parse_block(container, "RBRACE")
  if self:peek_kind("SEMI") then
    self:advance()
  end
end

function Parser:parse_block(container, stop_kind)
  while not self:peek_kind(stop_kind) do
    if self:peek_kind("EOF") then
      if stop_kind == "EOF" then
        return
      end
      error("unexpected end of input")
    end
    if self:skip_directive() then
    elseif self:peek_kind("SEMI") then
      self:advance()
    else
      self:parse_entry(container)
    end
  end
  if stop_kind ~= "EOF" then
    self:expect(stop_kind)
  end
end

function Parser:parse()
  local root = { name = "/", properties = {}, children = {} }
  self:parse_block(root, "EOF")
  return root
end

function DeviceTree.parse(text)
  return Parser.new(text):parse()
end

function DeviceTree.load(path)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return DeviceTree.parse(text)
end

return DeviceTree
