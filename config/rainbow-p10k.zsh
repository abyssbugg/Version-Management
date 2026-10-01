# Rainbow Powerlevel10k Theme Configuration
# ============================================================================
# A vibrant, colorful prompt with full segment decorations.
# Great for presentations, screenshots, and color terminal lovers.
# ============================================================================


() {
  emulate -L zsh -o extended_glob
  'builtin' 'local' '-a' 'p10k_config_opts'
  [[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
  [[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
  [[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
  'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'

  [[ $ZSH_VERSION == (5.<1->*|<6->.*) ]] || return

  # ── Left prompt ────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    os_icon
    context              # user@host (shown when not default)
    dir                  # current directory
    vcs                  # git status
    newline
    prompt_char
  )

  # ── Right prompt ───────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status
    background_jobs
    command_execution_time
    node_version
    python_version
    rust_version
    go_version
    rbenv
    time
  )

  # ── Basic style ────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_MODE=nerdfont-complete
  typeset -g POWERLEVEL9K_ICON_PADDING=moderate
  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true

  # ── Segment fill / separators ──────────────────────────────────────────────
  typeset -g POWERLEVEL9K_LEFT_SEGMENT_SEPARATOR='\uE0B0'   #
  typeset -g POWERLEVEL9K_RIGHT_SEGMENT_SEPARATOR='\uE0B2'  #
  typeset -g POWERLEVEL9K_LEFT_SUBSEGMENT_SEPARATOR='\uE0B1'
  typeset -g POWERLEVEL9K_RIGHT_SUBSEGMENT_SEPARATOR='\uE0B3'

  # ── Rainbow color palette ───────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_OS_ICON_BACKGROUND=201       # magenta
  typeset -g POWERLEVEL9K_OS_ICON_FOREGROUND=255
  typeset -g POWERLEVEL9K_DIR_BACKGROUND=027            # blue
  typeset -g POWERLEVEL9K_DIR_FOREGROUND=255
  typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=250
  typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=255
  typeset -g POWERLEVEL9K_VCS_CLEAN_BACKGROUND=034      # green
  typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=255
  typeset -g POWERLEVEL9K_VCS_MODIFIED_BACKGROUND=130   # orange
  typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=255
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_BACKGROUND=057  # purple
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=255
  typeset -g POWERLEVEL9K_TIME_BACKGROUND=238
  typeset -g POWERLEVEL9K_TIME_FOREGROUND=250
  typeset -g POWERLEVEL9K_STATUS_OK_BACKGROUND=034
  typeset -g POWERLEVEL9K_STATUS_ERROR_BACKGROUND=160
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_BACKGROUND=052
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=255
  typeset -g POWERLEVEL9K_NODE_VERSION_BACKGROUND=022
  typeset -g POWERLEVEL9K_NODE_VERSION_FOREGROUND=255
  typeset -g POWERLEVEL9K_PYTHON_VERSION_BACKGROUND=024
  typeset -g POWERLEVEL9K_PYTHON_VERSION_FOREGROUND=255
  typeset -g POWERLEVEL9K_RUST_VERSION_BACKGROUND=094
  typeset -g POWERLEVEL9K_RUST_VERSION_FOREGROUND=255

  # ── Directory ───────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
  typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=4
  typeset -g POWERLEVEL9K_DIR_MAX_LENGTH=50
  typeset -g POWERLEVEL9K_DIR_SHOW_WRITABLE=v3

  # ── Prompt char ─────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=076
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=196
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='❯'

  # ── Execution time ──────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_PRECISION=1
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FORMAT='d h m s'

  # ── Transient prompt ─────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=off

  # ── Instant prompt ───────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_INSTANT_PROMPT=verbose

  typeset -g POWERLEVEL9K_DISABLE_HOT_RELOAD=true

  (( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}

  # Restore saved options and drop the tracker. zsh's grammar forbids `always`
  # after a function body, so cleanup runs at the end of the anonymous function.
  'builtin' 'unset' 'p10k_config_opts'
}
