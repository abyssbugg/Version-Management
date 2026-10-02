#!/usr/bin/env zsh
# ============================================================================
# Colorblind-Friendly Theme Preset
# Part of Professional Development Terminal Setup
# ============================================================================
# Accessible color scheme avoiding red/green confusion.
# Uses blue/orange/purple palette distinguishable by most colorblind users.
# ============================================================================

# Standard prompt elements
POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    dir                     # Current directory
    vcs                     # Git status
    prompt_char             # Prompt character
)

POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status                  # Exit code
    command_execution_time  # Duration
    node_version           # Node.js version
    python_version         # Python version
)

# ============================================================================
# Colorblind-Safe Palette
# ============================================================================
# Based on IBM's colorblind-safe palette
# Avoids problematic red/green combinations

# Primary colors (distinguishable)
local COLOR_BLUE='33'      # Blue (#648FFF)
local COLOR_PURPLE='99'    # Purple (#785EF0)
local COLOR_CYAN='37'      # Cyan (#00B5AD)
local COLOR_ORANGE='208'   # Orange (#FE6100)
local COLOR_YELLOW='220'   # Yellow (#FFB000)
local COLOR_WHITE='255'    # White
local COLOR_BLACK='0'      # Black

# ============================================================================
# Directory Colors
# ============================================================================
POWERLEVEL9K_DIR_BACKGROUND=$COLOR_BLUE
POWERLEVEL9K_DIR_FOREGROUND=$COLOR_WHITE

# ============================================================================
# Git Status Colors
# ============================================================================
# Clean = Blue (instead of green)
POWERLEVEL9K_VCS_CLEAN_BACKGROUND=$COLOR_BLUE
POWERLEVEL9K_VCS_CLEAN_FOREGROUND=$COLOR_WHITE

# Modified = Orange (instead of yellow)
POWERLEVEL9K_VCS_MODIFIED_BACKGROUND=$COLOR_ORANGE
POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=$COLOR_BLACK

# Untracked = Purple (instead of red)
POWERLEVEL9K_VCS_UNTRACKED_BACKGROUND=$COLOR_PURPLE
POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=$COLOR_WHITE

# Conflicted = Yellow with pattern
POWERLEVEL9K_VCS_CONFLICTED_BACKGROUND=$COLOR_YELLOW
POWERLEVEL9K_VCS_CONFLICTED_FOREGROUND=$COLOR_BLACK

# ============================================================================
# Status Colors
# ============================================================================
# OK = Blue (instead of green)
POWERLEVEL9K_STATUS_OK_BACKGROUND=$COLOR_BLUE
POWERLEVEL9K_STATUS_OK_FOREGROUND=$COLOR_WHITE

# Error = Orange (instead of red)
POWERLEVEL9K_STATUS_ERROR_BACKGROUND=$COLOR_ORANGE
POWERLEVEL9K_STATUS_ERROR_FOREGROUND=$COLOR_BLACK

# ============================================================================
# Prompt Character Colors
# ============================================================================
POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_FOREGROUND=$COLOR_BLUE
POWERLEVEL9K_PROMPT_CHAR_OK_VICMD_FOREGROUND=$COLOR_PURPLE
POWERLEVEL9K_PROMPT_CHAR_ERROR_VIINS_FOREGROUND=$COLOR_ORANGE
POWERLEVEL9K_PROMPT_CHAR_ERROR_VICMD_FOREGROUND=$COLOR_ORANGE

# ============================================================================
# Version Manager Colors
# ============================================================================
POWERLEVEL9K_NODE_VERSION_BACKGROUND=$COLOR_CYAN
POWERLEVEL9K_NODE_VERSION_FOREGROUND=$COLOR_BLACK

POWERLEVEL9K_PYTHON_VERSION_BACKGROUND=$COLOR_YELLOW
POWERLEVEL9K_PYTHON_VERSION_FOREGROUND=$COLOR_BLACK

POWERLEVEL9K_GO_VERSION_BACKGROUND=$COLOR_CYAN
POWERLEVEL9K_GO_VERSION_FOREGROUND=$COLOR_BLACK

POWERLEVEL9K_RUST_VERSION_BACKGROUND=$COLOR_ORANGE
POWERLEVEL9K_RUST_VERSION_FOREGROUND=$COLOR_BLACK

# ============================================================================
# Additional Accessibility Options
# ============================================================================

# Use shapes/patterns in addition to colors
POWERLEVEL9K_VCS_BRANCH_ICON='⎇ '          # Branch with symbol
POWERLEVEL9K_VCS_UNTRACKED_ICON='◌ '       # Circle for untracked
POWERLEVEL9K_VCS_UNSTAGED_ICON='◐ '        # Half circle for unstaged
POWERLEVEL9K_VCS_STAGED_ICON='● '          # Filled circle for staged

# High contrast prompt character
POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION='▶'
POWERLEVEL9K_PROMPT_CHAR_ERROR_VIINS_CONTENT_EXPANSION='▷'

# Bold text for better visibility
POWERLEVEL9K_DIR_CONTENT_EXPANSION='%B${P9K_CONTENT}%b'

# Add newline for visual separation
POWERLEVEL9K_PROMPT_ADD_NEWLINE=true

# ============================================================================
# Notes
# ============================================================================
# This preset uses:
# - Blue for "good/clean" (instead of green)
# - Orange for "warning/modified" (instead of yellow/red)
# - Purple for "needs attention" (instead of red)
# - Shape indicators alongside colors
#
# For severe colorblindness, consider also enabling:
# POWERLEVEL9K_MODE='ascii'  # Text-only mode
