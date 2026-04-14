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
10. **Safeguarded Peek (Live Edit)**: Use `zp` to edit code in a floating window. Safeguarded against "self-folding" and macro errors.
11. **Relative Numbering in Peek**: Improved navigation and editing experience inside the preview window.
12. **Smart Fold Percentage**: Visualize code density at a glance (e.g., `⚡ 45 lines (12.5%)`).
13. **Large File Armor**: Automatically scales to faster folding methods for massive files to prevent lag.
14. **Quick Levels**: Toggle global fold levels instantly with `z1` through `z5`.
15. **Native Extensibility**: Fully language-agnostic logic. You can gracefully extend any folding patterns via your personal `~/.config/nvim/after/queries/` without modifying core logic.

## 📦 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "ThongVu1996/simple-fold.nvim",
    event = { "BufReadPost", "BufNewFile" },
    opts = {
        icon = "⚡",
        suffix_text = "lines",
        icons = {
            error = "󰅚 ",
            warn = "󰀪 ",
            info = "󰋽 ",
            hint = "󰌶 ",
        }
    },
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
*   `z1` - `z5`: Set fold level globally for the buffer.

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
    }
})
```

## 📄 License
MIT
