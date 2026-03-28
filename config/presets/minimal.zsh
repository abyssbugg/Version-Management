#!/usr/bin/env zsh
# ============================================================================
# Minimal Theme Preset
# Part of Professional Development Terminal Setup
# ============================================================================
# A clean, fast, distraction-free prompt.
# Ideal for: Experienced users, slow terminals, minimal aesthetics
# ============================================================================

# Minimal left prompt - just directory and git
POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    dir                     # Current directory
    vcs                     # Git status (minimal)
)

# Minimal right prompt - just status
POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status                  # Exit code
)

# Shorten directory display
POWERLEVEL9K_SHORTEN_DIR_LENGTH=2
POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique

# Disable newlines for compact display
POWERLEVEL9K_PROMPT_ADD_NEWLINE=false

# Enable transient prompt (clean history)
POWERLEVEL9K_TRANSIENT_PROMPT=always

# Disable segment separators for cleaner look
POWERLEVEL9K_LEFT_SEGMENT_SEPARATOR=''
POWERLEVEL9K_RIGHT_SEGMENT_SEPARATOR=''
POWERLEVEL9K_LEFT_SUBSEGMENT_SEPARATOR=' '
POWERLEVEL9K_RIGHT_SUBSEGMENT_SEPARATOR=' '

# Simple prompt character
POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION='❯'
POWERLEVEL9K_PROMPT_CHAR_ERROR_VIINS_CONTENT_EXPANSION='❯'

# Muted colors
POWERLEVEL9K_DIR_FOREGROUND='blue'
POWERLEVEL9K_DIR_BACKGROUND='none'
POWERLEVEL9K_VCS_CLEAN_FOREGROUND='green'
POWERLEVEL9K_VCS_CLEAN_BACKGROUND='none'
POWERLEVEL9K_VCS_MODIFIED_FOREGROUND='yellow'
POWERLEVEL9K_VCS_MODIFIED_BACKGROUND='none'

# Disable icons for text-only display (optional)
# POWERLEVEL9K_MODE='ascii'

# Fast instant prompt
POWERLEVEL9K_INSTANT_PROMPT=quiet
