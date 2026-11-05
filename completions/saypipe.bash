# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Everett C. Haimes III
# bash completion for saypipe. Candidates come from `saypipe --complete <kind>`.

_saypipe() {
    local cur prev words cword
    if declare -F _init_completion >/dev/null 2>&1; then
        _init_completion -n @ || return
    else
        words=("${COMP_WORDS[@]}") cword=$COMP_CWORD cur=${COMP_WORDS[COMP_CWORD]}
    fi
    local sp=${words[0]} kind='' extra=''
    compopt -o nosort 2>/dev/null     # keep saypipe's order: configured hosts first

    if [ "$cword" -eq 1 ]; then
        if [[ $cur == -* ]]; then
            COMPREPLY=($(compgen -W "$("$sp" --complete options 2>/dev/null)" -- "$cur"))
        else
            COMPREPLY=($(compgen -W "$("$sp" --complete hosts 2>/dev/null)" -- "$cur"))
        fi
        return
    fi

    case ${words[1]} in
        --link|--gpu-add|--audio-add|--share-add|--host-add) kind=hosts ;;
        --host-remove)    kind=listed ;;
        --completion-hosts)
            [ "$cword" -eq 2 ] && COMPREPLY=($(compgen -W "all configured" -- "$cur"))
            return ;;
        --probe)          kind=hosts extra=--apply ;;
        --unlink)         kind=links ;;
        --gpu-remove)     kind=gpu ;;
        --audio-remove)   kind=audio ;;
        --share-remove|--share-exit) kind=share ;;
        --unalias)        kind=aliases ;;
        --default-remove) kind=defaults ;;
        --default-set)    [ "$cword" -eq 2 ] && kind=hosts ;;
        --alias)          [ "$cword" -eq 3 ] && kind=hosts ;;
    esac
    [ -n "$kind" ] || return 0
    COMPREPLY=($(compgen -W "$extra $("$sp" --complete "$kind" 2>/dev/null)" -- "$cur"))
}

complete -F _saypipe saypipe
