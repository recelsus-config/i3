#!/bin/sh

preferred_terminals="ghostty alacritty x-terminal-emulator xterm"

for terminal_cmd in $preferred_terminals; do
  if command -v "$terminal_cmd" >/dev/null 2>&1; then
    exec "$terminal_cmd"
  fi
done

exec xterm
