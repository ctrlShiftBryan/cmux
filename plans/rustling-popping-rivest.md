# Add Ghostty Config to Dotfiles

## Context
Bryan is migrating from wezterm+tmux to cmux/Ghostty. He wants transparent backgrounds on unfocused panes (like his tmux setup) and wants the Ghostty config tracked in his dotfiles repo via GNU Stow.

Existing config at `~/.config/ghostty/config` has only: `shell-integration-features = no-notify`

## Steps

1. **Create stow-compatible ghostty config dir**
   - Create `~/dotfiles/ghostty/.config/ghostty/config`

2. **Write config file** with existing + new settings:
   ```
   shell-integration-features = no-notify
   background-opacity = 0.85
   unfocused-split-opacity = 0.15
   ```
   (Values are starting points — Bryan can tune after seeing the result)

3. **Add `ghostty` to stow command** in `~/dotfiles/setup.sh` (line 60):
   - Change: `stow zsh bavim tmux wezterm starship nvim agents`
   - To: `stow zsh bavim tmux wezterm starship nvim agents ghostty`

4. **Run `stow ghostty`** from `~/dotfiles` to create the symlink

## Files Modified
- `~/dotfiles/ghostty/.config/ghostty/config` (new)
- `~/dotfiles/setup.sh` (add ghostty to stow list)

## Verification
- `ls -la ~/.config/ghostty/config` should show symlink to dotfiles
- Open cmux, create a split (Cmd+D), focus one pane — unfocused pane should appear dimmed/transparent
