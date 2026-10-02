#!/usr/bin/env zsh
# ============================================================================
# Verbose Theme Preset
# Part of Professional Development Terminal Setup
# ============================================================================
# A feature-rich prompt showing all available information.
# Ideal for: New users, learning tools, system monitoring
# ============================================================================

# Comprehensive left prompt
POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    os_icon                 # OS identifier
    context                 # user@hostname
    dir                     # Current directory
    vcs                     # Git status (detailed)
    prompt_char             # Prompt character
)

# Comprehensive right prompt
POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status                  # Exit code
    command_execution_time  # Command duration
    background_jobs         # Background jobs
    direnv                  # Direnv status
    virtualenv              # Python virtualenv
    anaconda                # Conda environment
    pyenv                   # Pyenv version
    node_version           # Node.js version
    go_version             # Go version
    rust_version           # Rust version
    java_version           # Java version
    ruby_version           # Ruby version
    package                 # Package version (package.json)
    kubecontext            # Kubernetes context
    aws                     # AWS profile
    docker_machine         # Docker machine
    disk_usage             # Disk space
    ram                     # Memory usage
    load                    # System load
    battery                # Battery status (laptop)
    wifi                    # WiFi signal
    time                    # Current time
)

# Show full directory path
POWERLEVEL9K_SHORTEN_DIR_LENGTH=4
POWERLEVEL9K_SHORTEN_STRATEGY=truncate_from_right

# Add newlines for readability
POWERLEVEL9K_PROMPT_ADD_NEWLINE=true

# Two-line prompt
POWERLEVEL9K_PROMPT_ON_NEWLINE=true
POWERLEVEL9K_MULTILINE_FIRST_PROMPT_PREFIX='╭─'
POWERLEVEL9K_MULTILINE_LAST_PROMPT_PREFIX='╰─❯ '

# Detailed git status
POWERLEVEL9K_VCS_SHOW_SUBMODULE_DIRTY=true
POWERLEVEL9K_VCS_GIT_HOOKS=(vcs-detect-changes git-aheadbehind git-remotebranch git-tagname git-stash)

# Show all version managers (not just in projects)
POWERLEVEL9K_NODE_VERSION_PROJECT_ONLY=false
POWERLEVEL9K_PYTHON_VERSION_PROJECT_ONLY=false
POWERLEVEL9K_GO_VERSION_PROJECT_ONLY=false
POWERLEVEL9K_RUST_VERSION_PROJECT_ONLY=false
POWERLEVEL9K_JAVA_VERSION_PROJECT_ONLY=false

# Command execution time for any command
POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=0
POWERLEVEL9K_COMMAND_EXECUTION_TIME_PRECISION=2

# Colorful indicators
POWERLEVEL9K_DIR_BACKGROUND='blue'
POWERLEVEL9K_DIR_FOREGROUND='white'
POWERLEVEL9K_VCS_CLEAN_BACKGROUND='green'
POWERLEVEL9K_VCS_CLEAN_FOREGROUND='black'
POWERLEVEL9K_VCS_MODIFIED_BACKGROUND='yellow'
POWERLEVEL9K_VCS_MODIFIED_FOREGROUND='black'
POWERLEVEL9K_VCS_UNTRACKED_BACKGROUND='red'
POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND='white'

# Enable instant prompt
POWERLEVEL9K_INSTANT_PROMPT=verbose
