# Apple-Style Powerlevel10k Theme Configuration
# ============================================================================
# A clean, macOS-inspired prompt theme.
# Inspired by the macOS Monterey terminal aesthetic: soft colors, minimal clutter.
# ============================================================================

# Temporarily change options.
'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob

  # Unset all configuration options.
  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'

  # Zsh >= 5.1 is required.
  [[ $ZSH_VERSION == (5.<1->*|<6->.*) ]] || return

  # ── Left prompt ────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    os_icon          # macOS apple icon
    dir              # current directory
    vcs              # git status
    newline
    prompt_char      # prompt symbol
  )

  # ── Right prompt ───────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status           # exit code
    node_version     # node.js version
    python_version   # python version
    rust_version     # rust version
    time             # current time
  )

  # ── Basic style ────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_MODE=nerdfont-complete
  typeset -g POWERLEVEL9K_ICON_PADDING=moderate
  typeset -g POWERLEVEL9K_BACKGROUND_JOBS_VERBOSE=false
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_ICON='?'

  # ── Colors — macOS Big Sur palette ─────────────────────────────────────────
  typeset -g POWERLEVEL9K_DIR_BACKGROUND=039          # bright blue
  typeset -g POWERLEVEL9K_DIR_FOREGROUND=255
  typeset -g POWERLEVEL9K_VCS_CLEAN_BACKGROUND=034    # green
  typeset -g POWERLEVEL9K_VCS_MODIFIED_BACKGROUND=130 # orange
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_BACKGROUND=238
  typeset -g POWERLEVEL9K_STATUS_OK_BACKGROUND=000
  typeset -g POWERLEVEL9K_STATUS_ERROR_BACKGROUND=001
  typeset -g POWERLEVEL9K_TIME_BACKGROUND=238
  typeset -g POWERLEVEL9K_TIME_FOREGROUND=250

  # ── Directory ───────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_last
  typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=3
  typeset -g POWERLEVEL9K_DIR_MAX_LENGTH=40

  # ── Prompt char ─────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=076
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=196
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='❯'

  # ── Transient prompt ─────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=same-dir

  # ── Instant prompt ───────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_INSTANT_PROMPT=verbose

  # ── Hot reload ───────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_DISABLE_HOT_RELOAD=true

  (( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
} always {
  'builtin' 'unset' 'p10k_config_opts'
}
