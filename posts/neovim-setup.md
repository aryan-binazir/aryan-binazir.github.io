---
title: "My Neovim Setup: Building a Development Environment That Stays Out of the Way"
date: 2024-12-03
tag: Dev Tools
excerpt: After years of tweaking configs, I've landed on a Neovim + Tmux workflow that balances speed, discoverability, and minimal cognitive overhead.
---

I've used a lot of editors. VS Code, Sublime, IntelliJ, Emacs for a painful month. I kept coming back to Vim. Not because it's the "best" editor — that argument is exhausting — but because it maps closest to how I think about editing text: as a series of composable operations.

## Why Neovim Over Vim

Neovim gave me two things I couldn't get from Vim: Lua-based configuration and a built-in LSP client. Lua configs are just easier to reason about than Vimscript, and native LSP means I get IDE-grade completions, go-to-definition, and diagnostics without a heavy plugin framework.

## The Plugin Stack

I keep it lean. Every plugin has to earn its place:

- `telescope.nvim` — fuzzy finder for files, grep, LSP symbols
- `treesitter` — syntax highlighting that actually understands the AST
- `nvim-lspconfig` — LSP configs for Go, Python, TypeScript, Lua
- `oil.nvim` — file explorer that feels like editing a buffer
- `harpoon` — quick-switch between a handful of key files

## Tmux Integration

Neovim handles code. Tmux handles everything else. I run tests in a split pane, keep a persistent session for each project, and use `tmux-sessionizer` to jump between projects in under a second. The combination means I almost never touch a mouse, and context-switching between projects has near-zero friction.

```bash
# Quick project switch
bind-key -r f run-shell "tmux neww ~/scripts/tmux-sessionizer"

# Split and run tests
bind-key -r T split-window -h "cd #{pane_current_path} && go test ./..."
```

## The Philosophy

The best development environment is the one you stop noticing. If you're spending more time configuring your editor than writing code, something's wrong. I aim for a setup that's fast to start, predictable in behavior, and invisible when I'm in flow.
