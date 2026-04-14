# simple-fold.nvim ⚡

A high-performance, feature-rich folding plugin for Neovim that makes your code structure alive and readable.

Inspired by [nvim-ufo](https://github.com/kevinhwang91/nvim-ufo), this plugin provides a modern and powerful folding experience while remaining lightweight and highly optimized for performance.

## 🚀 Features

1.  **Modern UI & Performance**: High-performance fold rendering with syntax highlighting (colors dynamically extracted from Treesitter).
2.  **PSR-12 Smart Brace Matching**: Automatically finds and displays `{ ... }` structure, supporting PSR-12 style next-line braces.
3.  **Intelligent Bracket Nesting**: Automatically detects and pairs up to 3 outer bracket shells (e.g., `({[ ... ]})`) to keep the visualization clean.
4.  **Signature Preservation (Smart Cut)**: Protects important function arguments `()` and return types `: Type` intact while smartly filtering out redundant trailing fold-start braces.
5.  **Smart Toggle (`za`)**: A heavy-duty override for `za` that securely prevents `E490` crashes and safely jumps down to handle multi-line PSR-12 headers.
6.  **LSP Diagnostics Dashboard**: Real-time Error 󰅚, Warning 󰀪, Info 󰋽, and Hint 󰌶 counts visible on folded lines.
7.  **Multiline Return Peeking**: Preview function return values directly on the fold line (e.g., `➔ $this->data`).
8.  **Absolute PHP Conceal**: Automatically injects and **completely hides** `<?php` tags in Peek windows to enable syntax highlighting for snippets.
9.  **Persistent Folds**: Remembers your manual folds across sessions and file restarts (Auto `mkview`/`loadview`).
10. **Live Edit Portal (`zp`)**: A revolutionary "true-portal" editing experience using the **original buffer**. Allows real-time editing with full LSP, Diagnostics, and Formatter support. Safeguarded against "self-folding" and E966 crashes via intelligent monkey-patching.
11. **Relative Numbering in Peek**: Improved navigation and editing experience inside the preview window.
12. **Smart Fold Percentage**: Visualize code density at a glance (e.g., `⚡ 45 lines (12.5%)`).
13. **Large File Armor**: Automatically scales to faster folding methods for massive files to prevent lag.
14. **Quick Levels**: Toggle global fold levels instantly with `z1` through `z5`.
15. **Native Extensibility**: Fully language-agnostic logic. You can gracefully extend any folding patterns via your personal `~/.config/nvim/after/queries/` without modifying core logic.
16. **Integrated Search & History**: Use `/` and `?` inside the Peek window to search. Includes persistent **Search History (↑/↓ arrows)** and a protected Command-line range to keep your edits bounded.

## 📦 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "ThongVu1996/simple-fold.nvim",
    event = { "BufReadPost", "BufNewFile" },
    opts = {},
    config = function(_, opts)
        require("simple-fold").setup(opts)
    end
}
```

## ⌨️ Keymaps

*   `za`: Smart toggle fold (Intelligent jump for PSR-12 and E490 safeguarded).
*   `zp`: Toggle Peek Fold (Floating window).
*   `q`: Close Peek window (inside Peek).
*   `<CR>`: Jump to line and open fold (inside Peek).
*   `z1` - `z9`: Set fold level globally for the buffer.

## 🛠️ Configuration

The plugin is highly customizable. Here are the default options:

```lua
require("simple-fold").setup({
    icon = "⚡",
    suffix_text = "lines",
    large_file_cutoff = 1.5 * 1024 * 1024,
    icons = {
        error = "󰅚 ",
        warn = "󰀪 ",
        info = "󰋽 ",
        hint = "󰌶 ",
        return_symbol = "󰌆 ",
        preview = "🔍 ",
        fold_open = "",
        fold_close = "",
    },
    ui = {
        search_prompt = "  Search ",
        search_help = "  ↑/↓=history  Enter=go  Esc=cancel",
        cmd_prompt = " ⌘ Cmd ",
        cmd_help = "  range is locked  Enter=run  Esc=cancel",
        border = "rounded",
    }
})
```

---

## 🐘 Laravel Blade Setup

For the best experience with **Blade**, you need the v0.12.0+ parser which supports semantic HTML integration.

### 1. Install the Parser
Add this to your `init.lua` or Treesitter configuration:

```lua
-- Register the blade filetype
vim.filetype.add({
  pattern = {
    ['.*%.blade%.php'] = 'blade',
  },
})

-- Register the blade parser
local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
parser_config.blade = {
  install_info = {
    url = "https://github.com/EmranMR/tree-sitter-blade",
    files = {"src/parser.c"},
    branch = "main",
  },
  filetype = "blade"
}
```
Then restart Neovim and run `:TSInstall blade`.

### 2. Configure Folding
Create `~/.config/nvim/after/ftplugin/blade.lua` and add:

```lua
-- Smart Treesitter folding for Blade
vim.opt_local.foldmethod = "expr"
vim.opt_local.foldexpr = "v:lua.vim.treesitter.foldexpr()"

-- Keep folds open by default
vim.opt_local.foldlevel = 99
vim.opt_local.foldenable = true

-- Use Simple-Fold for beautiful rendering
vim.opt_local.foldtext = "v:lua.require('simple-fold').render()"
```

---
## 📄 License
MIT
