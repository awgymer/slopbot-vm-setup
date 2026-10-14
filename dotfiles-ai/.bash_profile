# Login shells, interactive or not: `become claude` and
# `become claude claude -p "..."` both read this file.
#
# bash reads ~/.bash_profile instead of ~/.profile when it exists, so
# ~/.profile is sourced at the end. Ubuntu's ~/.profile sources ~/.bashrc
# for an interactive shell, which sources ~/.bashrc.local for the aliases.
source "${HOME}/.bash_tools"
[[ -f "${HOME}/.profile" ]] && source "${HOME}/.profile"
