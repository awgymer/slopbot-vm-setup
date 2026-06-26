# Enable Powerlevel10k instant prompt (must be near the top, before any output).
# if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
#   source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
# fi

# Powerlevel10k theme
source ~/powerlevel10k/powerlevel10k.zsh-theme

# History
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory sharehistory hist_ignore_dups hist_ignore_space hist_reduce_blanks

# Useful options
setopt autocd extendedglob nocaseglob

# Completion
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

# Aliases
[[ -f ~/.zaliases ]] && source ~/.zaliases

# User-local bin (uv, nextflow, gh, etc.)
export PATH="${HOME}/.local/bin:${PATH}"

# SDKMAN!
export SDKMAN_DIR="${HOME}/.sdkman"
[[ -s "${SDKMAN_DIR}/bin/sdkman-init.sh" ]] && source "${SDKMAN_DIR}/bin/sdkman-init.sh"

# nvm
export NVM_DIR="${HOME}/.nvm"
[[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"

# p10k config — run `p10k configure` to (re)generate
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

# Machine-local config: secrets, env vars, overrides — not committed to version control
[[ -f ~/.zlocal ]] && source ~/.zlocal
