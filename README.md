# simple-fold.nvim ⚡

A high-performance, feature-rich folding plugin for Neovim that makes your code structure alive and readable.

![Demo](https://user-images.githubusercontent.com/placeholder.png)

## 🚀 Features

1.  **Modern UI & Performance**: limit Treesitter parsing to 150 characters to prevent lag.
2.  **PSR-12 Smart Brace Matching**: Unified color for `{` and `}` even on separate lines.
3.  **LSP Diagnostics Dashboard**: See Error, Warning, Info, and Hints inside folded blocks.
4.  **Multiline Return Peeking**: Read what your function returns without unfolding.
5.  **Smart Fold Percentage**: Visualize how much code you're hiding (e.g., `(12.5%)`).
6.  **Peek Fold (Breadcrumbs)**: Use `zp` to open a floating window with context-aware titles.
7.  **Live Edit**: Edit code directly inside the Peek window.
8.  **Protected Keymaps**: Safe `q` and `<CR>` handling (No more macro recording errors).
9.  **Smart Auto-close**: Auto-closes preview on window/buffer leave.
10. **Large File Armor**: Auto-switches to fast indent folding for files > 1.5MB.
11. **Persistence & Quick Levels**: Remember folds after restart and toggle levels with `z1-z5`.

## 📦 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "ThongVu1996/simple-fold.nvim", -- Replace with your actual user name
    event = "VeryLazy",
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
