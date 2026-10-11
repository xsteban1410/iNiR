#!/usr/bin/env bash
# Migration 045: Mod+U opens the iRiS Audio Engine.
#
# Fresh installs get the bind from defaults/niri; an install that keeps its Niri config never sees new defaults.
# Skipped when Mod+U is already bound anywhere in the Niri config (niri rejects duplicate binds).

MIGRATION_ID="045-audio-engine-keybind"
MIGRATION_TITLE="Audio Engine keybind"
MIGRATION_DESCRIPTION="Binds Mod+U to the iRiS Audio Engine (inir audioEngine toggle). Skipped if Mod+U is already bound."
MIGRATION_TARGET_FILE="~/.config/niri/config.d/70-binds.kdl"
MIGRATION_REQUIRED=false

_audio_bind_line='    Mod+U { spawn "inir" "audioEngine" "toggle"; }'

_audio_niri_files() {
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/niri" file
  for file in "$dir/config.kdl" "$dir"/config.d/*.kdl; do
    [[ -f "$file" ]] && printf '%s\n' "$file"
  done
}

migration_check() {
  local binds_file="${XDG_CONFIG_HOME:-$HOME/.config}/niri/config.d/70-binds.kdl" file
  [[ -f "$binds_file" ]] || return 1
  grep -q 'spawn "inir"' "$binds_file" 2>/dev/null || return 1

  while IFS= read -r file; do
    grep -Eq '^[[:space:]]*(Mod|Super)\+U[[:space:]]*(\{|[a-z-]+=)' "$file" 2>/dev/null && return 1
  done < <(_audio_niri_files)
  return 0
}

migration_preview() {
  echo -e "In 70-binds.kdl:"
  echo -e "${STY_GREEN}+ ${_audio_bind_line#"${_audio_bind_line%%[![:space:]]*}"}${STY_RST}"
}

migration_apply() {
  migration_check || return 0
  local binds_file="${XDG_CONFIG_HOME:-$HOME/.config}/niri/config.d/70-binds.kdl"
  local line_re='"equalizer" "toggle"'

  grep -q "$line_re" "$binds_file" || line_re='"session" "toggle"'
  if grep -q "$line_re" "$binds_file"; then
    sed -i "/${line_re//\"/\\\"}/a\\${_audio_bind_line}" "$binds_file"
  else
    sed -i "0,/^binds[[:space:]]*{/s//&\n${_audio_bind_line}/" "$binds_file"
  fi
}
