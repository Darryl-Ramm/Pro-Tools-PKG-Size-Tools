#!/bin/bash
# rx.sh
###
# Run a command or shell as root in a sandbox-exec sandbox, with all file
# writes constrained to a work directory under /tmp.
#
# This is handcuffs against accidental root writes and deletes, not a jail.
###
# MIT License
#
# Copyright (c) 2026 Darryl Ramm
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
###
# Coding assistance from Anthropic Claude.
###

GIT_TAG_VERSION="@@VERSION@@"

set -u

export BASH_SILENCE_DEPRECATION_WARNING=1

#
# Constants
#

# PATH for this script itself, system tools only, never the user's PATH.
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# PATH for commands run inside the sandbox.
SANDBOX_PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/libexec"

# Prompt for the interactive shell, so it is obvious we are root in a sandbox.
SANDBOX_PS1='[rx-sandbox] \w # '

# Writes are denied everywhere except the sandbox directory and a few devices.
SANDBOX_PROFILE='(version 1)
(allow default)
(deny file-write*)
(allow file-write*
    (subpath (param "SANDBOX_DIR"))
    (literal "/dev/null")
    (literal "/dev/tty")
    (literal "/dev/dtracehelper")
    (regex #"^/dev/ttys[0-9]+$")
    (regex #"^/dev/fd/[0-9]+$"))'

PATH="${SAFE_PATH}"
export PATH

DEBUG_OPTION=""
our_name="${0##*/}"

#
# Bash functions
#


function usage {
    echo "
 Usage: ${our_name} [-d] [-h] [-v] sandbox_work_directory [command_to_exec...]

 ${our_name} runs a command, or a bash shell, as root under sandbox-exec with
 all file writes constrained to sandbox_work_directory. This is handcuffs
 against accidental root writes and deletes, not a security jail.

 sandbox_work_directory MUST be inside /tmp or /private/tmp, for example
 /tmp/pkgwork. It is created (mode 700) if it does not exist. If it exists
 it must be a directory you own. /tmp and /private/tmp themselves are not
 allowed.

 command_to_exec can be a multi-element set of command line arguments just
 as it would be typed in a shell, it is not quoted. If command_to_exec is
 not provided we run the bash shell.

 The command runs with sandbox_work_directory as its current directory, and
 ${our_name} does not interpret the command's arguments, so relative path
 arguments are left as typed. The directory you ran ${our_name} from is
 passed to the command in the environment variable SANDBOX_RUN_FROM, so
 scripts can resolve relative path arguments against it. A command
 containing a / is taken relative to that same directory. A plain command
 name is looked up only in:
   ${SANDBOX_PATH}

 sudo asks for your password on every run, and the cached sudo credential
 is discarded when the sandbox exits.

 Options:
   -d  debug. Trace the launch (set -x) and show the command executed in
       the sandbox.
   -h  help. Print this help message and exit.
   -v  version. Print the script version and exit.
"
}


function die {
    echo "ERROR: $*" >&2
    exit 1
}


# Print the real path of the sandbox directory argument. If it does not exist
# yet, resolve its parent directory and append the final name, so we can check
# where it would be created before we create anything.
function resolve_sandbox_dir {
    local arg="$1"
    local parent
    local base

    if [[ -e "${arg}" ]]; then
        realpath "${arg}" 2>/dev/null
        return $?
    fi

    parent=$(realpath "$(dirname "${arg}")" 2>/dev/null) || return 1
    base=$(basename "${arg}")
    echo "${parent}/${base}"
}


# The resolved path must be strictly inside /private/tmp (/tmp is a symlink
# to it, so realpath always yields /private/tmp/...).
function check_sandbox_dir {
    local given="$1"
    local resolved="$2"

    case "${resolved}" in
        /private/tmp/?*)
            return 0
            ;;
    esac

    echo "ERROR: sandbox work directory must be inside /tmp or /private/tmp" >&2
    echo "       you gave:     ${given}" >&2
    echo "       resolves to:  ${resolved}" >&2
    echo "       example:      ${our_name} /tmp/mywork some_command" >&2
    exit 1
}


function launch_sandbox {
    local dir="$1"
    local rc
    shift

    cd "${dir}" || die "cd \"${dir}\" failed"

    # Discard any cached sudo credential so the user is always asked, and
    # knows what is going on and why sudo is asking for a password.
    /usr/bin/sudo -k
    echo "To launch the sandbox able to run root privilege commands sudo will ask for your password:"

    /usr/bin/sudo /usr/bin/env -i \
        PATH="${SANDBOX_PATH}" \
        TMPDIR="${dir}" \
        HOME="${dir}" \
        TERM="${TERM:-dumb}" \
        PS1="${SANDBOX_PS1}" \
        BASH_SILENCE_DEPRECATION_WARNING=1 \
        RX_IN_SANDBOX=1 \
        SANDBOX_ROOT="${dir}" \
        SANDBOX_RUN_FROM="${run_from}" \
        SANDBOX_DEBUG="${DEBUG_OPTION}" \
        /usr/bin/sandbox-exec -D "SANDBOX_DIR=${dir}" -p "${SANDBOX_PROFILE}" \
        "${this_file}" "$@"
    rc=$?

    # Do not leave a fresh sudo credential behind in this terminal.
    /usr/bin/sudo -k
    return ${rc}
}


function run_in_sandbox {
    PATH="${SANDBOX_PATH}"
    export PATH

    if [[ -n "${SANDBOX_DEBUG:-}" ]]; then
        echo "rx debug: exec ${*:-/bin/bash}" >&2
    fi

    if [[ $# -eq 0 ]]; then
        exec /bin/bash
    fi

    exec "$@"
}

#
# Main
#

if ! type -P realpath >/dev/null 2>&1; then
    die "realpath not found, this script needs macOS 13 or later"
fi

this_file=$(realpath "$0") || die "cannot resolve path of ${our_name}"

# If a nested sandbox-exec succeeds, we are not inside a sandbox yet.
if /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then

    # Launcher pass, running as the user. The only root work happens later,
    # inside the sandbox.
    if [[ ${EUID} -eq 0 ]]; then
        die "do not run ${our_name} as root or with sudo, it runs sudo itself"
    fi

    # Remember where we were run from, before launch_sandbox does its cd. It
    # is passed into the sandbox as SANDBOX_RUN_FROM so scripts running there
    # can resolve their own relative path arguments.
    run_from="${PWD}"

    while getopts ":dhv" opt; do
        case "${opt}" in
            d)
                DEBUG_OPTION="TRUE"
                ;;
            h)
                usage
                exit 0
                ;;
            v)
                echo "${GIT_TAG_VERSION}"
                exit 0
                ;;
            \?)
                echo "Invalid option -${OPTARG}" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
    shift $((OPTIND - 1))

    # Now $1 is the sandbox directory, and anything left in $@ is the command + args
    if [[ $# -eq 0 ]]; then
        echo "ERROR: sandbox_work_directory argument is missing" >&2
        usage >&2
        exit 1
    fi

    sandbox_arg="$1"
    shift

    # Resolve symlinks (/tmp -> /private/tmp) and relative paths, since the
    # sandbox profile matches on resolved paths and we cd before launching.
    # Check the location before we create anything.
    sandbox_dir=$(resolve_sandbox_dir "${sandbox_arg}") ||
        die "cannot resolve \"${sandbox_arg}\", does its parent directory exist?"
    check_sandbox_dir "${sandbox_arg}" "${sandbox_dir}"

    if [[ ! -e "${sandbox_dir}" ]]; then
        mkdir -m 700 "${sandbox_dir}" || die "mkdir \"${sandbox_dir}\" failed"

        # Resolve and check again now that it exists, in case a symlink
        # appeared in the meantime.
        sandbox_dir=$(resolve_sandbox_dir "${sandbox_dir}") ||
            die "cannot resolve \"${sandbox_arg}\" after creating it"
        check_sandbox_dir "${sandbox_arg}" "${sandbox_dir}"
    fi

    if [[ ! -d "${sandbox_dir}" ]]; then
        die "${sandbox_dir} exists but is not a directory"
    fi

    if [[ ! -O "${sandbox_dir}" ]]; then
        die "${sandbox_dir} is not owned by you"
    fi

    # Make the command unambiguous before we cd into the sandbox directory.
    if [[ $# -gt 0 ]]; then
        cmd="$1"

        case "${cmd}" in
            /*)
                ;;
            */*)
                cmd="${PWD}/${cmd}"
                ;;
        esac

        case "${cmd}" in
            */*)
                # Tidy the path (drop ./ and ../ components) by resolving
                # the directory part only, leaving the command name itself
                # alone so a symlinked command keeps its name.
                cmd_dir=$(realpath "$(dirname "${cmd}")" 2>/dev/null) ||
                    die "directory of ${cmd} not found"
                if [[ "${cmd_dir}" == "/" ]]; then
                    cmd="/$(basename "${cmd}")"
                else
                    cmd="${cmd_dir}/$(basename "${cmd}")"
                fi

                if [[ ! -f "${cmd}" || ! -x "${cmd}" ]]; then
                    die "${cmd} is not an executable file"
                fi
                ;;
            *)
                saved_path="${PATH}"
                PATH="${SANDBOX_PATH}"
                found=$(type -P "${cmd}")
                PATH="${saved_path}"
                if [[ -z "${found}" ]]; then
                    die "${cmd} not found in the sandbox PATH: ${SANDBOX_PATH}"
                fi
                ;;
        esac

        shift
        set -- "${cmd}" "$@"
    fi

    echo "Setting up sandbox directory: ${sandbox_dir} to run command: ${*:-/bin/bash}"

    if [[ -n "${DEBUG_OPTION}" ]]; then
        set -x
    fi

    launch_sandbox "${sandbox_dir}" "$@"
    exit $?
fi

# The probe failed. That is expected inside the sandbox, but it would also
# happen if sandbox-exec were missing or we were already sandboxed, so check
# that launch_sandbox started us, that we are root, and that the sandbox is
# really in effect. Otherwise fail closed rather than run unconstrained.

if [[ -z "${RX_IN_SANDBOX:-}" ]]; then
    die "sandbox-exec is unavailable, or this shell is already sandboxed"
fi

if [[ ${EUID} -ne 0 ]]; then
    die "sandbox pass is not running as root, refusing to continue"
fi

check_sandbox_dir "SANDBOX_ROOT" "${SANDBOX_ROOT:-}"

# A write outside the sandbox directory must be denied. If it succeeds the
# sandbox is not in effect: clean up and refuse.
probe_file="/private/var/root/.rx_probe.$$"
if ( : > "${probe_file}" ) 2>/dev/null; then
    /bin/rm -f "${probe_file}"
    die "sandbox is not in effect, refusing to run"
fi

# For commands that resolved via PATH we rely on the sandbox PATH set in
# run_in_sandbox.
run_in_sandbox "$@"
