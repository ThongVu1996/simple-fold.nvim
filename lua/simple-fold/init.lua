local M = {}

-- --- DEFAULT CONFIGURATION ---
M.config = {
    icon = "⚡",
    suffix_text = "lines",
    large_file_cutoff = 1.5 * 1024 * 1024, -- 1.5MB
    peek_keymaps = {
        close = "q",
        jump = "<CR>",
    },
    icons = {
        error = " ",
        warn = " ",
        info = " ",
        hint = " ",
        return_symbol = "󰌆 ",
        preview = "🔍 ",
        fold_open = "",
        fold_close = "",
        fold = " ",
    }
}

local ns_id = vim.api.nvim_create_namespace("SimpleFold")

-- 1. FOLDTEXT RENDERING ENGINE
function M.render()
    local ok, res = pcall(M._render_logic)
    if not ok then
        local num_lines = vim.v.foldend - vim.v.foldstart + 1
        return { { num_lines .. " lines (" .. tostring(res) .. ")", "Error" } }
    end
    return res
end


-- Check if a hl group name has a fg color, using nvim_get_hl (link=false follows
-- ALL links and works for lazily-created TS groups that hlID() would miss).
local function hl_has_fg(name)
    local ok, a = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    return ok and a and (a.fg ~= nil or a.ctermfg ~= nil)
end

-- Resolve a treesitter capture name to a highlight group following Neovim's
-- own RIGHT-TO-LEFT fallback chain:
--   @tag.attribute.name -> @tag.attribute -> @tag  (trim rightmost segment)
local function resolve_ts_hl(cap)
    local name = cap:match('^@?(.+)$') or cap
    repeat
        local hl = '@' .. name
        if hl_has_fg(hl) then return hl end
        name = name:match('^(.+)%.[^.]+$')
    until not name
    return nil
end

-- Walk candidate list; follows TS fallback chain per candidate.
-- Also tries bare legacy group names (Comment, Special, etc.).
local function get_valid_hl(candidates)
    for _, cand in ipairs(candidates) do
        local found = resolve_ts_hl(cand)
        if found then return found end
        local bare = cand:match('^@(.+)$') or cand
        if hl_has_fg(bare) then return bare end
    end
    return nil
end


-- [DEBUG TOOL] Run :lua require('simple-fold').debug()
M.debug = function()
    local line = vim.fn.getline(vim.v.foldstart)
    if not line or line == "" then print("No line at foldstart"); return end
    print("--- SimpleFold Debug ---")
    print("Line: " .. line)
    
    for col = 0, math.min(50, #line - 1) do
        local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, vim.v.foldstart - 1, col)
        local result = "None"
        if ok and caps and #caps > 0 then
            local cands = {}
            for i = #caps, 1, -1 do table.insert(cands, "@" .. caps[i].capture) end
            local found = get_valid_hl(cands)
            result = found or ("No Color for: " .. caps[#caps].capture)
        end
        local char = line:sub(col+1, col+1)
        if char:match("%S") then
            print(string.format("[%d] '%s' -> %s", col, char, result))
        end
    end
end

function M._render_logic()
    local pos = vim.v.foldstart
    local end_pos = vim.v.foldend
    local num_lines = end_pos - pos + 1
    local line = vim.api.nvim_buf_get_lines(0, pos - 1, pos, false)[1]

    if not line then
        return { { "...", "Comment" } }
    end

    local text_parts = {}
    local prev_hl = nil
    local current_text = ""
    local open_cluster, close_cluster = "", ""
    local found_bracket = false
    local brace_hl = "Special"

    local win_width = vim.api.nvim_win_get_width(0)
    local max_col = math.min(#line, win_width - 30)

    -- Tag Detection Logic
    local is_tag = line:match("^%s*<")
    if is_tag then
        local tag_start = line:find("<") or 0
        local first_space = line:find(" ", tag_start)
        local tag_close = line:find(">", tag_start)
        local limit = max_col
        if first_space then limit = math.min(limit, first_space - 1) end
        if tag_close then limit = math.min(limit, tag_close - 1) end
        max_col = limit
    end

    -- Bracket Cluster Detection
    local _, last_bracket = line:find(".*[{(%[]%s*$")
    if not last_bracket then
        _, last_bracket = line:find(".*>%s*$")
    end

    if last_bracket then
        local cluster_start = last_bracket
        while cluster_start > 1 and line:sub(cluster_start - 1, cluster_start - 1):match("[{(%[%>]") do
            cluster_start = cluster_start - 1
        end
        max_col = math.min(max_col, cluster_start - 1)
    end

    -- End line matching
    local end_line_text = vim.api.nvim_buf_get_lines(0, end_pos - 1, end_pos, false)[1] or ""
    local function get_tag_match(line_text)
        if not line_text then return nil end
        local t = line_text:match("^%s*(.*)")
        if not t then return nil end
        return t:match("^(</[^>]+>)")
    end

    local tag_match = get_tag_match(end_line_text)
    if not tag_match then
        local next_line = vim.api.nvim_buf_get_lines(0, end_pos, end_pos + 1, false)[1]
        tag_match = get_tag_match(next_line)
    end

    if tag_match then
        found_bracket = true
        close_cluster = tag_match
        local tag_start_idx = string.find(end_line_text, tag_match, 1, true)
        if tag_start_idx then
            tag_start_idx = tag_start_idx - 1
            local check_col = tag_start_idx + math.min(2, #tag_match - 1)
            local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, end_pos - 1, check_col)
            if ok and caps and #caps > 0 then
                brace_hl = "@" .. caps[#caps].capture
            end
        end
    end

    local is_tag = line:match("^%s*<")
    local tag_hl = "Special"
    local tag_name_end = 0

    -- Use Treesitter to find the exact tag name boundary
    if is_tag then
        local tag_col = line:find("<") or 0
        local ok_node, node = pcall(vim.treesitter.get_node, { bufnr = 0, pos = { pos - 1, tag_col } })
        while ok_node and node and node:type() ~= "jsx_opening_element" and node:type() ~= "start_tag" do
            local p = node:parent()
            if not p or (p:start() ~= node:start()) then break end
            node = p
        end
        if ok_node and node then
            for child in node:iter_children() do
                local c_type = child:type()
                if c_type == "identifier" or c_type == "tag_name" or c_type:match("name") then
                    local _, _, _, e_col = child:range()
                    tag_name_end = e_col
                    -- Get tag highlight
                    local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, pos - 1, tag_col + 1)
                    if ok and caps and #caps > 0 then
                        local best = caps[#caps].capture
                        local prios = { "constructor", "type", "builtin", "tag" }
                        for _, p in ipairs(prios) do
                            for _, cap in ipairs(caps) do
                                if cap.capture:match(p) then best = cap.capture; goto found_tag_best end
                            end
                        end
                        ::found_tag_best::
                        tag_hl = "@" .. best
                        brace_hl = tag_hl
                    end
                    break
                end
            end
        end
    end

    local p_ok, parser = pcall(vim.treesitter.get_parser, 0)
    if p_ok and parser then parser:parse() end

    -- Syntax Highlighting for fold head
    for col = 0, math.min(max_col, #line) - 1 do
        local char = line:sub(col + 1, col + 1)
        local capture_name = "Normal"
        
        -- If we're inside the tag name ONLY, use the synchronized tag_hl
        if is_tag and col > 0 and col < tag_name_end and char:match("[%w]") then
            capture_name = tag_hl
        else
            local success, captures = pcall(vim.treesitter.get_captures_at_pos, 0, pos - 1, col)
            
            if success and captures and #captures > 0 then
                -- Build candidate list: most-specific capture first.
                -- get_valid_hl will follow the TS fallback chain inside each candidate.
                local cand_list = {}
                for i = #captures, 1, -1 do
                    table.insert(cand_list, captures[i].capture)
                end

                local found = get_valid_hl(cand_list)
                if found then
                    capture_name = found
                    goto found_color
                end

                -- Semantic fallback: map known capture categories to stable HL groups
                local best = captures[#captures].capture
                if best:match('attribute') or best:match('property') then
                    capture_name = resolve_ts_hl('@attribute') or '@attribute'
                elseif best:match('tag') then
                    capture_name = tag_hl
                else
                    capture_name = '@' .. best
                end
            else
                -- Treesitter gave nothing: try Vim legacy syntax (works for blade/php)
                local syn_id = vim.fn.synID(pos, col + 1, 1)
                if syn_id ~= 0 then
                    local final_syn = vim.fn.synIDtrans(syn_id)
                    if vim.fn.synIDattr(final_syn, 'fg', 'gui') ~= '' or
                       vim.fn.synIDattr(final_syn, 'fg', 'cterm') ~= '' then
                        local syn_name = vim.fn.synIDattr(syn_id, 'name')
                        if syn_name and syn_name ~= '' then
                            capture_name = syn_name
                        end
                    end
                end
            end
        end
        ::found_color::
        ::skip_prio::
        if capture_name == prev_hl then
            current_text = current_text .. char
        else
            if prev_hl then
                table.insert(text_parts, { current_text, prev_hl })
            end
            current_text, prev_hl = char, capture_name
        end
    end
    if current_text ~= "" then
        table.insert(text_parts, { current_text, prev_hl })
    end

    -- Close Tag logic
    local is_tag = false
    local tag_name = line:match("<([%w%-:]+)")
    if tag_name and line:match(">$") then
        close_cluster = "</" .. tag_name .. ">"
        is_tag, found_bracket = true, true
        open_cluster = "" -- Don't repeat the '>' if it's a tag
    end

    -- Open Bracket Cluster logic
    if not is_tag then
        local _, b_end = line:find(".*[{(%[%>]%s*$")
        if b_end then
            local chain_start = b_end
            while chain_start > 1 do
                local prev = line:sub(chain_start - 1, chain_start - 1)
                if prev:match("[{(%[%>]") then
                    chain_start = chain_start - 1
                else
                    break
                end
            end
            local count = 0
            for i = chain_start, b_end do
                if count >= 3 then break end
                local char_b = line:sub(i, i)
                if char_b:match("[{(%[%>]") then
                    open_cluster = open_cluster .. char_b
                    local c = (char_b == "{") and "}" or (char_b == "[" and "]" or (char_b == "(" and ")" or (char_b == "<" and ">" or "")))
                    close_cluster = close_cluster .. c
                    count = count + 1
                end
            end
            local reversed_close = ""
            for i = #close_cluster, 1, -1 do
                reversed_close = reversed_close .. close_cluster:sub(i, i)
            end
            close_cluster, found_bracket = reversed_close, true
            local ok_b, caps_b = pcall(vim.treesitter.get_captures_at_pos, 0, pos - 1, b_end - 1)
            if ok_b and caps_b and #caps_b > 0 and brace_hl == "Special" then
                brace_hl = "@" .. caps_b[#caps_b].capture
            end
        end
    end

    -- Jsx/Html Attribute support
    if tag_match then
        local tag_col = line:find("<") or 0
        local ok_node, node = pcall(vim.treesitter.get_node, { bufnr = 0, pos = { pos - 1, tag_col } })
        while ok_node and node and node:type() ~= "jsx_opening_element" and node:type() ~= "start_tag" do
            local p = node:parent()
            if not p or (p:start() ~= node:start()) then break end
            node = p
        end

        if ok_node and node then
            local attrs = {}
            for child in node:iter_children() do
                if child:type():match("attribute") then
                    table.insert(attrs, child)
                end
            end

            for i = 1, math.min(5, #attrs) do
                local attr_node = attrs[i]
                local a_start_row, a_start_col = attr_node:start()
                local a_end_row, a_end_col = attr_node:end_()
                table.insert(text_parts, { " ", "Normal" })
                for r = a_start_row, a_end_row do
                    local a_line = vim.api.nvim_buf_get_lines(0, r, r + 1, false)[1] or ""
                    local s_col = (r == a_start_row) and a_start_col or 0
                    local e_col = (r == a_end_row) and a_end_col or #a_line
                    local current_chunk, chunk_hl = "", nil
                    for c = s_col, e_col - 1 do
                        local a_char = a_line:sub(c + 1, c + 1)
                        local ok_c, a_caps = pcall(vim.treesitter.get_captures_at_pos, 0, r, c)
                        local a_hl = "@attribute"
                        if ok_c and a_caps and #a_caps > 0 then
                            -- Build candidate list and use the same fallback chain as main render
                            local cands = {}
                            for i2 = #a_caps, 1, -1 do
                                table.insert(cands, '@' .. a_caps[i2].capture)
                            end
                            local found_hl = get_valid_hl(cands)
                            if found_hl then
                                a_hl = found_hl
                            else
                                -- semantic fallback for attribute/property captures
                                local best_cap = a_caps[#a_caps].capture
                                if best_cap:match('attribute') or best_cap:match('property') then
                                    a_hl = resolve_ts_hl('@tag.attribute.name')
                                        or resolve_ts_hl('@attribute')
                                        or '@attribute'
                                elseif best_cap:match('string') then
                                    a_hl = resolve_ts_hl('@string') or 'String'
                                elseif best_cap:match('operator') or best_cap:match('punct') then
                                    a_hl = resolve_ts_hl('@operator') or 'Operator'
                                else
                                    a_hl = '@' .. best_cap
                                end
                            end
                        end
                        if a_hl == chunk_hl then
                            current_chunk = current_chunk .. a_char
                        else
                            if chunk_hl then table.insert(text_parts, { current_chunk, chunk_hl }) end
                            current_chunk, chunk_hl = a_char, a_hl
                        end
                    end
                    if current_chunk ~= "" then
                        table.insert(text_parts, { current_chunk, chunk_hl })
                    end
                end
            end
            if #attrs > 5 then
                table.insert(text_parts, { " ... ", "Comment" })
            end
        end
        open_cluster = line:match("/%s*>$") and "/>" or ">"
    elseif line:match("^%s*(.*)") then
        local trim_end = line:match("^%s*(.*)")
        local first_char = trim_end:sub(1, 1)
        local expected_open = (first_char == "}") and "{" or (first_char == "]") and "[" or (first_char == ")") and "(" or nil
        if expected_open then
            if not found_bracket or close_cluster:sub(1, 1) ~= first_char then
                open_cluster, close_cluster, found_bracket = expected_open, first_char, true
                local start_col = string.find(end_line_text, trim_end, 1, true)
                if start_col then
                    start_col = start_col - 1
                    local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, end_pos - 1, start_col)
                    if ok and caps and #caps > 0 then
                        brace_hl = "@" .. caps[#caps].capture
                    end
                end
            end
        end
    end

    -- Diagnostics and Final Construction
    if not found_bracket then
        -- Default to curly braces if no bracket found on first line (common for signatures)
        table.insert(text_parts, { " { ", brace_hl })
        table.insert(text_parts, { " ... ", "Comment" })
        table.insert(text_parts, { " }", brace_hl })
    else
        local prefix = (is_tag or tag_match or open_cluster:match("^[})%]%s]")) and "" or " "
        table.insert(text_parts, { prefix .. open_cluster, brace_hl })
        table.insert(text_parts, { " ... ", "Comment" })
        table.insert(text_parts, { close_cluster, brace_hl })

        local end_line_text_raw = vim.api.nvim_buf_get_lines(0, end_pos - 1, end_pos, false)[1] or ""
        local trim_end_raw = end_line_text_raw:match("^%s*(.*)")
        if trim_end_raw and vim.startswith(trim_end_raw, close_cluster) then
            local end_suffix = trim_end_raw:sub(#close_cluster + 1):match("^(.-)%s*$")
            if end_suffix and #end_suffix > 0 then
                if #end_suffix > 40 then end_suffix = end_suffix:sub(1, 40) .. "..." end
                local start_col = string.find(end_line_text_raw, trim_end_raw, 1, true)
                if start_col then
                    start_col = start_col - 1 + #close_cluster
                    local end_col = start_col + #end_suffix
                    local cur_hl, cur_text = nil, ""
                    for col = start_col, end_col - 1 do
                        local char_s, hl_s = end_line_text_raw:sub(col + 1, col + 1), "Normal"
                        local ok_s, caps_s = pcall(vim.treesitter.get_captures_at_pos, 0, end_pos - 1, col)
                        if ok_s and caps_s and #caps_s > 0 then
                            hl_s = "@" .. caps_s[#caps_s].capture
                        end
                        if hl_s == cur_hl then
                            cur_text = cur_text .. char_s
                        else
                            if cur_hl then table.insert(text_parts, { cur_text, cur_hl }) end
                            cur_text, cur_hl = char_s, hl_s
                        end
                    end
                    if cur_text ~= "" then table.insert(text_parts, { cur_text, cur_hl }) end
                else
                    table.insert(text_parts, { end_suffix, "Normal" })
                end
            end
        end
    end

    local all_diagnostics = vim.diagnostic.get(0)
    local counts = { [1] = 0, [2] = 0, [3] = 0, [4] = 0 }
    for _, d in ipairs(all_diagnostics) do
        if d.lnum and d.lnum >= pos - 1 and d.lnum <= end_pos - 1 then
            local sev = d.severity
            if sev and counts[sev] then counts[sev] = counts[sev] + 1 end
        end
    end
    local d_icons = { M.config.icons.error, M.config.icons.warn, M.config.icons.info, M.config.icons.hint }
    local d_hls = { "DiagnosticError", "DiagnosticWarn", "DiagnosticInfo", "DiagnosticHint" }
    for i = 1, 4 do
        if counts[i] > 0 then
            table.insert(text_parts, { " " .. (d_icons[i] or "") .. counts[i], d_hls[i] })
        end
    end

    local total = vim.api.nvim_buf_line_count(0)
    local pct = total > 0 and string.format("(%.1f%%)", (num_lines / total) * 100) or ""
    table.insert(text_parts, { string.format(" %s %d lines %s ", M.config.icon, num_lines, pct), "Special" })
    return text_parts
end

-- Detect if filetype relies purely on treesitter injection (e.g. blade.php)
-- In these cases, vim.treesitter.foldexpr() returns 0 for every line.
local function is_injection_only_ft()
    local ft = vim.bo.filetype
    -- Blade: With the new 0.12.0 parser, we can use Treesitter folding!
    return false
end

function M.foldexpr()
    if vim.b.simple_fold_large then return "0" end
    if is_injection_only_ft() then
        -- Blade / injection-only: treesitter can't drive folds, fall back to indent.
        -- Return the indent level as a fold depth (compatible with foldmethod=expr).
        local indent = vim.fn.indent(vim.v.lnum)
        local sw     = vim.bo.shiftwidth
        if sw == 0 then sw = vim.bo.tabstop end
        if sw == 0 then sw = 4 end
        return tostring(math.floor(indent / sw))
    end
    return vim.treesitter.foldexpr()
end

-- 2. PORTAL ARCHITECTURE (SAME BUFFER, VIEWPORT LOCK)
M.preview_win_id = nil
M.original_win_id = nil

-- Persistent search history for the mini-input (shared across peek sessions).
M._search_history = M._search_history or {}

-- Floating mini-input widget for Search/Cmdline inside the peek view.
-- 'history'     : optional table; ↑/↓ in Insert mode browse it.
-- 'protect_len' : when > 0, BS/Del/C-w/C-u cannot remove the first protect_len chars.
local function open_mini_input(title, prefill, on_confirm, on_cancel, history, protect_len)
    history     = history     or {}
    protect_len = protect_len or 0
    local input_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[input_buf].bufhidden = 'wipe'
    vim.bo[input_buf].buftype  = 'nofile'

    local w   = math.min(72, vim.o.columns - 8)
    local row = math.floor((vim.o.lines - 5) / 2)
    local col = math.floor((vim.o.columns - w) / 2)

    local input_win = vim.api.nvim_open_win(input_buf, true, {
        relative   = 'editor',
        row = row, col = col,
        width = w, height = 1,
        style  = 'minimal',
        border = 'rounded',
        title      = ' ' .. title .. ' ',
        title_pos  = 'center',
        zindex     = 250,
    })
    vim.wo[input_win].winhl          = 'Normal:NormalFloat,FloatBorder:FloatBorder'
    vim.wo[input_win].number         = false
    vim.wo[input_win].relativenumber = false
    vim.wo[input_win].cursorline     = false

    if prefill and prefill ~= '' then
        vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { prefill })
        vim.api.nvim_win_set_cursor(input_win, { 1, #prefill })
    end
    vim.cmd('startinsert!')

    local done      = false
    -- hist_idx points PAST the last entry = "live" position
    local hist_idx  = #history + 1
    local saved_live = prefill or ''

    local function set_line(text)
        vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { text })
        pcall(vim.api.nvim_win_set_cursor, input_win, { 1, #text })
    end

    local function finish(text)
        if done then return end
        done = true
        vim.cmd('stopinsert')
        -- persist to history (dedup, newest at end, cap 50)
        if text and text ~= '' and text ~= (prefill or '') then
            for i = #history, 1, -1 do
                if history[i] == text then table.remove(history, i) end
            end
            table.insert(history, text)
            if #history > 50 then table.remove(history, 1) end
        end
        pcall(vim.api.nvim_win_close, input_win, true)
        if text ~= nil then
            if on_confirm then vim.schedule(function() on_confirm(text) end) end
        else
            if on_cancel then vim.schedule(on_cancel) end
        end
    end

    local ko = { buffer = input_buf, nowait = true }

    -- Protected-prefix helpers: stop deletion from eating the range prefix.
    local function safe_bs()
        local line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ''
        local pos  = vim.api.nvim_win_get_cursor(input_win)[2]  -- 0-indexed byte pos
        if pos <= protect_len then return end  -- at or behind guard — block
        local dk = vim.api.nvim_replace_termcodes('<BS>', true, false, true)
        vim.api.nvim_feedkeys(dk, 'n', true)
    end
    local function safe_cw()  -- <C-w>: delete word backward
        local pos = vim.api.nvim_win_get_cursor(input_win)[2]
        if pos <= protect_len then return end
        local dk = vim.api.nvim_replace_termcodes('<C-w>', true, false, true)
        vim.api.nvim_feedkeys(dk, 'n', true)
    end
    local function safe_cu()  -- <C-u>: delete to start of line
        -- Replace text before cursor with protect prefix only.
        local line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ''
        local pos  = vim.api.nvim_win_get_cursor(input_win)[2]
        if pos <= protect_len then return end
        local new_line = line:sub(1, protect_len) .. line:sub(pos + 1)
        vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { new_line })
        pcall(vim.api.nvim_win_set_cursor, input_win, { 1, protect_len })
    end
    if protect_len > 0 then
        vim.keymap.set('i', '<BS>',  safe_bs,  ko)
        vim.keymap.set('i', '<Del>', safe_bs,  ko)
        vim.keymap.set('i', '<C-w>', safe_cw,  ko)
        vim.keymap.set('i', '<C-u>', safe_cu,  ko)
        -- <Home> jumps to the end of the protected prefix, not col 0.
        vim.keymap.set('i', '<Home>', function()
            pcall(vim.api.nvim_win_set_cursor, input_win, { 1, protect_len })
        end, ko)
    end

    -- ↑ = older history entry
    vim.keymap.set('i', '<Up>', function()
        if #history == 0 then return end
        if hist_idx == #history + 1 then
            saved_live = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ''
        end
        hist_idx = math.max(1, hist_idx - 1)
        set_line(history[hist_idx])
    end, ko)

    -- ↓ = newer / back to live
    vim.keymap.set('i', '<Down>', function()
        if hist_idx > #history then return end
        hist_idx = hist_idx + 1
        set_line(hist_idx <= #history and history[hist_idx] or saved_live)
    end, ko)

    vim.keymap.set({ 'i', 'n' }, '<CR>', function()
        local t = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ''
        finish(t)
    end, ko)
    vim.keymap.set({ 'i', 'n' }, '<Esc>', function() finish(nil) end, ko)
    vim.keymap.set({ 'i', 'n' }, '<C-c>', function() finish(nil) end, ko)

    vim.api.nvim_create_autocmd('WinClosed', {
        once    = true,
        pattern = tostring(input_win),
        callback = function() if not done then finish(nil) end end,
    })
end

function M.close_preview()
    if M.preview_win_id and vim.api.nvim_win_is_valid(M.preview_win_id) then
        pcall(vim.api.nvim_win_close, M.preview_win_id, true)
        M.preview_win_id = nil
    end
    if M.original_win_id and vim.api.nvim_win_is_valid(M.original_win_id) then
        pcall(vim.api.nvim_set_current_win, M.original_win_id)
        M.original_win_id = nil
    end
end

function M.toggle_peek()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    local cursor_pos = vim.api.nvim_win_get_cursor(win)

    if M.preview_win_id and vim.api.nvim_win_is_valid(M.preview_win_id) then
        M.close_preview()
        return
    end

    local f_start = vim.fn.foldclosed(cursor_pos[1])
    if f_start == -1 then
        local next_f = vim.fn.foldclosed(cursor_pos[1] + 1)
        if next_f ~= -1 then
            f_start = next_f
        else
            return
        end
    end

    local f_end      = vim.fn.foldclosedend(f_start)
    local fold_lines = f_end - f_start + 1
    -- EXACT FIT: window height = fold line count, capped at screen space.
    -- This prevents the portal from showing any content outside the fold.
    local max_h = math.max(1, vim.api.nvim_win_get_height(win) - 6)
    local h     = math.min(fold_lines, max_h)
    local w     = math.min(vim.api.nvim_win_get_width(win) - 10, 100)

    M.original_win_id = win
    M.preview_win_id  = vim.api.nvim_open_win(buf, true, {
        relative  = 'cursor',
        row = 1, col = 0,
        width = w, height = h,
        style  = 'minimal',
        border = 'rounded',
        title     = ' 🔍 Live Edit Portal ',
        title_pos = 'center',
    })

    local p_win = M.preview_win_id
    vim.w[p_win].is_peek          = true
    -- Allow inner folds; outer (boundary) fold is blocked via za keymap below.
    vim.wo[p_win].foldenable      = true
    vim.wo[p_win].foldmethod      = 'expr'
    vim.wo[p_win].foldexpr        = "v:lua.require('simple-fold').foldexpr()"
    vim.wo[p_win].foldtext        = "v:lua.require('simple-fold').render()"
    vim.wo[p_win].foldlevel       = 99   -- start with everything open
    vim.wo[p_win].winhl           = 'NormalFloat:Normal,FloatBorder:FloatBorder'
    vim.wo[p_win].number          = true
    vim.wo[p_win].relativenumber  = false  -- absolute for extmark readability
    vim.wo[p_win].signcolumn      = 'no'
    vim.wo[p_win].foldcolumn      = '0'
    vim.wo[p_win].scrolloff       = 0
    vim.wo[p_win].sidescrolloff   = 0

    -- Anchor the fold range in the shared buffer via extmarks so that
    -- edits (insert/delete lines) keep ls/le accurate automatically.
    local anchor_ns = vim.api.nvim_create_namespace('SimpleFoldAnchors')
    local start_ext = vim.api.nvim_buf_set_extmark(buf, anchor_ns, f_start - 1, 0, {})
    local end_ext   = vim.api.nvim_buf_set_extmark(buf, anchor_ns, f_end   - 1, 0, {})

    -- Scroll to fold start
    vim.api.nvim_win_set_cursor(p_win, { f_start, 0 })
    vim.api.nvim_win_call(p_win, function() vim.cmd('normal! zt') end)

    -- Returns current anchor bounds (1-indexed line numbers)
    local function get_bounds()
        local sp = vim.api.nvim_buf_get_extmark_by_id(buf, anchor_ns, start_ext, {})
        local ep = vim.api.nvim_buf_get_extmark_by_id(buf, anchor_ns, end_ext,   {})
        if not sp[1] or not ep[1] then return nil, nil end
        return sp[1] + 1, ep[1] + 1
    end

    local function jump_and_close()
        local pos = vim.api.nvim_win_get_cursor(p_win)
        M.close_preview()
        vim.schedule(function()
            pcall(vim.api.nvim_win_set_cursor, 0, pos)
            vim.cmd('normal! zvzz')
        end)
    end

    -- ---------------------------------------------------------------
    -- enforce_constraints: clamps cursor + resizes to visible screen lines
    -- (accounting for any inner folds the user has collapsed) + locks viewport.
    -- ---------------------------------------------------------------
    local function enforce_constraints()
        -- Skip in insert mode: completion plugins fire CursorMovedI and call
        -- screenpos() right after, giving E966 if we move the viewport.
        if vim.fn.mode():sub(1, 1) == 'i' then return end
        if not M.preview_win_id or not vim.api.nvim_win_is_valid(p_win) then return end
        if vim.api.nvim_get_current_win() ~= p_win then return end

        local ls, le = get_bounds()
        if not ls then return end

        -- 1. Clamp cursor to [ls, le]
        local c = vim.api.nvim_win_get_cursor(p_win)
        if c[1] < ls then
            c[1] = ls
            vim.api.nvim_win_set_cursor(p_win, c)
        elseif c[1] > le then
            c[1] = le
            vim.api.nvim_win_set_cursor(p_win, c)
        end

        local win_info = vim.fn.getwininfo(p_win)[1]
        if not win_info then return end
        local win_h   = win_info.height
        local fold_sz = le - ls + 1

        -- 2. Count how many buffer lines are hidden by inner folds so we can
        --    compute the actual screen height the content needs.
        local hidden = 0
        local lnum   = ls
        while lnum <= le do
            local fc = vim.fn.foldclosed(lnum)
            local fe = vim.fn.foldclosedend(lnum)
            if fc == lnum and fe > lnum then
                hidden = hidden + (fe - lnum)  -- fe-lnum lines folded (1 stays as foldtext)
                lnum = fe + 1
            else
                lnum = lnum + 1
            end
        end
        local screen_h = math.max(1, fold_sz - hidden)

        -- Resize down to actual visible screen lines (never larger than fold_sz)
        if screen_h < win_h then
            pcall(vim.api.nvim_win_set_config, p_win, { height = screen_h })
            win_h = screen_h
        end

        -- 3. Viewport lock (use screen_h for the "fits entirely" test)
        if screen_h <= win_h then
            if win_info.topline ~= ls then
                vim.fn.winrestview({ topline = ls })
            end
        else
            if win_info.topline < ls then
                vim.fn.winrestview({ topline = ls })
            elseif win_info.botline > le then
                vim.fn.winrestview({ topline = math.max(ls, le - win_h + 1) })
            end
        end
    end

    -- ---------------------------------------------------------------
    -- Scoped search: run vim.fn.search inside the peek window,
    -- constrained to [ls, le], with fold-wrapping on miss.
    -- ---------------------------------------------------------------
    local function do_fold_search(pattern, fwd)
        if not pattern or pattern == '' then return end
        vim.fn.setreg('/', pattern)
        -- Make sure we operate inside the peek window
        if vim.api.nvim_get_current_win() ~= p_win then
            if not vim.api.nvim_win_is_valid(p_win) then return end
            vim.api.nvim_set_current_win(p_win)
        end
        local ls, le = get_bounds()
        if not ls then return end
        local flags    = fwd and 'w' or 'bw'
        local stopline = fwd and le or ls
        local ok, result = pcall(vim.fn.search, pattern, flags, stopline)
        if not ok or result == 0 then
            local save = vim.api.nvim_win_get_cursor(p_win)
            vim.api.nvim_win_set_cursor(p_win, { fwd and ls or le, 0 })
            local ok2, result2 = pcall(vim.fn.search, pattern, flags, stopline)
            if not ok2 or result2 == 0 then
                vim.api.nvim_win_set_cursor(p_win, save)
                vim.api.nvim_echo(
                    { { '[SimpleFold] Not found in fold: ' .. pattern, 'WarningMsg' } },
                    false, {})
            end
        end
        -- Call enforce_constraints directly (not via vim.schedule) so we don't race
        -- with blink.cmp's CursorMovedI handler which calls screenpos() synchronously.
        enforce_constraints()
    end

    -- Track registered keymaps for cleanup on WinClosed
    local registered_keys = {}

    local pg = vim.api.nvim_create_augroup('SimpleFoldPeek', { clear = true })
    -- CursorMovedI intentionally omitted — blink.cmp / nvim-cmp register their own
    -- CursorMovedI handler and call screenpos() right after, which errors (E966)
    -- when our winrestview() runs in the same insert-mode tick.
    -- InsertLeave fires once we exit insert mode and corrects the viewport then.
    vim.api.nvim_create_autocmd({ 'CursorMoved', 'WinScrolled', 'InsertLeave' }, {
        group = pg, callback = enforce_constraints,
    })

    -- ---------------------------------------------------------------
    -- FIX E966 "Invalid line number": This is a known Neovim bug where
    -- vim.fn.screenpos() incorrectly throws E966 in a floating window if the line
    -- interacts complexly with folds (either cached layouts or background folds).
    -- Instead of crippling our fold features by disabling folds in insert mode,
    -- we inject a safe pcall wrapper directly into blink.cmp's coordinate resolver.
    -- ---------------------------------------------------------------
    pcall(function()
        local blink_win = package.loaded['blink.cmp.lib.window'] or require('blink.cmp.lib.window')
        if blink_win and type(blink_win.get_cursor_screen_position) == 'function' then
            if not blink_win._patched_by_simple_fold then
                local orig_fn = blink_win.get_cursor_screen_position
                
                -- Use varargs `...` to forward all arguments gracefully, future-proofing the signature
                blink_win.get_cursor_screen_position = function(...)
                    local ok, res = pcall(orig_fn, ...)
                    if ok then return res end
                    
                    -- Safe fallback to prevent crashing the editor
                    return {
                        distance_from_top = 0,
                        distance_from_bottom = vim.o.lines,
                        distance_from_left = 0,
                        distance_from_right = vim.o.columns,
                    }
                end
                blink_win._patched_by_simple_fold = true
            end
        end
    end)


    vim.api.nvim_create_autocmd('WinClosed', {
        group   = pg,
        pattern = tostring(p_win),
        callback = function()
            pcall(vim.api.nvim_buf_clear_namespace, buf, anchor_ns, 0, -1)
            pcall(vim.api.nvim_del_augroup_by_id, pg)
            for _, ki in ipairs(registered_keys) do
                pcall(vim.keymap.del, ki.mode, ki.key, { buffer = buf })
            end
            M.preview_win_id = nil
        end,
    })

    local kop = { buffer = buf, nowait = true, silent = true }
    local function smart_map(key, peek_fn, default_key)
        vim.keymap.set('n', key, function()
            if M.preview_win_id and vim.api.nvim_get_current_win() == M.preview_win_id then
                peek_fn()
            elseif default_key then
                local dk = vim.api.nvim_replace_termcodes(default_key, true, false, true)
                vim.api.nvim_feedkeys(dk, 'n', true)
            end
        end, kop)
        table.insert(registered_keys, { mode = 'n', key = key })
    end

    -- Core keymaps
    smart_map('<CR>', jump_and_close)
    vim.keymap.set('i', '<C-CR>', jump_and_close, kop)
    vim.keymap.set('i', '<S-CR>', jump_and_close, kop)
    smart_map('q',     M.close_preview)
    smart_map('<Esc>', M.close_preview)

    -- Movement (clamped to fold bounds)
    local function move(k)
        return function()
            local ls, le = get_bounds()
            if not ls then return end
            local curr  = vim.api.nvim_win_get_cursor(0)[1]
            local win_h = vim.api.nvim_win_get_height(0)
            if k == 'j' then
                if curr < le then vim.cmd('normal! j') end
            elseif k == 'k' then
                if curr > ls then vim.cmd('normal! k') end
            elseif k == '\x05' then
                if vim.fn.line('w$') < le then vim.cmd('normal! \x05') end
            elseif k == '\x19' then
                if vim.fn.line('w0') > ls then vim.cmd('normal! \x19') end
            elseif k == '\x04' then
                vim.api.nvim_win_set_cursor(0, { math.min(le, curr + math.floor(win_h / 2)), 0 })
            elseif k == '\x15' then
                vim.api.nvim_win_set_cursor(0, { math.max(ls, curr - math.floor(win_h / 2)), 0 })
            elseif k == '\x06' then
                vim.api.nvim_win_set_cursor(0, { math.min(le, curr + win_h), 0 })
            elseif k == '\x02' then
                vim.api.nvim_win_set_cursor(0, { math.max(ls, curr - win_h), 0 })
            end
        end
    end

    smart_map('j',     move('j'))
    smart_map('k',     move('k'))
    smart_map('<C-d>', move('\x04'))
    smart_map('<C-u>', move('\x15'))
    smart_map('<C-f>', move('\x06'))
    smart_map('<C-b>', move('\x02'))
    smart_map('<C-e>', move('\x05'))
    smart_map('<C-y>', move('\x19'))
    smart_map('gg', function()
        local ls = get_bounds()
        if ls then vim.api.nvim_win_set_cursor(0, { ls, 0 }) end
    end)
    smart_map('G', function()
        local _, le = get_bounds()
        if le then vim.api.nvim_win_set_cursor(0, { le, 0 }) end
    end)

    -- Boundary-line guard applied to ALL fold operator keys.
    -- Prevents folding the outermost peek boundary via any mechanism.
    local function za_guard(fallback_key)
        return function()
            local ls = get_bounds()
            if not ls then return end
            
            -- Pre-emptive check: block right away if standing exactly on the boundary
            local cur = vim.api.nvim_win_get_cursor(0)
            if cur[1] == ls and string.match(fallback_key, "^z[acCmoOMvVzfF]$") then
                vim.notify(
                    table.concat({
                        'The boundary line is the fold this portal is previewing.',
                        'Folding it would close the portal view.',
                        'Press q or <CR> to close, or use za on an inner block.',
                    }, ' '),
                    vim.log.levels.INFO,
                    { title = '🔍 Live Edit Portal — Fold Hint' }
                )
                return
            end

            -- Execute the normal fold command
            pcall(vim.cmd, 'normal! ' .. fallback_key)

            -- If the operation caused the outermost peek boundary to close
            -- (which happens if you use `za` on a line with no inner fold), revert it!
            if vim.fn.foldclosed(ls) ~= -1 then
                local save_cur = vim.api.nvim_win_get_cursor(0)
                -- move cursor to boundary and force it open
                vim.api.nvim_win_set_cursor(0, { ls, 0 })
                pcall(vim.cmd, 'normal! zo')
                -- restore cursor
                pcall(vim.api.nvim_win_set_cursor, 0, save_cur)
                
                vim.notify(
                    table.concat({
                        'Prevented closing the portal boundary view.',
                        'Use q or <CR> to close the portal.',
                    }, ' '),
                    vim.log.levels.INFO,
                    { title = '🔍 Live Edit Portal' }
                )
            end

            enforce_constraints()
        end
    end

    -- za : toggle fold
    smart_map('za', za_guard('za'))
    -- zc : close fold
    smart_map('zc', za_guard('zc'))
    -- zC : close all folds under cursor
    smart_map('zC', za_guard('zC'))
    -- zo : open fold (harmless on boundary, but guard for symmetry)
    smart_map('zo', za_guard('zo'))
    -- zm / zM : fold more / fold all  — guard catches case when cursor is at ls
    smart_map('zm', za_guard('zm'))
    smart_map('zM', za_guard('zM'))
    -- zr / zR : reduce folds / open all — safe, but guard for consistency
    smart_map('zr', za_guard('zr'))
    smart_map('zR', za_guard('zR'))
    -- zf / zF : create fold at cursor / N lines — block if at boundary
    smart_map('zf', za_guard('zf'))
    smart_map('zF', za_guard('zF'))
    -- zd / zD : delete fold — block at boundary
    smart_map('zd', za_guard('zd'))
    smart_map('zD', za_guard('zD'))

    -- n / N : repeat last search within fold bounds
    smart_map('n', function()
        local p = vim.fn.getreg('/')
        if not p or p == '' then return end
        -- Strip range constraints injected by previous / ? calls
        local clean = p:gsub('^\\%%>[0-9]+l\\%%<[0-9]+l', '')
        if clean ~= '' then do_fold_search(clean, true) end
    end)
    smart_map('N', function()
        local p = vim.fn.getreg('/')
        if not p or p == '' then return end
        local clean = p:gsub('^\\%%>[0-9]+l\\%%<[0-9]+l', '')
        if clean ~= '' then do_fold_search(clean, false) end
    end)

    -- / : floating Search UI (forward) with persistent history
    smart_map('/', function()
        local ret = p_win
        open_mini_input('  Search ↓  ↑/↓=history  Enter=go  Esc=cancel', '', function(pattern)
            if not vim.api.nvim_win_is_valid(ret) then return end
            vim.api.nvim_set_current_win(ret)
            do_fold_search(pattern, true)
        end, function()
            if vim.api.nvim_win_is_valid(ret) then vim.api.nvim_set_current_win(ret) end
        end, M._search_history)
    end, '/')

    -- ? : floating Search UI (backward) — shares search history with /
    smart_map('?', function()
        local ret = p_win
        open_mini_input('  Search ↑  ↑/↓=history  Enter=go  Esc=cancel', '', function(pattern)
            if not vim.api.nvim_win_is_valid(ret) then return end
            vim.api.nvim_set_current_win(ret)
            do_fold_search(pattern, false)
        end, function()
            if vim.api.nvim_win_is_valid(ret) then vim.api.nvim_set_current_win(ret) end
        end, M._search_history)
    end, '?')

    -- : : floating Cmdline UI — range prefix is protected (cannot be deleted)
    smart_map(':', function()
        local ls, le = get_bounds()
        if not ls then return end
        local ret     = p_win
        local prefill = ls .. ',' .. le .. ' '
        -- protect_len = #prefill so the range cannot be backspaced away
        open_mini_input(' ⌘ Cmd  range is locked  Enter=run  Esc=cancel', prefill, function(cmd_text)
            if not vim.api.nvim_win_is_valid(ret) then return end
            vim.api.nvim_set_current_win(ret)
            local cmd = (cmd_text or ''):match('^%s*(.*%S)')
            if cmd and cmd ~= '' then
                pcall(vim.cmd, cmd)
            end
        end, function()
            if vim.api.nvim_win_is_valid(ret) then vim.api.nvim_set_current_win(ret) end
        end, nil, #prefill)
    end, ':')
end

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    local function apply()
        local b = vim.api.nvim_get_current_buf()
        local w = vim.api.nvim_get_current_win()
        if not vim.api.nvim_buf_is_valid(b) or vim.w[w].is_peek then return end
        vim.defer_fn(function()
            if not vim.api.nvim_buf_is_valid(b) or not vim.api.nvim_win_is_valid(w) or vim.w[w].is_peek then return end
            local ft = vim.bo[b].filetype
            -- Blade and other injection-only filetypes: use indent-based fold method
            -- so fold still works even though TS injection trees can't drive foldexpr
            if ft == "blade" then
                vim.opt_local.foldtext = "v:lua.require('simple-fold').render()"
                vim.opt_local.foldmethod = "expr"
                vim.opt_local.foldexpr = "v:lua.vim.treesitter.foldexpr()"
            else
                vim.opt_local.foldtext = "v:lua.require('simple-fold').render()"
                vim.opt_local.foldmethod = "expr"
                vim.opt_local.foldexpr = "v:lua.require('simple-fold').foldexpr()"
            end
            vim.opt_local.foldenable, vim.opt_local.foldlevel = true, 99
            pcall(function()
                vim.opt_local.fillchars:append({
                    foldopen = M.config.icons.fold_open,
                    foldclose = M.config.icons.fold_close,
                    fold = " "
                })
            end)
        end, 50)
    end

    local ag = vim.api.nvim_create_augroup('SimpleFoldAuto', { clear = true })
    vim.api.nvim_create_autocmd(
        { 'FileType', 'BufReadPost', 'BufEnter', 'BufWinEnter', 'WinEnter' },
        { group = ag, callback = apply })
    apply()

    -- (Guards removed to allow user configuration to override defaults)

    local vg = vim.api.nvim_create_augroup("SimpleFoldView", { clear = true })
    vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWritePost" }, { group = vg, callback = function() pcall(vim.cmd.mkview) end })
    vim.api.nvim_create_autocmd("BufWinEnter", { group = vg, callback = function() pcall(vim.cmd.loadview) end })

    for i = 1, 9 do
        vim.keymap.set("n", "z" .. i, function() vim.opt_local.foldlevel = i end, { desc = "Set Foldlevel " .. i })
    end
    vim.keymap.set("n", "z0", function() vim.opt_local.foldlevel = 0 end, { desc = "Set Foldlevel 0" })
    vim.keymap.set("n", "za", function() pcall(vim.cmd, "normal! za") end, { silent = true })
    vim.keymap.set("n", "zp", M.toggle_peek, { silent = true })
end

return M
