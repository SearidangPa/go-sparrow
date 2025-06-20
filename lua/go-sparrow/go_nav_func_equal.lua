local M = {}

local ignore_list = {
  -- === in test ===
  NoError = true,
  Error = true,
  Errorf = true,

  -- === in log ===
  Info = true,
  Infof = true,
  Warn = true,
  Debug = true,
  Fatal = true,
  Fatalf = true,
  WithFields = true,
  WithField = true,

  -- === in error handling ===
  Wrap = true,
  Wrapf = true,

  -- === go builtins ===
  len = true,
  make = true,
}

local cache = {
  buf_nr = nil,
  changedtick = nil,
  matches = nil,
}

local query_string = [[
;; Function calls in short variable declarations (e.g., result, err := func())
(short_var_declaration
  left: (expression_list)
  right: (expression_list
    (call_expression
      function: [
        (identifier) @func_name
        (selector_expression
          field: (field_identifier) @func_name)
      ])))

;; Function calls in assignment statements (e.g., result, err = func())
(assignment_statement
  left: (expression_list)
  right: (expression_list
    (call_expression
      function: [
        (identifier) @func_name
        (selector_expression
          field: (field_identifier) @func_name)
      ])))

;; Chained method calls in assignment statements (e.g., logEntry = logEntry.WithField(...))
(assignment_statement
  right: (expression_list
    (call_expression
      function: (selector_expression
        field: (field_identifier) @func_name))))

;; Function calls in if statement conditions (e.g., if !bytes.Equal(...))
(if_statement
  condition: (_
    (call_expression
      function: [
        (identifier) @func_name
        (selector_expression
          field: (field_identifier) @func_name)
      ])))

;; Function calls in expression statements (e.g., func())
(expression_statement
  (call_expression
    function: [
      (identifier) @func_name
      (selector_expression
        field: (field_identifier) @func_name)
    ]))

;; Function calls in go statements (e.g., go func())
(go_statement
  (call_expression
    function: [
      (identifier) @func_name
      (selector_expression
        field: (field_identifier) @func_name)
    ]))
]]

local function get_cached_matches()
  local buf_nr = vim.api.nvim_get_current_buf()
  local changedtick = vim.api.nvim_buf_get_changedtick(buf_nr)

  if cache.buf_nr == buf_nr and cache.changedtick == changedtick and cache.matches then
    return cache.matches
  end

  local _, query, root = require('go-sparrow.util_treesitter').get_parser_and_query(query_string)
  local matches = {}
  local top_line, bottom_line = require('go-sparrow.util_treesitter').get_visible_range()

  -- First get matches in visible range
  for id, node, _ in query:iter_captures(root, buf_nr, top_line, bottom_line) do
    local capture_name = query.captures[id]
    if capture_name == 'func_name' then
      local func_name = vim.treesitter.get_node_text(node, buf_nr)
      if not ignore_list[func_name] then
        local start_row, start_col = node:range()
        table.insert(matches, {
          node = node,
          row = start_row,
          col = start_col,
          name = func_name,
        })
      end
    end
  end

  -- If we need more matches, expand search
  if #matches < 10 then -- arbitrary threshold
    for id, node, _ in query:iter_captures(root, buf_nr, 0, -1) do
      local capture_name = query.captures[id]
      if capture_name == 'func_name' then
        local start_row, start_col = node:range()
        -- Skip if already in visible range
        if start_row < top_line or start_row > bottom_line then
          local func_name = vim.treesitter.get_node_text(node, buf_nr)
          if not ignore_list[func_name] then
            table.insert(matches, {
              node = node,
              row = start_row,
              col = start_col,
              name = func_name,
            })
          end
        end
      end
    end
  end

  table.sort(matches, function(a, b)
    if a.row == b.row then
      return a.col < b.col
    end
    return a.row < b.row
  end)

  cache.buf_nr = buf_nr
  cache.changedtick = changedtick
  cache.matches = matches

  return matches
end

local function find_prev_func_call_with_equal(row, col)
  local matches = get_cached_matches()
  assert(matches, 'No matches found')
  local previous_match = nil

  for _, match in ipairs(matches) do
    if match.row < row or (match.row == row and match.col < col) then
      previous_match = match
    else
      break
    end
  end

  return previous_match and previous_match.node or nil
end

local function find_next_func_call_with_equal(row, col)
  local matches = get_cached_matches()
  assert(matches, 'No matches found')

  for _, match in ipairs(matches) do
    if match.row > row or (match.row == row and match.col > col) then
      return match.node
    end
  end

  return nil
end

local function move_to_next_func_call()
  local count = vim.v.count
  if count == 0 then
    count = 1
  end
  for _ = 1, count do
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local current_row, current_col = cursor_pos[1] - 1, cursor_pos[2]
    local next_node = find_next_func_call_with_equal(current_row, current_col)

    if next_node then
      local start_row, start_col, _, _ = next_node:range()
      vim.api.nvim_win_set_cursor(0, { start_row + 1, start_col })
    end
  end
end

local function move_to_previous_func_call()
  local count = vim.v.count
  if count == 0 then
    count = 1
  end
  for _ = 1, count do
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local current_row, current_col = cursor_pos[1] - 1, cursor_pos[2]
    local previous_node = find_prev_func_call_with_equal(current_row, current_col)

    if previous_node then
      local start_row, start_col, _, _ = previous_node:range()
      vim.api.nvim_win_set_cursor(0, { start_row + 1, start_col })
    end
  end
end

function M.get_prev_func_call_with_equal()
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local current_row, current_col = cursor_pos[1] - 1, cursor_pos[2]
  local previous_node = find_prev_func_call_with_equal(current_row, current_col)
  if previous_node then
    local res = vim.treesitter.get_node_text(previous_node, 0)
    return res
  end
end

M.next_function_call = move_to_next_func_call
M.prev_function_call = move_to_previous_func_call

return M
