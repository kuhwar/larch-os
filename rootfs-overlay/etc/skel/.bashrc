# ~/.bashrc: executed by bash for non-login interactive shells.

case $- in
    *i*) ;;
      *) return;;
esac

HISTCONTROL=ignoreboth
shopt -s histappend
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s checkwinsize

# Color ls if supported
if command -v dircolors >/dev/null 2>&1; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
fi

# Prompt
PS1='\u@\h:\w\$ '
case "$TERM" in
    xterm*|rxvt*) PS1="\[\e]0;\u@\h: \w\a\]$PS1" ;;
esac

# Bash completion
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi

# larch-os: persistent, user-scoped Flatpak (Flathub --user remote + alias).
[ -r /etc/profile.d/larch-flatpak.sh ] && . /etc/profile.d/larch-flatpak.sh
