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
        -- Return the actual Lua error message for debugging
        local num_lines = vim.v.foldend - vim.v.foldstart + 1
        return { { num_lines .. " lines (" .. tostring(res) .. ")", "Error" } }
    end
    return res
end

function M._render_logic()
    local pos = vim.v.foldstart
    local end_pos = vim.v.foldend
    local num_lines = end_pos - pos + 1
    local line = vim.api.nvim_buf_get_lines(0, pos - 1, pos, false)[1]
    
    if not line then return { { "...", "Comment" } } end
    
    local text_parts = {}
    local prev_hl = nil
    local current_text = ""
    
    local open_cluster = ""
    local close_cluster = ""
    local found_bracket = false
    local brace_hl = "Special" -- Fallback
    
    local win_width = vim.api.nvim_win_get_width(0)
    local max_col = math.min(#line, win_width - 30)
    
    -- If it's a tag, only render the tag name part in the first loop
    -- The Attribute Collector will handle all props (even those on line 1)
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

    -- Smart cut: cut at brackets OR tag ends at the end of the line
    local _, last_bracket = line:find(".*[{(%[]%s*$")
    if not last_bracket then
        _, last_bracket = line:find(".*>%s*$")
    end
    
    if last_bracket then
        local cluster_start = last_bracket
        while cluster_start > 1 and line:sub(cluster_start-1, cluster_start-1):match("[{(%[%>]") do
            cluster_start = cluster_start - 1
        end
        max_col = math.min(max_col, cluster_start - 1)
    end

    -- 2. Truth Test: Verify against the closing line of the fold!
    -- This definitively resolves PSR-12, complex React declarations, and HTML/JSX tags.
    local end_line_text = vim.api.nvim_buf_get_lines(0, end_pos - 1, end_pos, false)[1] or ""
    local trim_end = end_line_text:match("^%s*(.*)")

    local function get_tag_match(line_text)
        if not line_text then return nil end
        local t = line_text:match("^%s*(.*)")
        if not t then return nil end
        return t:match("^(</[^>]+>)")
    end

    local tag_match = get_tag_match(end_line_text)
    
    -- HTML/Blade enhancement: If no tag match on end_pos, peek at end_pos + 1
    if not tag_match then
        local next_line = vim.api.nvim_buf_get_lines(0, end_pos, end_pos + 1, false)[1]
        tag_match = get_tag_match(next_line)
    end
    
    if tag_match then
        found_bracket = true
        close_cluster = tag_match
        
        -- Attempt to steal highlight from the actual tag name (after the </)
        local tag_start_idx = string.find(end_line_text, tag_match, 1, true)
        if tag_start_idx then
            tag_start_idx = tag_start_idx - 1
            local check_col = tag_start_idx + math.min(2, #tag_match - 1)
            local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, end_pos - 1, check_col)
            if ok and caps and #caps > 0 then 
                local best_cap = caps[#caps].capture
                local priorities = { "constructor", "type", "builtin", "tag" }
                for _, p in ipairs(priorities) do
                    for _, cap in ipairs(caps) do
                        if cap.capture:match(p) then
                            best_cap = cap.capture
                            goto found_close_best
                        end
                    end
                end
                ::found_close_best::
                brace_hl = "@" .. best_cap
            end
        end
    end

    for col = 0, max_col - 1 do
        local char = line:sub(col + 1, col + 1)
        local capture_name = "Normal"
        local success, captures = pcall(vim.treesitter.get_captures_at_pos, 0, pos - 1, col)
        
        if success and captures and #captures > 0 then
            -- Prioritize more specific captures (Attributes, Components, Types, Variables)
            local best_cap = captures[#captures].capture
            local priorities = { "attribute", "property", "variable", "constructor", "type", "builtin" }
            
            -- If we already found a 'Truth' tag match and this is part of the tag, reuse brace_hl
            if tag_match and col > 0 and char:match("[%w]") then
                capture_name = brace_hl
                goto skip_prio
            end

            for _, p in ipairs(priorities) do
                for _, cap in ipairs(captures) do
                    if cap.capture:match(p) then
                        best_cap = cap.capture
                        goto found_best
                    end
                end
            end
            ::found_best::
            capture_name = "@" .. best_cap
        end
        ::skip_prio::
        if capture_name == prev_hl then
            current_text = current_text .. char
        else
            if prev_hl then table.insert(text_parts, { current_text, prev_hl }) end
            current_text = char
            prev_hl = capture_name
        end
    end
    if current_text ~= "" then table.insert(text_parts, { current_text, prev_hl }) end

    -- Smart Brace Detection (Type-First approach)

    -- 1. Identify the chain of opening brackets ending at the main fold point
    local _, b_end = line:find(".*[{(%[%>]")
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
            local char = line:sub(i, i)
            if char:match("[{(%[%>]") then
                open_cluster = open_cluster .. char
                local c = (char == "{") and "}" or (char == "[" and "]" or (char == "(" and ")" or (char == "<" and ">" or "")))
                close_cluster = close_cluster .. c
                count = count + 1
            end
        end

        local reversed_close = ""
        for i = #close_cluster, 1, -1 do
            reversed_close = reversed_close .. close_cluster:sub(i, i)
        end
        close_cluster = reversed_close

        found_bracket = true
        
        -- Highlight based on the very last bracket in the chain
        local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, pos - 1, b_end - 1)
        if ok and caps and #caps > 0 then brace_hl = "@" .. caps[#caps].capture end
    end

    -- 2. Truth Test: Verify against the closing line of the fold!
    -- This definitively resolves PSR-12, complex React declarations, and HTML/JSX tags.
    local end_line_text = vim.api.nvim_buf_get_lines(0, end_pos - 1, end_pos, false)[1] or ""
    local trim_end = end_line_text:match("^%s*(.*)")

    local function get_tag_match(line_text)
        if not line_text then return nil end
        local t = line_text:match("^%s*(.*)")
        if not t then return nil end
        return t:match("^(</[^>]+>)")
    end

    local tag_match = get_tag_match(end_line_text)
    
    -- HTML/Blade enhancement: If no tag match on end_pos, peek at end_pos + 1
    if not tag_match then
        local next_line = vim.api.nvim_buf_get_lines(0, end_pos, end_pos + 1, false)[1]
        tag_match = get_tag_match(next_line)
    end
    
    if tag_match then
        found_bracket = true
        close_cluster = tag_match
        
        -- Attempt to steal highlight from the actual tag name (after the </)
        local tag_start_idx = string.find(end_line_text, tag_match, 1, true)
        if tag_start_idx then
            tag_start_idx = tag_start_idx - 1
            local check_col = tag_start_idx + math.min(2, #tag_match - 1)
            local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, end_pos - 1, check_col)
            if ok and caps and #caps > 0 then 
                local best_cap = caps[#caps].capture
                local priorities = { "constructor", "type", "builtin", "tag" }
                for _, p in ipairs(priorities) do
                    for _, cap in ipairs(caps) do
                        if cap.capture:match(p) then
                            best_cap = cap.capture
                            goto found_close_best
                        end
                    end
                end
                ::found_close_best::
                brace_hl = "@" .. best_cap
            end
        end

        -- Robust Attribute Collector: Using Treesitter to "hunt" attributes across lines
        local tag_col = line:find("<") or 0
        local ok_node, node = pcall(vim.treesitter.get_node, { bufnr = 0, pos = { pos - 1, tag_col } })
        
        -- Navigate to the opening element node
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
            
            -- Render the first 5 attributes with GRANULAR highlight
            for i = 1, math.min(5, #attrs) do
                local attr_node = attrs[i]
                local a_start_row, a_start_col = attr_node:start()
                local a_end_row, a_end_col = attr_node:end_()
                
                table.insert(text_parts, { " ", "Normal" })
                
                -- Support multiline attribute nodes by iterating through their lines/cols
                for r = a_start_row, a_end_row do
                    local a_line = vim.api.nvim_buf_get_lines(0, r, r + 1, false)[1] or ""
                    local s_col = (r == a_start_row) and a_start_col or 0
                    local e_col = (r == a_end_row) and a_end_col or #a_line
                    
                    local current_chunk = ""
                    local chunk_hl = nil
                    
                    for c = s_col, e_col - 1 do
                        local a_char = a_line:sub(c + 1, c + 1)
                        local ok_c, a_caps = pcall(vim.treesitter.get_captures_at_pos, 0, r, c)
                        local a_hl = "@attribute"
                        if ok_c and a_caps and #a_caps > 0 then
                            a_hl = "@" .. a_caps[#a_caps].capture
                        end
                        
                        if a_hl == chunk_hl then
                            current_chunk = current_chunk .. a_char
                        else
                            if chunk_hl then table.insert(text_parts, { current_chunk, chunk_hl }) end
                            current_chunk = a_char
                            chunk_hl = a_hl
                        end
                    end
                    if current_chunk ~= "" then table.insert(text_parts, { current_chunk, chunk_hl }) end
                end
            end
            
            if #attrs > 5 then
                table.insert(text_parts, { " ... ", "Comment" })
            end
        end
        open_cluster = line:match("/%s*>$") and "/>" or ">" -- Complete the tag visually
    elseif trim_end then
        -- Existing Bracket Truth Test
        local first_char = trim_end:sub(1,1)
        local expected_open = (first_char == "}") and "{" or (first_char == "]") and "[" or (first_char == ")") and "(" or nil
        
        if expected_open then
            if not found_bracket or close_cluster:sub(1,1) ~= first_char then
                open_cluster = expected_open
                close_cluster = first_char
                found_bracket = true
                
                local start_col = string.find(end_line_text, trim_end, 1, true)
                if start_col then
                    start_col = start_col - 1
                    local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, end_pos - 1, start_col)
                    if ok and caps and #caps > 0 then brace_hl = "@" .. caps[#caps].capture end
                end
            end
        end
    end

    -- 3. Render the fold breadcrumb
    if not found_bracket then
        table.insert(text_parts, { " ... ", "Comment" })
    else
        -- Extract isolated dependency arrays for multiline hooks (e.g. useMemo, useCallback)
        local prev_deps_match = nil
        local prev_start_col = nil
        local prev_line = nil
        
        if close_cluster == ")" then
            local e_line = vim.api.nvim_buf_get_lines(0, end_pos - 1, end_pos, false)[1] or ""
            local e_trim = e_line:match("^%s*(.*)")
            if e_trim and vim.startswith(e_trim, ")") then
                local e_suf = e_trim:sub(2):match("^(.-)%s*$")
                -- Only look backwards if the closing line doesn't have significant content
                if e_suf == "" or e_suf == ";" or e_suf == "," then
                    local p_line = vim.api.nvim_buf_get_lines(0, end_pos - 2, end_pos - 1, false)[1] or ""
                    local p_trim = p_line:match("^%s*(.*)")
                    if p_trim then
                        -- Check if the preceding line is purely a dependency array e.g. `[deps],` or `, [deps]`
                        local d_match = p_trim:match("^(,?[%s]*%[.*%]),?$")
                        if d_match then
                            prev_deps_match = d_match
                            prev_line = p_line
                            prev_start_col = string.find(p_line, d_match, 1, true)
                        end
                    end
                end
            end
        end

        -- SMART PREFIX: Tags get no space, brackets/types get a leading space for readability
        local prefix = (is_tag or tag_match or open_cluster:match("^[})%]%s]")) and "" or " "
        table.insert(text_parts, { prefix .. open_cluster, brace_hl })
        table.insert(text_parts, { " ... ", "Comment" })
        
        -- Inject the extracted multiline React hook dependency array
        if prev_deps_match then
            if not prev_deps_match:match("^,") then
                table.insert(text_parts, { ", ", "@punctuation.delimiter" })
            end
            
            if prev_start_col then
                prev_start_col = prev_start_col - 1
                local e_col = prev_start_col + #prev_deps_match
                local cur_hl = nil
                local cur_text = ""
                for col = prev_start_col, e_col - 1 do
                    local char = prev_line:sub(col + 1, col + 1)
                    local hl = "Normal"
                    local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, end_pos - 2, col)
                    if ok and caps and #caps > 0 then hl = "@" .. caps[#caps].capture end
                    
                    if hl == cur_hl then cur_text = cur_text .. char
                    else
                        if cur_text ~= "" and cur_hl then table.insert(text_parts, { cur_text, cur_hl }) end
                        cur_text = char
                        cur_hl = hl
                    end
                end
                if cur_text ~= "" then table.insert(text_parts, { cur_text, cur_hl }) end
            else
                table.insert(text_parts, { prev_deps_match, "Normal" })
            end
        end

        table.insert(text_parts, { close_cluster, brace_hl })
        
        -- Smart trailing suffix extraction (e.g. for React's }, [dependencies]) matches same line
        local end_line_text = vim.api.nvim_buf_get_lines(0, end_pos - 1, end_pos, false)[1] or ""
        local trim_end = end_line_text:match("^%s*(.*)")
        if trim_end and vim.startswith(trim_end, close_cluster) then
            local end_suffix = trim_end:sub(#close_cluster + 1)
            end_suffix = end_suffix:match("^(.-)%s*$") -- remove trailing whitespace
            
            if end_suffix and #end_suffix > 0 then
                if #end_suffix > 40 then
                    end_suffix = end_suffix:sub(1, 40) .. "..."
                end
                
                -- Syntax highlight the suffix flawlessly using treesitter
                local start_col = string.find(end_line_text, trim_end, 1, true)
                if start_col then
                    start_col = start_col - 1 + #close_cluster
                    local end_col = start_col + #end_suffix
                    local cur_hl = nil
                    local cur_text = ""
                    for col = start_col, end_col - 1 do
                        local char = end_line_text:sub(col + 1, col + 1)
                        local hl = "Normal"
                        local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, end_pos - 1, col)
                        if ok and caps and #caps > 0 then
                            hl = "@" .. caps[#caps].capture
                        end
                        if hl == cur_hl then
                            cur_text = cur_text .. char
                        else
                            if cur_hl then table.insert(text_parts, { cur_text, cur_hl }) end
                            cur_text = char
                            cur_hl = hl
                        end
                    end
                    if cur_text ~= "" then table.insert(text_parts, { cur_text, cur_hl }) end
                else
                    table.insert(text_parts, { end_suffix, "Normal" })
                end
            end
        end
    end

    -- 3. LSP Diagnostics Dashboard
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

    -- (Return preview purposefully removed for UI minimalism)

    local total = vim.api.nvim_buf_line_count(0)
    local pct = total > 0 and string.format("(%.1f%%)", (num_lines / total) * 100) or ""
    local suffix = string.format(" %s %d lines %s ", M.config.icon, num_lines, pct)
    table.insert(text_parts, { suffix, "Special" })
    
    return text_parts
end

-- Custom fold expression using Treesitter
function M.foldexpr()
    if vim.b.simple_fold_large then return "0" end
    return vim.treesitter.foldexpr()
end

-- 2. PEEK FOLD ENGINE (LIVE EDIT SUPPORT)
M.preview_win_id = nil
M.original_win_id = nil
local peek_group = vim.api.nvim_create_augroup("SimpleFoldPeek", { clear = true })

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
    if M.preview_win_id and vim.api.nvim_win_is_valid(M.preview_win_id) then
        M.close_preview()
        return
    end

    local winid = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local cur_line = cursor[1]
    local f_start = vim.fn.foldclosed(cur_line)
    
    -- Smart Peek: If no fold at cursor, check the next line (for PSR-12/PHP)
    if f_start == -1 then
        local next_f_start = vim.fn.foldclosed(cur_line + 1)
        if next_f_start ~= -1 then
            f_start = next_f_start
        else
            return
        end
    end
    
    local f_end = vim.fn.foldclosedend(f_start)
    M.original_win_id = winid
    local original_buf = vim.api.nvim_get_current_buf()
    local ft = vim.bo[original_buf].filetype

    local lines = vim.api.nvim_buf_get_lines(original_buf, f_start - 1, f_end, false)
    
    local preview_buf = vim.api.nvim_create_buf(false, true)
    
    local old_undolevels = vim.api.nvim_get_option_value("undolevels", { scope = "global" })
    vim.bo[preview_buf].undolevels = -1
    
    local title = lines[1] or ""
    title = vim.trim(title):sub(1, 40)

    local injected_php = false
    if ft == "php" and #lines > 0 then
        local has_tag = false
        for _, line in ipairs(lines) do
            if line:find("<%?php") or line:find("<%?=") then
                has_tag = true
                break
            end
        end
        if not has_tag then
            lines[1] = "<?php " .. lines[1]
            injected_php = true
        end
    end

    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
    
    vim.bo[preview_buf].undolevels = old_undolevels
    vim.bo[preview_buf].modifiable = true

    vim.bo[preview_buf].filetype = ft

    local w = math.min(vim.api.nvim_win_get_width(0) - 10, 100)
    local h = math.min(#lines, vim.api.nvim_win_get_height(0) - 5)

    M.preview_win_id = vim.api.nvim_open_win(preview_buf, true, {
        relative = "cursor", row = 1, col = 1,
        width = w, height = h,
        style = "minimal", border = "rounded",
        title = " " .. M.config.icons.preview .. title .. " (Live Edit) ",
        title_pos = "center",
    })

    -- Finalize settings with a schedule to ensure they stick
    vim.schedule(function()
        if not vim.api.nvim_win_is_valid(M.preview_win_id) then return end
        
        vim.wo[M.preview_win_id].number = true
        vim.wo[M.preview_win_id].relativenumber = true
        vim.wo[M.preview_win_id].foldenable = true
        vim.wo[M.preview_win_id].foldlevel = 99
        
        if injected_php then
            vim.wo[M.preview_win_id].conceallevel = 3
            vim.wo[M.preview_win_id].concealcursor = "nvic"
            -- Absolute conceal for the PHP tag at the start of line 1
            vim.fn.matchadd("Conceal", [[^<?php\s*]], 11, -1, { window = M.preview_win_id, conceal = "" })
        end
        
        -- Safe 'za' mapping: prevent folding the main block but allow inner ones
        vim.keymap.set("n", "za", function()
            local line = vim.fn.line(".")
            local level = vim.fn.foldlevel(line)
            if level == 1 then
                vim.cmd("normal! zo") -- Always keep level 1 open
            else
                vim.cmd("normal! za") -- Toggle others
            end
        end, { buffer = preview_buf, silent = true, nowait = true })

        -- Open all folds in preview so the 'main' thing isn't folded
        vim.api.nvim_win_call(M.preview_win_id, function()
            vim.cmd("normal! zR")
        end)
    end)

    -- --- DIAGNOSTIC MIRRORING LOGIC ---
    local mirror_ns = vim.api.nvim_create_namespace("SimpleFoldMirror")
    
    local function update_preview_diagnostics()
        if not vim.api.nvim_buf_is_valid(preview_buf) or not vim.api.nvim_buf_is_valid(original_buf) then return end
        
        local all_diagnostics = vim.diagnostic.get(original_buf)
        local mirrored = {}
        
        for _, d in ipairs(all_diagnostics) do
            -- Only mirror diagnostics that fall within the current fold range
            if d.lnum >= f_start - 1 and d.lnum < f_end then
                local m = vim.deepcopy(d)
                local offset = f_start - 1
                m.lnum = d.lnum - offset
                m.end_lnum = (d.end_lnum or d.lnum) - offset
                m.bufnr = preview_buf
                table.insert(mirrored, m)
            end
        end
        
        -- Set mirrored diagnostics in its own namespace
        vim.diagnostic.set(mirror_ns, preview_buf, mirrored)
        
        -- Set mirrored diagnostics in its own namespace for reference, but don't draw extmarks
        vim.diagnostic.set(mirror_ns, preview_buf, mirrored)
    end

    local function sync_back()
        if not vim.api.nvim_buf_is_valid(preview_buf) or not vim.api.nvim_buf_is_valid(original_buf) then return end
        local new_lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
        
        if #new_lines == 0 then return end
        
        if injected_php then
            new_lines[1] = new_lines[1]:gsub("^<%?php%s?", "")
        end
        
        vim.api.nvim_buf_set_lines(original_buf, f_start - 1, f_end, false, new_lines)
        f_end = f_start + #new_lines - 1
        
        -- After syncing back, the original buffer has the context to re-calculate diagnostics accurately
        vim.schedule(update_preview_diagnostics)
    end
    
    -- Block standard LSP from attaching to the preview buffer (prevents "context-less" errors)
    vim.api.nvim_create_autocmd("LspAttach", {
        group = peek_group,
        buffer = preview_buf,
        callback = function(args)
            vim.schedule(function()
                pcall(vim.lsp.buf_detach_client, args.buf, args.data.client_id)
            end)
        end
    })

    -- Listen for diagnostic updates on the original buffer to mirror them live
    vim.api.nvim_create_autocmd("DiagnosticChanged", {
        group = peek_group,
        callback = function(args)
            if args.data.buf == original_buf then
                update_preview_diagnostics()
            end
        end
    })

    -- Initial diagnostic mirror
    vim.schedule(update_preview_diagnostics)

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = peek_group, buffer = preview_buf,
        callback = sync_back,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        group = peek_group, pattern = tostring(M.preview_win_id),
        callback = function()
            if vim.api.nvim_buf_is_valid(preview_buf) then
                vim.api.nvim_buf_delete(preview_buf, { force = true })
            end
            M.preview_win_id = nil
        end,
    })

    local kopts = { buffer = preview_buf, silent = true }
    vim.keymap.set("n", M.config.peek_keymaps.close, function() M.close_preview() end, kopts)
    vim.keymap.set("n", M.config.peek_keymaps.jump, function()
        local c = vim.api.nvim_win_get_cursor(M.preview_win_id)
        local target_line = f_start + c[1] - 1
        M.close_preview()
        vim.cmd("normal! zO")
        pcall(vim.api.nvim_win_set_cursor, 0, { target_line, c[2] })
        vim.cmd("normal! zz")
    end, kopts)

    vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
        group = peek_group, buffer = preview_buf,
        callback = function()
            vim.schedule(function()
                if M.preview_win_id and vim.api.nvim_get_current_win() ~= M.preview_win_id then
                    M.close_preview()
                end
            end)
        end,
    })
end

-- --- SMART TOGGLE FOR PHP/PSR-12 ---
function M.smart_toggle()
    -- Extremely simple toggle to restore functionality
    pcall(function() vim.cmd("normal! za") end)
end

function M.foldexpr()
    return vim.treesitter.foldexpr()
end


-- 4. PERSISTENCE (SAVE/LOAD FOLDS)
local view_group = vim.api.nvim_create_augroup("SimpleFoldView", { clear = true })
vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWritePost" }, {
    group = view_group,
    pattern = "*",
    callback = function()
        if vim.bo.filetype ~= "" and vim.bo.buftype == "" then
            vim.cmd("silent! mkview")
        end
    end,
})

vim.api.nvim_create_autocmd("BufWinEnter", {
    group = view_group,
    pattern = "*",
    callback = function()
        if vim.bo.filetype ~= "" and vim.bo.buftype == "" then
            vim.cmd("silent! loadview")
        end
    end,
})

-- 3. SETUP & INTEGRATION
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    
    vim.api.nvim_set_hl(0, "Folded", { bg = "NONE", italic = false })

    local function apply_fold_settings()
        local buf = vim.api.nvim_get_current_buf()
        if not vim.api.nvim_buf_is_valid(buf) then return end

        vim.defer_fn(function()
            if not vim.api.nvim_buf_is_valid(buf) then return end
            
            local ft = vim.bo[buf].filetype
            local ext = vim.fn.expand("%:e")

            if not vim.b[buf].simple_fold_large then
                local ok, stats = pcall(vim.loop.fs_stat, vim.api.nvim_buf_get_name(buf))
                if ok and stats and stats.size > M.config.large_file_cutoff then
                    vim.b[buf].simple_fold_large = true
                end
            end

            -- 1. CLASSIFY FILE & FORCE VISUALS
            vim.api.nvim_set_option_value("foldtext", "v:lua.require('simple-fold').render()", { scope = "local" })
            
            -- Only expand if not already handled by loadview
            if vim.wo.foldlevel == 0 then
                vim.api.nvim_set_option_value("foldlevel", 99, { scope = "local" })
            end
            
            vim.api.nvim_set_option_value("foldenable", true, { scope = "local" })
            
            vim.api.nvim_set_hl(0, "Folded", { bg = "NONE", italic = false })
            
            pcall(function()
                vim.opt_local.fillchars:append({
                    foldopen = M.config.icons.fold_open,
                    foldclose = M.config.icons.fold_close,
                    fold = " ",
                })
            end)

            -- 2. CHOOSE FOLD METHOD
            if vim.b[buf].simple_fold_large then
                vim.api.nvim_set_option_value("foldmethod", "indent", { scope = "local" })
            else
                if (ft == "php" or ext == "php") and ft ~= "php" then
                    vim.bo[buf].filetype = "php"
                    ft = "php"
                end

                if vim.fn.has("nvim-0.10") == 1 then
                    vim.api.nvim_set_option_value("foldmethod", "expr", { scope = "local" })
                    vim.api.nvim_set_option_value("foldexpr", "v:lua.require('simple-fold').foldexpr()", { scope = "local" })
                    if ft == "php" and not pcall(vim.treesitter.get_parser, buf) then
                        pcall(vim.treesitter.start, buf, "php")
                    end
                else
                    vim.api.nvim_set_option_value("foldmethod", "indent", { scope = "local" })
                end
            end
        end, 50)
    end

    local fold_group = vim.api.nvim_create_augroup("SimpleFoldAuto", { clear = true })
    vim.api.nvim_create_autocmd({ "FileType", "BufReadPost", "BufEnter", "BufWinEnter", "WinEnter" }, {
        group = fold_group,
        callback = apply_fold_settings,
    })

    apply_fold_settings()

    local view_grp = vim.api.nvim_create_augroup("SimpleFoldView", { clear = true })
    vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWritePost" }, {
        group = view_grp,
        callback = function(args)
            if vim.b[args.buf].nofile or vim.bo[args.buf].filetype == "" then return end
            pcall(vim.cmd.mkview, { mods = { emsg_silent = true } })
        end,
    })
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = view_grp,
        callback = function(args)
            if vim.b[args.buf].nofile or vim.bo[args.buf].filetype == "" then return end
            pcall(vim.cmd.loadview, { mods = { emsg_silent = true } })
        end,
    })

    -- Commands
    vim.api.nvim_create_user_command("SimpleFoldFix", apply_fold_settings, { desc = "Fix SimpleFold UI" })

    -- Keymaps
    vim.keymap.set("n", "za", M.smart_toggle, { silent = true, desc = "SimpleFold: Smart Toggle" })
    vim.keymap.set("n", "zp", M.toggle_peek, { desc = "SimpleFold: Toggle Peek" })
    for i = 1, 5 do
        vim.keymap.set("n", "z" .. i, function() vim.opt_local.foldlevel = i end, { desc = "Set Foldlevel " .. i })
    end
end

return M
