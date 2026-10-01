# Minimal Powerlevel10k Theme Configuration
# ============================================================================
# A distraction-free, ultra-minimal prompt: directory + git status only.
# Designed for focused work and fast rendering.
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

  # ── Left prompt — directory + prompt char only ─────────────────────────────
  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    dir
    vcs
    newline
    prompt_char
  )

  # ── Right prompt — empty for minimal look ──────────────────────────────────
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=()

  # ── Basic style ────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_MODE=nerdfont-complete
  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=false

  # ── Colors — monochrome / very subtle ──────────────────────────────────────
  typeset -g POWERLEVEL9K_DIR_BACKGROUND=none
  typeset -g POWERLEVEL9K_DIR_FOREGROUND=075
  typeset -g POWERLEVEL9K_VCS_CLEAN_BACKGROUND=none
  typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=070
  typeset -g POWERLEVEL9K_VCS_MODIFIED_BACKGROUND=none
  typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=178
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_BACKGROUND=none
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=244

  # ── Left section separators — invisible (no powerline) ─────────────────────
  typeset -g POWERLEVEL9K_LEFT_SEGMENT_SEPARATOR=''
  typeset -g POWERLEVEL9K_LEFT_SUBSEGMENT_SEPARATOR=' '
  typeset -g POWERLEVEL9K_RIGHT_SEGMENT_SEPARATOR=''
  typeset -g POWERLEVEL9K_RIGHT_SUBSEGMENT_SEPARATOR=' '

  # ── Directory ───────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
  typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=2
  typeset -g POWERLEVEL9K_DIR_MAX_LENGTH=30
  typeset -g POWERLEVEL9K_DIR_SHOW_WRITABLE=v3

  # ── Prompt char ─────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=242
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=196
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='$'

  # ── Transient prompt ─────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=always

  # ── Instant prompt ───────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet

  typeset -g POWERLEVEL9K_DISABLE_HOT_RELOAD=true

  (( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}

  # Restore saved options and drop the tracker. zsh's grammar forbids `always`
  # after a function body, so cleanup runs at the end of the anonymous function.
  'builtin' 'unset' 'p10k_config_opts'
}
