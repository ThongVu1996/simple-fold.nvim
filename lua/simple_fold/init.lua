local M = {}

-- --- DEFAULT CONFIGURATION ---
M.config = {
    icon = "⚡",
    suffix_text = "lines",
    large_file_cutoff = 1572864, -- 1.5MB
    icons = {
        error = " ",
        warn  = " ",
        info  = " ",
        hint  = " ",
        preview = "🔍 ",
        return_symbol = "󰌆 ",
        fold_open = "",
        fold_close = "",
    }
}

-- Private state for Peek Fold engine
local preview_win_id = nil
local original_win_id = nil
local peek_group = vim.api.nvim_create_augroup("SimpleFoldPeek", { clear = true })

-- --- HELPER: CLOSE PREVIEW WINDOW ---
local function close_preview()
    if preview_win_id and vim.api.nvim_win_is_valid(preview_win_id) then
        pcall(vim.api.nvim_win_close, preview_win_id, true)
        preview_win_id = nil
    end
    if original_win_id and vim.api.nvim_win_is_valid(original_win_id) then
        pcall(vim.api.nvim_set_current_win, original_win_id)
        original_win_id = nil
    end
end

-- --- CORE: RENDER ENGINE (FoldText) ---
function M.render()
    local pos = vim.v.foldstart
    local end_pos = vim.v.foldend
    local line = vim.api.nvim_buf_get_lines(0, pos - 1, pos, false)[1]
    
    if not line then return { { "...", "Comment" } } end
    
    local text_parts = {}
    local prev_hl = nil
    local current_text = ""
    
    -- Performance optimization: limit Treesitter parse columns
    local win_width = vim.api.nvim_win_get_width(0)
    local max_col = math.min(#line, win_width, 150) 

    for col = 0, max_col - 1 do
        local char = line:sub(col + 1, col + 1)
        local capture_name = "Normal"
        local success, captures = pcall(vim.treesitter.get_captures_at_pos, 0, pos - 1, col)
        if success and captures and #captures > 0 then
            local capture = captures[#captures].capture
            capture_name = "@" .. capture
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
    
    -- PSR-12 BRACE MATCHING
    local separator = (#line > max_col) and "..." or " ... "
    local brace_hl = "Delimiter"
    local has_brace_in_sep = false
    
    local brace_match_col = line:find("[%{%[]%s*$")
    if brace_match_col then
        local success, captures = pcall(vim.treesitter.get_captures_at_pos, 0, pos - 1, brace_match_col - 1)
        if success and captures and #captures > 0 then
            brace_hl = "@" .. captures[#captures].capture
        end
    else
        local search_end = math.min(pos + 1, end_pos - 1)
        local brace_row, brace_col, found_brace_char
        for i = pos, search_end do
            local next_line = vim.api.nvim_buf_get_lines(0, i, i + 1, false)[1]
            if next_line then
                brace_row = i
                brace_col, _, found_brace_char = next_line:find("^%s*([%{%[])")
                if brace_col then break end
            end
        end
        if brace_col then
            separator = " " .. found_brace_char .. " ... "
            has_brace_in_sep = true
            local success, captures = pcall(vim.treesitter.get_captures_at_pos, 0, brace_row, brace_col - 1)
            if success and captures and #captures > 0 then
                brace_hl = "@" .. captures[#captures].capture
            end
        end
    end

    local separator_hl = has_brace_in_sep and brace_hl or "Comment"
    table.insert(text_parts, { separator, separator_hl })
    
    local end_line = vim.api.nvim_buf_get_lines(0, end_pos - 1, end_pos, false)[1]
    if end_line then
        local closing_part = end_line:match("^%s*(.*)") or "}"
        table.insert(text_parts, { closing_part, brace_hl })
    end
    
    -- LSP DIAGNOSTICS
    local diagnostics = vim.diagnostic.get(0)
    local errors, warnings, infos, hints = 0, 0, 0, 0
    for _, d in ipairs(diagnostics) do
        if d.lnum >= pos - 1 and d.lnum <= end_pos - 1 then
            if d.severity == vim.diagnostic.severity.ERROR then errors = errors + 1 end
            if d.severity == vim.diagnostic.severity.WARN then warnings = warnings + 1 end
            if d.severity == vim.diagnostic.severity.INFO then infos = infos + 1 end
            if d.severity == vim.diagnostic.severity.HINT then hints = hints + 1 end
        end
    end
    
    if errors > 0 or warnings > 0 or infos > 0 or hints > 0 then
        table.insert(text_parts, { "  ", "Normal" })
    end
    if errors > 0 then table.insert(text_parts, { M.config.icons.error .. errors .. " ", "DiagnosticError" }) end
    if warnings > 0 then table.insert(text_parts, { M.config.icons.warn .. warnings .. " ", "DiagnosticWarn" }) end
    if infos > 0 then table.insert(text_parts, { M.config.icons.info .. infos .. " ", "DiagnosticInfo" }) end
    if hints > 0 then table.insert(text_parts, { M.config.icons.hint .. hints .. " ", "DiagnosticHint" }) end

    -- RETURN PEEKING
    local return_text = ""
    local scan_start = math.max(pos + 1, end_pos - 8) 
    local return_line_idx = -1
    for i = end_pos - 1, scan_start, -1 do
        local l = vim.api.nvim_buf_get_lines(0, i - 1, i, false)[1]
        if l and l:match("^%s*return") then
            return_line_idx = i
            break
        end
    end

    if return_line_idx ~= -1 then
        local raw_lines = vim.api.nvim_buf_get_lines(0, return_line_idx - 1, end_pos - 1, false)
        local joined_text = ""
        for _, l in ipairs(raw_lines) do
            joined_text = joined_text .. " " .. vim.trim(l)
        end
        joined_text = vim.trim(joined_text):gsub("%s+", " ")
        if #joined_text > 50 then 
            return_text = joined_text:sub(1, 50) .. "..." 
        else
            return_text = joined_text
        end
    end
    
    if return_text ~= "" then
        table.insert(text_parts, { "  " .. M.config.icons.return_symbol .. return_text .. " ", "Comment" })
    end

    -- PERCENTAGE & SUFFIX
    local lines_count = end_pos - pos - 1
    local total_lines = vim.api.nvim_buf_line_count(0)
    local percentage = ""
    if total_lines > 0 then
        percentage = string.format("(%.1f%%)", (lines_count / total_lines) * 100)
    end
    
    local suffix = string.format(" %s %d %s %s ", M.config.icon, lines_count, M.config.suffix_text, percentage)
    table.insert(text_parts, { suffix, "Special" })
    
    return text_parts
end

-- --- PEEK ENGINE: ISOLATED & SYNCED ---
function M.toggle_peek()
    if preview_win_id and vim.api.nvim_win_is_valid(preview_win_id) then
        close_preview()
        return
    end

    local winid = vim.api.nvim_get_current_win()
    local lnum = vim.api.nvim_win_get_cursor(winid)[1]
    local fold_start = vim.fn.foldclosed(lnum)
    if fold_start == -1 then return end

    local fold_end = vim.fn.foldclosedend(lnum)
    original_win_id = winid
    local original_buf = vim.api.nvim_get_current_buf()
    local ft = vim.bo[original_buf].filetype

    -- [1] ISOLATION: Get lines
    local lines = vim.api.nvim_buf_get_lines(original_buf, fold_start - 1, fold_end, false)
    local preview_buf = vim.api.nvim_create_buf(false, true) 
    
    -- [2] PHP COLOR FIX: Inject virtual tag for Treesitter context
    if ft == "php" then
        local php_lines = { "<?php" }
        for _, l in ipairs(lines) do table.insert(php_lines, l) end
        vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, php_lines)
    else
        vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
    end
    
    vim.bo[preview_buf].filetype = ft

    -- Title logic
    local raw_title = vim.trim(lines[1] or "Code Snippet")
    local display_title = #raw_title > 45 and raw_title:sub(1, 45) .. "..." or raw_title

    -- Dimensions
    local win_width = vim.api.nvim_win_get_width(0)
    local win_height = vim.api.nvim_win_get_height(0)
    local width = math.min(win_width - 10, 100)
    local height = math.min(#lines + (ft == "php" and 1 or 0), win_height - 5)

    local opts = {
        relative = "cursor",
        row = 1, col = 1, width = width, height = height,
        style = "minimal", border = "rounded",
        title = M.config.icons.preview .. display_title .. " ", title_pos = "center",
    }

    preview_win_id = vim.api.nvim_open_win(preview_buf, true, opts)

    -- [3] UI & HIGHLIGHT LINKING
    vim.wo[preview_win_id].winhighlight = "Normal:Normal,FloatBorder:FloatBorder,CursorLine:Visual,EndOfBuffer:Normal"
    vim.wo[preview_win_id].number = true
    vim.wo[preview_win_id].relativenumber = true
    vim.wo[preview_win_id].cursorline = true
    vim.wo[preview_win_id].foldenable = false 

    -- Force Treesitter Highlighting
    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(preview_buf) then
            pcall(vim.treesitter.start, preview_buf, ft)
        end
    end)

    -- [4] LIVE SYNC: Mirror changes back to original file
    vim.api.nvim_buf_attach(preview_buf, false, {
        on_lines = function(_, _, _, first, last_orig, last_new)
            local is_php = (vim.bo[preview_buf].filetype == "php")
            local apply_first = is_php and math.max(1, first) or first
            local apply_last_orig = is_php and math.max(1, last_orig) or last_orig
            local apply_last_new = is_php and math.max(1, last_new) or last_new
            
            -- Prevent virtual PHP tag from syncing
            if is_php and first == 0 then return end
            
            local new_lines = vim.api.nvim_buf_get_lines(preview_buf, apply_first, apply_last_new, false)
            local target_first = fold_start - 1 + apply_first - (is_php and 1 or 0)
            local target_last = fold_start - 1 + apply_last_orig - (is_php and 1 or 0)
            
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(original_buf) and vim.api.nvim_buf_is_valid(preview_buf) then
                    pcall(vim.api.nvim_buf_set_lines, original_buf, target_first, target_last, false, new_lines)
                end
            end)
        end
    })

    -- Local Keymaps
    local key_opts = { buffer = preview_buf, silent = true }

    -- Keymap: Jump to line and force open fold in the original window
    vim.keymap.set("n", "<CR>", function()
        -- 1. Collect all necessary metadata BEFORE closing the floating window
        -- We need current cursor position and the target window ID
        local cursor = vim.api.nvim_win_get_cursor(preview_win_id)
        
        -- Calculate the actual line in the original buffer (account for PHP <?php offset)
        local target_line = fold_start - 1 + cursor[1] - (ft == "php" and 1 or 0)
        local target_col = cursor[2]
        
        -- Capture original_win_id into a local scope to prevent it being reset to nil by close_preview()
        local target_win = original_win_id 
        
        -- 2. Close the preview window
        -- Note: This will reset the global original_win_id to nil, but target_win remains valid here
        close_preview()
        
        -- 3. Execute jump and fold operations with a micro-delay to ensure UI stability
        vim.defer_fn(function()
            if target_win and vim.api.nvim_win_is_valid(target_win) then
                -- Return focus to the original window
                vim.api.nvim_set_current_win(target_win)
                
                -- Set cursor to the exact calculated position
                vim.api.nvim_win_set_cursor(target_win, { target_line, target_col })
                
                -- 'zv' makes the cursor line viewable (opens containing folds)
                -- 'zz' centers the screen on the cursor
                vim.cmd("normal! zvzz")
                
                -- 'zO' forces open the fold under the cursor recursively
                vim.cmd("normal! zO")
            end
        end, 10) -- 10ms delay is sufficient for Neovim to regain focus after closing a float
    end, key_opts)


    -- Auto-close
    vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
        group = peek_group,
        buffer = preview_buf,
        callback = function()
            vim.schedule(close_preview)
        end,
    })
end

-- --- INTERNAL UI SETUP ---
local function setup_ui()
    vim.api.nvim_set_hl(0, "Folded", { bg = "NONE", italic = false })
    vim.opt.foldtext = "v:lua.require'simple_fold'.render()"
    vim.opt.foldlevel = 99
    vim.opt.foldlevelstart = 99
    vim.opt.foldenable = true
    vim.opt.foldcolumn = "1"
    vim.opt.fillchars = { 
        eob = " ", 
        fold = " ", 
        foldopen = M.config.icons.fold_open, 
        foldsep = " ", 
        foldclose = M.config.icons.fold_close 
    }
end

-- --- PUBLIC API: SETUP ---
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    _G.SimpleFoldRender = M.render

    -- Large File Protection
    vim.api.nvim_create_autocmd("BufReadPre", {
        callback = function(args)
            local ok, stats = pcall(vim.loop.fs_stat, vim.api.nvim_buf_get_name(args.buf))
            if ok and stats and stats.size > M.config.large_file_cutoff then
                vim.b[args.buf].large_file = true
                vim.schedule(function()
                    vim.opt_local.foldmethod = "indent"
                end)
            end
        end,
    })

    setup_ui()

    vim.api.nvim_create_autocmd("ColorScheme", {
        pattern = "*",
        callback = setup_ui,
    })

    -- Persistence (mkview/loadview)
    local view_group = vim.api.nvim_create_augroup("SimpleFoldView", { clear = true })
    vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWritePost" }, {
        group = view_group,
        callback = function(args)
            if vim.b[args.buf].nofile or vim.bo[args.buf].filetype == "" then return end
            vim.cmd.mkview({ mods = { emsg_silent = true } })
        end,
    })
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = view_group,
        callback = function(args)
            if vim.b[args.buf].nofile or vim.bo[args.buf].filetype == "" then return end
            vim.cmd.loadview({ mods = { emsg_silent = true } })
        end,
    })

    -- Keymappings
    -- Close peek window
    vim.keymap.set("n", "q", function()
        close_preview()
    end, key_opts)
    -- Levels fold
    vim.keymap.set("n", "zp", M.toggle_peek, { desc = "Toggle Fold Preview" })
    for i = 1, 5 do
        vim.keymap.set("n", "z" .. i, function()
            vim.opt_local.foldlevel = i
        end, { desc = "Set Fold Level" })
    end
end

return M