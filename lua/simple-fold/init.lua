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
    
    local win_width = vim.api.nvim_win_get_width(0)
    local max_col = math.min(#line, win_width - 30)
    
    -- Smart cut: only cut if the bracket is at the very end of the line's content
    -- (likely the fold-starting bracket)
    local _, last_bracket = line:find(".*[{(%[]%s*$")
    if last_bracket then
        local cluster_start = last_bracket
        while cluster_start > 1 and line:sub(cluster_start-1, cluster_start-1):match("[{(%[]") do
            cluster_start = cluster_start - 1
        end
        max_col = math.min(max_col, cluster_start - 1)
    end

    for col = 0, max_col - 1 do
        local char = line:sub(col + 1, col + 1)
        local capture_name = "Normal"
        local success, captures = pcall(vim.treesitter.get_captures_at_pos, 0, pos - 1, col)
        if success and captures and #captures > 0 then
            capture_name = "@" .. captures[#captures].capture
        end
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
    local open_char = "{"
    local close_char = "}"
    local found_on_first = false
    local brace_hl = "Special" -- Fallback

    -- 1. Identify the chain of opening brackets ending at the main fold point
    -- Use find with .* to get the index of the LAST bracket
    local _, b_end = line:find(".*[{(%[]")
    local open_cluster = ""
    local close_cluster = ""
    local found_bracket = false

    if b_end then
        -- Find the absolute START of this contiguous bracket chain
        local chain_start = b_end
        while chain_start > 1 do
            local prev = line:sub(chain_start - 1, chain_start - 1)
            if prev:match("[{(%[]") then
                chain_start = chain_start - 1
            else
                break
            end
        end

        local count = 0
        for i = chain_start, b_end do
            if count >= 3 then break end
            local char = line:sub(i, i)
            if char:match("[{(%[]") then
                open_cluster = open_cluster .. char
                local c = (char == "{") and "}" or (char == "[" and "]" or ")")
                close_cluster = close_cluster .. c
                count = count + 1
            end
        end

        -- Correctly reverse close_cluster for balanced output
        local reversed_close = ""
        for i = #close_cluster, 1, -1 do
            reversed_close = reversed_close .. close_cluster:sub(i, i)
        end
        close_cluster = reversed_close

        found_on_first = true
        found_bracket = true
        -- Highlight based on the very last bracket in the chain
        local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, pos - 1, b_end - 1)
        if ok and caps and #caps > 0 then brace_hl = "@" .. caps[#caps].capture end
        -- 2. Look on the next line (PSR-12)
        local next_l = vim.api.nvim_buf_get_lines(0, pos, pos + 1, false)[1] or ""
        local _, next_end = next_l:find(".*[{(%[]")
        if next_end then
            local char = next_l:sub(next_end, next_end)
            open_cluster = char
            close_cluster = (char == "{") and "}" or (char == "[" and "]" or ")")
            found_bracket = true
            local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, pos, next_end - 1)
            if ok and caps and #caps > 0 then brace_hl = "@" .. caps[#caps].capture end
        end
    end

    -- 3. Render the fold breadcrumb
    if not found_bracket then
        table.insert(text_parts, { " ... ", "Comment" })
    elseif found_on_first then
        table.insert(text_parts, { open_cluster, brace_hl })
        table.insert(text_parts, { " ... ", "Comment" })
        table.insert(text_parts, { close_cluster .. " ", brace_hl })
    else
        table.insert(text_parts, { " " .. open_cluster, brace_hl })
        table.insert(text_parts, { " ... ", "Comment" })
        table.insert(text_parts, { close_cluster .. " ", brace_hl })
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

    -- Return preview
    local ret_idx = -1
    local search_limit = math.min(10, num_lines - 1)
    for i = 1, search_limit do
        local l = vim.api.nvim_buf_get_lines(0, pos + i - 1, pos + i, false)[1]
        if l and l:match("^%s*return") then ret_idx = i; break end
    end
    if ret_idx ~= -1 then
        local l = vim.api.nvim_buf_get_lines(0, pos + ret_idx - 1, pos + ret_idx, false)[1]
        local val = l:match("return%s+(.-);?%s*$")
        if val then
            table.insert(text_parts, { " ➔ ", "Special" })
            table.insert(text_parts, { val:sub(1, 15), "String" })
        end
    end

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
    vim.bo[preview_buf].filetype = ft
    vim.bo[preview_buf].modifiable = true

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

    local function sync_back()
        if not vim.api.nvim_buf_is_valid(preview_buf) or not vim.api.nvim_buf_is_valid(original_buf) then return end
        local new_lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
        
        if #new_lines == 0 then return end
        
        if injected_php then
            new_lines[1] = new_lines[1]:gsub("^<%?php%s?", "")
        end
        
        vim.api.nvim_buf_set_lines(original_buf, f_start - 1, f_end, false, new_lines)
        f_end = f_start + #new_lines - 1
    end

    local peek_group = vim.api.nvim_create_augroup("SimpleFoldPeek", { clear = true })
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
        vim.keymap.set("n", "z" .. i, function() vim.opt_local.foldlevel = i end)
    end
end

return M
