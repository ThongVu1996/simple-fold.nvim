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
        error = "󰅚 ",
        warn = "󰀪 ",
        info = "󰋽 ",
        hint = "󰌶 ",
        return_symbol = "󰌆 ",
        preview = "🔍 ",
        fold_open = "",
        fold_close = "",
    }
}

-- 1. FOLDTEXT RENDERING ENGINE
function M.render()
    local pos = vim.v.foldstart
    local end_pos = vim.v.foldend
    local line = vim.api.nvim_buf_get_lines(0, pos - 1, pos, false)[1]
    
    if not line then return { { "...", "Comment" } } end
    
    local text_parts = {}
    local prev_hl = nil
    local current_text = ""
    
    -- Limit TS parsing column (Feature 1)
    local win_width = vim.api.nvim_win_get_width(0)
    local max_col = math.min(#line, win_width, 150) 

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
    
    -- Unified Brace Handling (Feature 2 - Robust Version)
    local brace_hl = nil
    local b_start, _, b_char = line:find("([%{%[])%s*$")
    if b_start then
        local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, pos - 1, b_start - 1)
        if ok and caps and #caps > 0 then brace_hl = "@" .. caps[#caps].capture end
        if brace_hl and #text_parts > 0 then
            local last_p = text_parts[#text_parts]
            if last_p[1] and b_char and last_p[1]:find(b_char, 1, true) then
                text_parts[#text_parts][2] = brace_hl
            end
        end
    end

    local separator = (#line > max_col) and "..." or " ... "
    local separator_hl = "Comment"

    -- PSR-12 Brace Search (Feature 2)
    if not brace_hl then
        local search_limit = math.min(pos + 1, end_pos - 1)
        for i = pos, search_limit do
            local next_l = vim.api.nvim_buf_get_lines(0, i, i + 1, false)[1]
            local bc, _, b_c = next_l and next_l:find("^%s*([%{%[])")
            if bc then
                separator = " " .. b_c .. " ... "
                local ok, caps = pcall(vim.treesitter.get_captures_at_pos, 0, i, bc - 1)
                if ok and caps and #caps > 0 then brace_hl = "@" .. caps[#caps].capture end
                separator_hl = brace_hl or "Comment"
                break
            end
        end
    end
    table.insert(text_parts, { separator, separator_hl })

    -- Closing Brace Rendering
    local end_l_text = vim.api.nvim_buf_get_lines(0, end_pos - 1, end_pos, false)[1]
    if end_l_text then
        local closing = end_l_text:match("^%s*(.*)") or "}"
        table.insert(text_parts, { closing, brace_hl or "Normal" })
    end

    -- Diagnostics (Feature 3)
    local diagnostics = vim.diagnostic.get(0)
    local errors, warnings, infos, hints = 0, 0, 0, 0
    for _, d in ipairs(diagnostics) do
        if d.lnum >= pos - 1 and d.lnum <= end_pos - 1 then
            local s = vim.diagnostic.severity
            if d.severity == s.ERROR then errors = errors + 1
            elseif d.severity == s.WARN then warnings = warnings + 1
            elseif d.severity == s.INFO then infos = infos + 1
            elseif d.severity == s.HINT then hints = hints + 1
            end
        end
    end
    if errors > 0 then table.insert(text_parts, { " " .. M.config.icons.error .. errors, "DiagnosticError" }) end
    if warnings > 0 then table.insert(text_parts, { " " .. M.config.icons.warn .. warnings, "DiagnosticWarn" }) end
    if infos > 0 then table.insert(text_parts, { " " .. M.config.icons.info .. infos, "DiagnosticInfo" }) end
    if hints > 0 then table.insert(text_parts, { " " .. M.config.icons.hint .. hints, "DiagnosticHint" }) end

    -- Return Peeking (Feature 4)
    local return_text = ""
    local scan_start = math.max(pos + 1, end_pos - 8)
    local ret_idx = -1
    for i = end_pos - 1, scan_start, -1 do
        local l = vim.api.nvim_buf_get_lines(0, i - 1, i, false)[1]
        if l and l:match("^%s*return") then ret_idx = i; break end
    end
    if ret_idx ~= -1 then
        local raw = vim.api.nvim_buf_get_lines(0, ret_idx - 1, end_pos - 1, false)
        local joined = ""
        for _, l in ipairs(raw) do joined = joined .. " " .. vim.trim(l) end
        joined = vim.trim(joined):gsub("%s+", " ")
        return_text = #joined > 50 and joined:sub(1, 48) .. ".." or joined
    end
    if return_text ~= "" then
        table.insert(text_parts, { "   " .. M.config.icons.return_symbol .. return_text .. " ", "Comment" })
    end

    -- Percentage Display (Feature 5)
    local count = end_pos - pos - 1
    local total = vim.api.nvim_buf_line_count(0)
    local pct = total > 0 and string.format("(%.1f%%)", (count / total) * 100) or ""
    local suffix = string.format(" %s %d %s %s ", M.config.icon, count, M.config.suffix_text, pct)
    table.insert(text_parts, { suffix, "Special" })
    
    return text_parts
end

-- 2. PEEK FOLD ENGINE (Feature 6, 7, 8, 9)
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
    local f_start = vim.fn.foldclosed(cursor[1])
    if f_start == -1 then return end
    
    local f_end = vim.fn.foldclosedend(cursor[1])
    M.original_win_id = winid
    local buf = vim.api.nvim_get_current_buf()
    
    local w = math.min(vim.api.nvim_win_get_width(0) - 10, 100)
    local h = math.min(f_end - f_start + 1, vim.api.nvim_win_get_height(0) - 5)
    
    local title = vim.api.nvim_buf_get_lines(0, f_start - 1, f_start, false)[1] or ""
    title = vim.trim(title):sub(1, 40)

    M.preview_win_id = vim.api.nvim_open_win(buf, true, {
        relative = "cursor", row = 1, col = 1,
        width = w, height = h,
        style = "minimal", border = "rounded",
        title = " " .. M.config.icons.preview .. title .. " ",
        title_pos = "center",
    })

    vim.wo[M.preview_win_id].number = true
    vim.wo[M.preview_win_id].relativenumber = true
    vim.wo[M.preview_win_id].foldenable = false
    vim.api.nvim_win_set_cursor(M.preview_win_id, {f_start, 0})

    local kopts = { buffer = buf, silent = true }
    vim.keymap.set("n", M.config.peek_keymaps.close, function() M.close_preview() end, kopts)
    vim.keymap.set("n", M.config.peek_keymaps.jump, function()
        local c = vim.api.nvim_win_get_cursor(M.preview_win_id)
        M.close_preview()
        vim.cmd("normal! zO")
        pcall(vim.api.nvim_win_set_cursor, 0, c)
        vim.cmd("normal! zz")
    end, kopts)

    vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave", "InsertEnter" }, {
        group = peek_group, buffer = buf,
        callback = function()
            vim.schedule(function()
                if M.preview_win_id and vim.api.nvim_get_current_win() ~= M.preview_win_id then
                    M.close_preview()
                end
            end)
        end,
    })
end

-- 3. SETUP & INTEGRATION
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    
    -- UI Highlights
    vim.api.nvim_set_hl(0, "Folded", { bg = "NONE", italic = false })

    -- Large File Protection (Feature 10)
    vim.api.nvim_create_autocmd("BufReadPre", {
        group = vim.api.nvim_create_augroup("SimpleFoldLargeFile", { clear = true }),
        callback = function(args)
            local ok, stats = pcall(vim.loop.fs_stat, vim.api.nvim_buf_get_name(args.buf))
            if ok and stats and stats.size > M.config.large_file_cutoff then
                vim.b[args.buf].simple_fold_large = true
                vim.schedule(function()
                    vim.opt_local.foldmethod = "indent"
                    vim.notify("Large file: Switched to fast indent folding!", vim.log.levels.WARN)
                end)
            end
        end,
    })

    -- Enable Treesitter Folding (Feature 1)
    vim.api.nvim_create_autocmd("FileType", {
        callback = function()
            if not vim.b.simple_fold_large and vim.fn.has("nvim-0.10") == 1 then
                vim.opt_local.foldmethod = "expr"
                vim.opt_local.foldexpr = "v:lua.vim.treesitter.foldexpr()"
                vim.opt_local.foldtext = "v:lua.require('simple-fold').render()"
            end
            vim.opt_local.foldlevel = 99
            vim.opt_local.foldenable = true
            vim.opt_local.fillchars:append({
                foldopen = M.config.icons.fold_open,
                foldclose = M.config.icons.fold_close,
                fold = " ",
            })
        end,
    })

    -- Persistence (Feature 11)
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

    -- Keymaps (Feature 11 - Quick Levels)
    vim.keymap.set("n", "zp", M.toggle_peek, { desc = "SimpleFold: Toggle Peek" })
    for i = 1, 5 do
        vim.keymap.set("n", "z" .. i, function() vim.opt_local.foldlevel = i end)
    end
end

return M
