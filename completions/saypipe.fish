# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Everett C. Haimes III
# fish completion for saypipe. Candidates come from `saypipe --complete <kind>`.

function __saypipe_list
    set -l tokens (commandline -opc)
    $tokens[1] --complete $argv 2>/dev/null
end

# __saypipe_at <n> <option>...: the command line has n tokens before the
# cursor and its first argument is one of the options.
function __saypipe_at
    set -l tokens (commandline -opc)
    test (count $tokens) -eq $argv[1]; and contains -- $tokens[2] $argv[2..-1]
end

# __saypipe_after <option>...: the first argument is one of the options.
function __saypipe_after
    set -l tokens (commandline -opc)
    test (count $tokens) -ge 2; and contains -- $tokens[2] $argv
end

function __saypipe_first
    test (count (commandline -opc)) -eq 1
end

complete -c saypipe -f

# First argument: a host or an option.
complete -c saypipe -n __saypipe_first -k -a '(__saypipe_list hosts)' -d host
complete -c saypipe -n __saypipe_first -l link -d 'create host links'
complete -c saypipe -n __saypipe_first -l unlink -d 'remove host links'
complete -c saypipe -n __saypipe_first -l alias -d 'link an alias to a host'
complete -c saypipe -n __saypipe_first -l unalias -d 'remove aliases and their links'
complete -c saypipe -n __saypipe_first -l gpu-add -d 'let hosts use GPU buffers'
complete -c saypipe -n __saypipe_first -l gpu-remove -d 'back to -n for hosts'
complete -c saypipe -n __saypipe_first -l gpu-list -d 'list GPU-enabled hosts'
complete -c saypipe -n __saypipe_first -l audio-add -d "play hosts' app audio here"
complete -c saypipe -n __saypipe_first -l audio-remove -d 'stop forwarding audio'
complete -c saypipe -n __saypipe_first -l audio-list -d 'list audio-enabled hosts'
complete -c saypipe -n __saypipe_first -l share-add -d 'share one ssh connection per host'
complete -c saypipe -n __saypipe_first -l share-remove -d 'stop sharing connections'
complete -c saypipe -n __saypipe_first -l share-list -d 'list hosts with connection sharing'
complete -c saypipe -n __saypipe_first -l share-exit -d 'close shared connections'
complete -c saypipe -n __saypipe_first -l list -d 'list every known host'
complete -c saypipe -n __saypipe_first -l probe -d 'test what hosts support'
complete -c saypipe -n __saypipe_first -l default-set -d "set a host's default command"
complete -c saypipe -n __saypipe_first -l default-remove -d 'remove default commands'
complete -c saypipe -n __saypipe_first -l default-list -d 'list default commands'
complete -c saypipe -n __saypipe_first -l global-default -d 'set the default for host links'
complete -c saypipe -n __saypipe_first -l global-default-remove -d 'remove the global default'
complete -c saypipe -n __saypipe_first -s h -l help -d 'show usage'

# Arguments of the management options.
complete -c saypipe -n '__saypipe_after --link --gpu-add --audio-add --share-add --probe' -k -a '(__saypipe_list hosts)' -d host
complete -c saypipe -n '__saypipe_after --probe' -l apply -d 'enable supported features'
complete -c saypipe -n '__saypipe_after --unlink' -a '(__saypipe_list links)' -d 'host link'
complete -c saypipe -n '__saypipe_after --gpu-remove' -a '(__saypipe_list gpu)' -d 'GPU-enabled host'
complete -c saypipe -n '__saypipe_after --audio-remove' -a '(__saypipe_list audio)' -d 'audio-enabled host'
complete -c saypipe -n '__saypipe_after --share-remove --share-exit' -a '(__saypipe_list share)' -d 'shared host'
complete -c saypipe -n '__saypipe_after --unalias' -a '(__saypipe_list aliases)' -d alias
complete -c saypipe -n '__saypipe_after --default-remove' -a '(__saypipe_list defaults)' -d 'host with a default'
complete -c saypipe -n '__saypipe_at 2 --default-set' -k -a '(__saypipe_list hosts)' -d host
complete -c saypipe -n '__saypipe_at 3 --alias' -k -a '(__saypipe_list hosts)' -d host
