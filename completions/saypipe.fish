# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Everett C. Haimes III
# fish completion for saypipe. Candidates come from `saypipe --complete <kind>`.

function __saypipe_list
    set -l tokens (commandline -opc)
    $tokens[1] --complete $argv 2>/dev/null
end

function __saypipe_first
    test (count (commandline -opc)) -eq 1
end

# __saypipe_after <option>...: the first argument is one of the options.
function __saypipe_after
    set -l tokens (commandline -opc)
    test (count $tokens) -ge 2; and contains -- $tokens[2] $argv
end

# __saypipe_args <option> <n>: the first argument is <option> and <n> other
# arguments (not --force/--global/--apply) follow it so far.
function __saypipe_args
    set -l tokens (commandline -opc)
    test (count $tokens) -ge 2; and test "$tokens[2]" = $argv[1]; or return 1
    set -l n 0
    for t in $tokens[3..-1]
        contains -- $t --force --global --apply; or set n (math $n + 1)
    end
    test $n -eq $argv[2]
end

# __saypipe_without <flag>: the flag isn't on the command line yet.
function __saypipe_without
    not contains -- $argv[1] (commandline -opc)
end

complete -c saypipe -f

# First argument: a host or an option.
complete -c saypipe -n __saypipe_first -k -a '(__saypipe_list hosts)' -d host
complete -c saypipe -n __saypipe_first -l host-add -d 'enable hosts (checks for waypipe)'
complete -c saypipe -n __saypipe_first -l host-remove -d 'remove hosts with their options'
complete -c saypipe -n __saypipe_first -l list -d 'enabled hosts with their options, or one list'
complete -c saypipe -n __saypipe_first -l probe -d 'test what hosts support'
complete -c saypipe -n __saypipe_first -l gpu-add -d 'let hosts use GPU buffers'
complete -c saypipe -n __saypipe_first -l gpu-remove -d 'back to -n for hosts'
complete -c saypipe -n __saypipe_first -l audio-add -d "play hosts' app audio here"
complete -c saypipe -n __saypipe_first -l audio-remove -d 'stop forwarding audio'
complete -c saypipe -n __saypipe_first -l share-add -d 'share one ssh connection per host'
complete -c saypipe -n __saypipe_first -l share-remove -d 'stop sharing connections'
complete -c saypipe -n __saypipe_first -l share-exit -d 'close shared connections'
complete -c saypipe -n __saypipe_first -l default-set -d "set a host's (or the global) default command"
complete -c saypipe -n __saypipe_first -l default-remove -d 'remove default commands'
complete -c saypipe -n __saypipe_first -l alias-add -d 'add an alias for a host'
complete -c saypipe -n __saypipe_first -l alias-remove -d 'remove aliases and their links'
complete -c saypipe -n __saypipe_first -l link-add -d 'make hosts commands'
complete -c saypipe -n __saypipe_first -l link-remove -d 'remove host links'
complete -c saypipe -n __saypipe_first -l completion-hosts -d 'complete all hosts or only enabled ones'
complete -c saypipe -n __saypipe_first -s h -l help -d 'show usage'

# Arguments of the options.
complete -c saypipe -n '__saypipe_after --host-add --gpu-add --audio-add --share-add --link-add --probe' -k -a '(__saypipe_list hosts)' -d host
complete -c saypipe -n '__saypipe_after --host-add --gpu-add --audio-add --share-add --link-add --alias-add; and __saypipe_without --force' -l force -d 'skip the waypipe check'
complete -c saypipe -n '__saypipe_after --probe; and __saypipe_without --apply' -l apply -d 'enable supported features'
complete -c saypipe -n '__saypipe_after --host-remove' -a '(__saypipe_list enabled-hosts)' -d 'enabled host'
complete -c saypipe -n '__saypipe_after --gpu-remove' -a '(__saypipe_list gpu)' -d 'GPU-enabled host'
complete -c saypipe -n '__saypipe_after --audio-remove' -a '(__saypipe_list audio)' -d 'audio-enabled host'
complete -c saypipe -n '__saypipe_after --share-remove --share-exit' -a '(__saypipe_list share)' -d 'shared host'
complete -c saypipe -n '__saypipe_after --link-remove' -a '(__saypipe_list links)' -d 'host link'
complete -c saypipe -n '__saypipe_after --alias-remove' -a '(__saypipe_list aliases)' -d alias
complete -c saypipe -n '__saypipe_args --alias-add 1' -k -a '(__saypipe_list hosts)' -d host
complete -c saypipe -n '__saypipe_args --default-set 0; and __saypipe_without --global' -k -a '(__saypipe_list hosts)' -d host
complete -c saypipe -n '__saypipe_args --default-set 0; and __saypipe_without --global' -l global -d 'the default for hosts without one'
complete -c saypipe -n '__saypipe_args --default-set 0; and __saypipe_without --force' -l force -d 'skip the waypipe check'
complete -c saypipe -n '__saypipe_after --default-remove; and __saypipe_without --global' -a '(__saypipe_list defaults)' -d 'host with a default'
complete -c saypipe -n '__saypipe_args --default-remove 0' -l global -d 'the global default'
complete -c saypipe -n '__saypipe_args --list 0' -a '(__saypipe_list lists)' -d list
complete -c saypipe -n '__saypipe_args --completion-hosts 0' -a 'all enabled'
