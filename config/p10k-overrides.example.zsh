#!/usr/bin/env zsh
# ============================================================================
# PowerLevel10k User Overrides
# Part of Professional Development Terminal Setup
# ============================================================================
# Copy this file to ~/.p10k-overrides.zsh and customize as needed.
# This file is sourced AFTER the main p10k config, so your settings
# will override the defaults.
# ============================================================================

# ============================================================================
# PROMPT ELEMENTS
# ============================================================================
# Customize which elements appear in your prompt.
# Uncomment and modify the arrays below.

# Left prompt elements
# POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
#   os_icon                 # OS identifier
#   dir                     # Current directory
#   vcs                     # Git status
#   prompt_char             # Prompt character
# )

# Right prompt elements
# POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
#   status                  # Exit code of last command
#   command_execution_time  # Duration of last command
#   background_jobs         # Background job indicator
#   node_version           # Node.js version
#   python_version         # Python version
#   go_version             # Go version
#   rust_version           # Rust version
#   java_version           # Java version
#   time                    # Current time
# )

# ============================================================================
# DIRECTORY DISPLAY
# ============================================================================

# How many directories to show (0 = full path)
# POWERLEVEL9K_SHORTEN_DIR_LENGTH=3

# Truncation strategy: truncate_to_unique, truncate_from_right, etc.
# POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique

# Show ~ for home directory
# POWERLEVEL9K_DIR_SHOW_WRITABLE=true

# ============================================================================
# GIT STATUS
# ============================================================================

# Show detailed git status
# POWERLEVEL9K_VCS_SHOW_SUBMODULE_DIRTY=true

# Git status icons (customize if desired)
# POWERLEVEL9K_VCS_BRANCH_ICON='\uF126 '
# POWERLEVEL9K_VCS_UNTRACKED_ICON='?'
# POWERLEVEL9K_VCS_UNSTAGED_ICON='!'
# POWERLEVEL9K_VCS_STAGED_ICON='+'

# ============================================================================
# COLORS
# ============================================================================
# Use 0-255 color codes or color names (red, green, blue, etc.)

# Directory colors
# POWERLEVEL9K_DIR_BACKGROUND='blue'
# POWERLEVEL9K_DIR_FOREGROUND='white'

# Git colors
# POWERLEVEL9K_VCS_CLEAN_BACKGROUND='green'
# POWERLEVEL9K_VCS_CLEAN_FOREGROUND='black'
# POWERLEVEL9K_VCS_MODIFIED_BACKGROUND='yellow'
# POWERLEVEL9K_VCS_MODIFIED_FOREGROUND='black'
# POWERLEVEL9K_VCS_UNTRACKED_BACKGROUND='red'
# POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND='white'

# Status colors
# POWERLEVEL9K_STATUS_OK_BACKGROUND='green'
# POWERLEVEL9K_STATUS_ERROR_BACKGROUND='red'

# ============================================================================
# ICONS
# ============================================================================
# Customize icons (requires Nerd Font)

# OS icons
# POWERLEVEL9K_APPLE_ICON=''
# POWERLEVEL9K_LINUX_ICON=''

# Folder icons
# POWERLEVEL9K_HOME_ICON=''
# POWERLEVEL9K_HOME_SUB_ICON=''
# POWERLEVEL9K_FOLDER_ICON=''

# Git icons
# POWERLEVEL9K_VCS_GIT_ICON=''
# POWERLEVEL9K_VCS_GIT_GITHUB_ICON=''
# POWERLEVEL9K_VCS_GIT_GITLAB_ICON=''
# POWERLEVEL9K_VCS_GIT_BITBUCKET_ICON=''

# ============================================================================
# TRANSIENT PROMPT
# ============================================================================
# Simplify prompt after command execution

# Enable transient prompt
# POWERLEVEL9K_TRANSIENT_PROMPT=always

# What to show in transient prompt
# POWERLEVEL9K_TRANSIENT_PROMPT_ELEMENTS=(prompt_char)

# ============================================================================
# INSTANT PROMPT
# ============================================================================
# Speed up prompt display

# Enable instant prompt (recommended)
# POWERLEVEL9K_INSTANT_PROMPT=verbose

# ============================================================================
# TIMING
# ============================================================================

# Show execution time for commands longer than X seconds
# POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3

# Precision of execution time (seconds, milliseconds)
# POWERLEVEL9K_COMMAND_EXECUTION_TIME_PRECISION=2

# ============================================================================
# VERSION MANAGER DISPLAY
# ============================================================================

# Only show version when in a project directory
# POWERLEVEL9K_NODE_VERSION_PROJECT_ONLY=true
# POWERLEVEL9K_PYTHON_VERSION_PROJECT_ONLY=true
# POWERLEVEL9K_GO_VERSION_PROJECT_ONLY=true
# POWERLEVEL9K_RUST_VERSION_PROJECT_ONLY=true
# POWERLEVEL9K_JAVA_VERSION_PROJECT_ONLY=true

# Version display format
# POWERLEVEL9K_NODE_VERSION_VISUAL_IDENTIFIER_EXPANSION=' '
# POWERLEVEL9K_PYTHON_VERSION_VISUAL_IDENTIFIER_EXPANSION=' '
# POWERLEVEL9K_GO_VERSION_VISUAL_IDENTIFIER_EXPANSION=' '
# POWERLEVEL9K_RUST_VERSION_VISUAL_IDENTIFIER_EXPANSION=' '
# POWERLEVEL9K_JAVA_VERSION_VISUAL_IDENTIFIER_EXPANSION=' '

# ============================================================================
# NEWLINES
# ============================================================================

# Add newline before prompt
# POWERLEVEL9K_PROMPT_ADD_NEWLINE=true

# Add newline after prompt
# POWERLEVEL9K_PROMPT_ADD_NEWLINE_COUNT=1

# ============================================================================
# MULTILINE PROMPT
# ============================================================================

# Use two-line prompt
# POWERLEVEL9K_PROMPT_ON_NEWLINE=true

# First line prefix
# POWERLEVEL9K_MULTILINE_FIRST_PROMPT_PREFIX='╭─'

# Last line prefix
# POWERLEVEL9K_MULTILINE_LAST_PROMPT_PREFIX='╰─❯ '

# ============================================================================
# CUSTOM SEGMENTS
# ============================================================================
# Define your own prompt segments

# Example: Show current Kubernetes context
# prompt_my_k8s() {
#   local context=$(kubectl config current-context 2>/dev/null)
#   [[ -n $context ]] && p10k segment -f blue -t "⎈ $context"
# }

# Add to right prompt:
# POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS+=my_k8s

# ============================================================================
# LOAD OVERRIDES
# ============================================================================
# Source this file from your ~/.zshrc after sourcing ~/.p10k.zsh:
#
#   [[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
#   [[ -f ~/.p10k-overrides.zsh ]] && source ~/.p10k-overrides.zsh
#
