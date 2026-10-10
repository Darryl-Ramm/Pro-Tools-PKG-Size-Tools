#!/bin/bash
###
# pt_unpack.sh expand the Pro Tools installer from a .dmg
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
# Made with assistance from Anthropic Claude.
###

set -u

GIT_TAG_VERSION="@@VERSION@@"

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/libexec

ourname="${0##*/}"

OPTION_DEBUG="FALSE"

#
# bash functions
#


function decho {
    if [[ "${OPTION_DEBUG}" == "TRUE" ]]; then
        echo "DEBUG: $*" >&2
    fi
}


function die {
    echo "ERROR: $*" >&2
    exit 1
}


# Print a command to stderr, quoted so it could be pasted back into a shell,
# and then run it.
function run {
    printf '+' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    "$@"
}


function short_usage {
    echo "usage: ${ourname} [-dhv] disk_image.dmg (use -h for help)" >&2
}


function usage {

    echo "usage: ${ourname} [-dhv] disk_image.dmg

Expand the Pro Tools installer .pkg and other sub-pkgs from a .dmg and
leave those expanded packages for analysis or repackaging.

This must be run as root within an rx.sh sandbox, for example:

    ./rx.sh /tmp/X ./${ourname} ../dmgs/Pro_Tools_Mac.dmg

It will not run outside of rx.sh. A relative disk_image.dmg path is
resolved against the directory rx.sh was run from (SANDBOX_RUN_FROM).

We run this as root to preserve .pkg file ownership and make applying
changes easier. This is a simple version of more comprehensive tools for
editing/repacking the Pro Tools installer.

options:
  -d debug. Print debug messages for development use.
  -h help. Print this help information.
  -v version. Print the software version and exit.

The directory layout we create under the sandbox directory:

   mount/  The directory where the .dmg file is attached/mounted. It is
           detached and removed when this script exits.

   expand/ Pristine, untouched output of 'pkgutil --expand-full'.
           This script only ever reads from expand.

   clone/  A cp -c (aka clonefile(2)) clone of expand/. clone/ is where
           we would edit and delete files for repackaging. For here it is
           where we expand sub-pkgs to inspect their content.

This unpacked/expanded installer image is intended to be used by tools
like pt_sizes.sh.
"
}


# The sandbox directory must be strictly inside /private/tmp (rx.sh hands us
# a resolved path). Check before we remove anything below it.
function check_sandbox_root {
    case "${SANDBOX_ROOT}" in
        */..|*/../*)
            die "SANDBOX_ROOT contains .. components: ${SANDBOX_ROOT}"
            ;;
        /private/tmp/?*)
            return 0
            ;;
    esac

    die "SANDBOX_ROOT must be inside /private/tmp, it is: ${SANDBOX_ROOT}"
}


# Be sure rx.sh started us, that we are root, and that the sandbox is really
# in effect: a write outside the sandbox directory must be denied.
function verify_sandbox {
    local probe_file="/private/var/root/.pt_unpack_probe.$$"

    if [[ -z "${RX_IN_SANDBOX:-}" ]]; then
        die "not running under rx.sh (RX_IN_SANDBOX is not set), quitting"
    fi

    if [[ ${EUID} -ne 0 ]]; then
        die "must run as root within an rx.sh sandbox, quitting"
    fi

    if ( : > "${probe_file}" ) 2>/dev/null; then
        rm -f "${probe_file}"
        die "sandbox is not in effect, quitting"
    fi
}


function is_mounted {
    mount | grep -F " on ${MOUNT_DIR} (" >/dev/null
}


# Detach the .dmg if it is attached, then remove the mount directory. We use
# rmdir, never rm -rf, on a mount point.
function detach_mount {
    if is_mounted; then
        run hdiutil detach "${MOUNT_DIR}" -quiet || return 1
    fi

    if [[ -d "${MOUNT_DIR}" ]]; then
        rmdir "${MOUNT_DIR}" || return 1
    fi

    return 0
}


function cleanup {
    if ! detach_mount; then
        echo "WARNING: could not detach ${MOUNT_DIR}, detach it manually" >&2
    fi
}

#
# Main
#

while getopts ":dhv" opt; do
    case "${opt}" in
        d)

            OPTION_DEBUG="TRUE"
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
            echo "Unknown option: -${OPTARG}" >&2
            short_usage
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

if [[ $# -ne 1 ]]; then
    echo "Expected disk_image.dmg argument" >&2
    short_usage
    exit 1
fi

filename_dmg="$1"

# SANDBOX_ROOT and SANDBOX_RUN_FROM are set in the environment by rx.sh.
if [[ -z "${SANDBOX_ROOT:-}" ]]; then
    die "environment variable SANDBOX_ROOT is not set, run this with rx.sh"
fi

if [[ -z "${SANDBOX_RUN_FROM:-}" ]]; then
    die "environment variable SANDBOX_RUN_FROM is not set, run this with rx.sh"
fi

check_sandbox_root
verify_sandbox

# expand is created by the pkgutil --expand-full command
EXPAND_DIR="${SANDBOX_ROOT}/expand"

# clone is a clonefile copy of expand, rebuilt every run
CLONE_DIR="${SANDBOX_ROOT}/clone"

# mount is created when we attach the .dmg and removed when we detach it
MOUNT_DIR="${SANDBOX_ROOT}/mount"

decho "SANDBOX_ROOT=${SANDBOX_ROOT}"
decho "SANDBOX_RUN_FROM=${SANDBOX_RUN_FROM}"
decho "initial filename_dmg=${filename_dmg}"

# A relative .dmg path is relative to where rx.sh was run, not to the sandbox
# directory we are sitting in.
case "${filename_dmg}" in
    /*)
        ;;
    *)
        filename_dmg="${SANDBOX_RUN_FROM}/${filename_dmg}"
        ;;
esac

# Tidy the path (drop ./ and ../ components) by resolving the directory part.
dmg_dir=$(realpath "$(dirname "${filename_dmg}")" 2>/dev/null) ||
    die "directory of ${filename_dmg} not found"

if [[ "${dmg_dir}" == "/" ]]; then
    dmg_dir=""
fi

filename_dmg="${dmg_dir}/$(basename "${filename_dmg}")"

decho "filename_dmg=${filename_dmg}"

if [[ ! -f "${filename_dmg}" || ! -r "${filename_dmg}" ]]; then
    die "${filename_dmg} is not a file or is not readable"
fi

#
# Actually process things. This is destructive, we blow everything away each
# time to just keep stuff simple.
#

# Whatever happens from here on, detach the .dmg when we exit.
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# Delete any existing sandbox files, detaching a leftover attached .dmg first.
# If the detach fails we do not delete anything.

detach_mount || die "cannot detach the existing mount at ${MOUNT_DIR}"
run rm -rf "${EXPAND_DIR}" "${CLONE_DIR}" || die "cannot remove old expand/clone"

# Attach .dmg

run mkdir -p "${MOUNT_DIR}" || die "mkdir ${MOUNT_DIR} failed"
run hdiutil attach "${filename_dmg}" -mountpoint "${MOUNT_DIR}" -nobrowse -readonly -quiet ||
    die "hdiutil attach ${filename_dmg} failed"

# Expand the main Install Pro Tools*.pkg package

pro_tools_pkgs=( "${MOUNT_DIR}/Install Pro Tools"*.pkg )
pro_tools_pkg="${pro_tools_pkgs[0]}"

if [[ ! -e "${pro_tools_pkg}" ]]; then
    die "no Install Pro Tools*.pkg found in ${MOUNT_DIR}"
fi

if [[ ${#pro_tools_pkgs[@]} -gt 1 ]]; then
    echo "WARNING: found ${#pro_tools_pkgs[@]} Install Pro Tools*.pkg packages, using the first:" >&2
    echo "         ${pro_tools_pkg}" >&2
fi

run pkgutil --expand-full "${pro_tools_pkg}" "${EXPAND_DIR}" ||
    die "pkgutil --expand-full ${pro_tools_pkg} failed"

# Clone expand dir to clone dir with APFS clonefile(2)

run cp -c -R -p "${EXPAND_DIR}/" "${CLONE_DIR}" ||
    die "cp -c (clonefile) failed, probably not on APFS"

# Expand embedded .pkg files, we do this on the clone so as not to disturb the
# expand copy at all. Collect the list first so we are not walking the tree
# while we add new directories to it.

nested_pkgs=()
while IFS= read -r -d '' pkg; do
    nested_pkgs+=("${pkg}")
done < <(find "${CLONE_DIR}" -name '*.pkg' -type f -print0)

failures=0

# The count check matters: bash 3.2 with set -u treats expanding an empty
# array as an error.
if [[ ${#nested_pkgs[@]} -gt 0 ]]; then
    for pkg in "${nested_pkgs[@]}"; do
        if ! run pkgutil --expand-full "${pkg}" "${pkg}_expand"; then
            echo "WARNING: could not expand ${pkg}" >&2
            failures=$((failures + 1))
        fi
    done
fi

echo "Expanded installer:  ${EXPAND_DIR}"
echo "Editable clone:      ${CLONE_DIR}"
echo "Embedded .pkg files: ${#nested_pkgs[@]} found, ${failures} failed to expand"

if [[ ${failures} -ne 0 ]]; then
    exit 1
fi

exit 0
