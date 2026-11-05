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
    local sp=${words[0]} kind='' extra='' w n
    compopt -o nosort 2>/dev/null     # keep saypipe's order: enabled hosts first

    if [ "$cword" -eq 1 ]; then
        if [[ $cur == -* ]]; then
            COMPREPLY=($(compgen -W "$("$sp" --complete options 2>/dev/null)" -- "$cur"))
        else
            COMPREPLY=($(compgen -W "$("$sp" --complete hosts 2>/dev/null)" -- "$cur"))
        fi
        return
    fi

    # flags already on the line aren't offered again
    local have=" ${words[*]:2:cword-2} "
    case ${words[1]} in
        --host-add|--gpu-add|--audio-add|--share-add|--link-add)
            kind=hosts; [[ $have == *" --force "* ]] || extra=--force ;;
        --probe)
            kind=hosts; [[ $have == *" --apply "* ]] || extra=--apply ;;
        --host-remove)    kind=enabled-hosts ;;
        --gpu-remove)     kind=gpu ;;
        --audio-remove)   kind=audio ;;
        --share-remove|--share-exit) kind=share ;;
        --link-remove)    kind=links ;;
        --alias-remove)   kind=aliases ;;
        --alias-add)
            # [--force] <alias> <host>: hosts in the second non-flag position
            n=0
            for w in "${words[@]:2:cword-2}"; do [ "$w" = --force ] || n=$((n + 1)); done
            [[ $have == *" --force "* ]] || extra=--force
            [ "$n" -eq 1 ] && kind=hosts ;;
        --default-set)
            # [--force] <host> <command...> | --global <command...>
            n=0
            for w in "${words[@]:2:cword-2}"; do case $w in --force|--global) ;; *) n=$((n + 1)) ;; esac; done
            if [ "$n" -eq 0 ] && [[ $have != *" --global "* ]]; then
                kind=hosts extra="--global --force"
            fi ;;
        --default-remove)
            [ "$cword" -eq 2 ] && extra=--global
            [[ $have == *" --global "* ]] || kind=defaults ;;
        --list)
            [ "$cword" -eq 2 ] && kind=lists ;;
        --completion-hosts)
            [ "$cword" -eq 2 ] && COMPREPLY=($(compgen -W "all enabled" -- "$cur"))
            return ;;
    esac
    [ -n "$kind$extra" ] || return 0
    COMPREPLY=($(compgen -W "$extra ${kind:+$("$sp" --complete "$kind" 2>/dev/null)}" -- "$cur"))
}

complete -F _saypipe saypipe
