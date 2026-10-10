#!/bin/bash
###
# pt_sizes.sh
###
# Report on the sizes of the main and all nested packages in a Pro Tools
# installer that pt_unpack.sh has expanded, using both the installKBytes
# included in each .pkg Distribution (or PackageInfo) file and the sum of the
# expanded package Payload as a sanity test.
#
# This script only reads the expanded packages, it does not need root or the
# sandbox.
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

# Keep printf's decimal point a period whatever the user's locale is.
export LC_NUMERIC=C

ourname="${0##*/}"

# Terminal bolding just to make output easier to read, only when we are
# writing to a terminal.
b=""
o=""
if [[ -t 1 && -n "${TERM:-}" ]]; then
    b=$(tput bold 2>/dev/null) || b=""
    o=$(tput sgr0 2>/dev/null) || o=""
fi

# Results from the last list_sizes call, all in KB.
list_xml_kb=0
list_du_kb=0
list_res_kb=0

# Running totals for the Scripts .pkg, all in KB.
total_xml_kb=0
total_du_kb=0
total_res_kb=0

# Number of directories du could not fully read, which means sizes are low.
unreadable_count=0

#
# Bash functions
#


function die {
    echo "ERROR: $*" >&2
    exit 1
}


function short_usage {
    echo "usage: ${ourname} [-hv] sandbox_directory (use -h for help)" >&2
}


function usage {
    echo "usage: ${ourname} [-hv] sandbox_directory

Report on the space that each package in a Pro Tools installer .dmg says it
will consume. The installer must already be expanded by pt_unpack.sh under
sandbox_directory, the same directory you gave to rx.sh. This script only
reads, it does not need root or the sandbox. sandbox_directory can also be
given in the SANDBOX_ROOT_DIR environment variable.

For the main installer, for each package in Pro Tools Application.pkg/Scripts,
and for the PACE iLok installers, we report for each .pkg:

  installKBytes  The space the .pkg says it needs, from the installKBytes
                 attributes in its Distribution or PackageInfo XML file.

  du Payload     The apparent size of the expanded Payload directory, from
                 du -A. This is a quick sanity check on installKBytes, and
                 du -A should give a closer match to it than plain du.

The installKBytes in the root Distribution file is what sets the space
required message in the installer that users see. But Pro Tools also packages
multiple .pkg files in Pro Tools Application.pkg/Scripts, and the standard
Apple .pkg tooling only calculates installKBytes from the content of the .pkg
Payloads. The Pro Tools 2026.4.x installer states it requires 9.6 GB of space,
which seems to be missing the roughly 1.6 GB of space required for the
Pro Tools Application.pkg/Scripts/*.pkg installers.

The SCRIPTS .PKG TOTAL line sums those installers. Its third value is the
total size of their Resources directories.

options:
  -h help. Print this help message and exit.
  -v version. Print the version of this script and exit.

sandbox_directory must contain the expand/ and clone/ directories made by
pt_unpack.sh.
"
}


function sum_array {
    local total=0
    local n

    for n in "$@"; do
        (( total += n ))
    done

    echo "${total}"
}


function pkg_ref_decode {
    local string="$1"

    string="${string#\#}"
    string="${string//+/ }"
    printf '%b\n' "${string//\%/\\x}"
}


function pkg_ref_name {
    local dist="$1"
    local idx="$2"
    local id="$3"
    local name

    # Most logical match first: text on the installKBytes element itself
    name=$(xmllint --xpath "normalize-space(//pkg-ref[@installKBytes][${idx}])" "${dist}" 2>/dev/null)

    # Fallback: any pkg-ref with the same id that carries text
    if [[ -z "${name}" ]]; then
        name=$(xmllint --xpath "normalize-space(//pkg-ref[@id='${id}'][normalize-space(.)])" "${dist}" 2>/dev/null)
    fi

    printf '%s\n' "${name}"
}


function kb_to_MB {
    # We use bc here because we need floating point math.
    echo "scale=6; ${1:-0} * 1024 / 1000000" | bc
}


# Print the apparent size in KB of a directory, 0 if it does not exist. Return
# non-zero if du could not read everything, so the size may be too low.
function dir_kb {
    local dir="$1"
    local out
    local rc

    if [[ ! -d "${dir}" ]]; then
        echo 0
        return 0
    fi

    out=$(du -Aks "${dir}" 2>/dev/null)
    rc=$?
    out="${out%%[[:space:]]*}"
    echo "${out:-0}"
    return ${rc}
}


# Print the table of sizes for one Distribution or PackageInfo file and leave
# the KB totals in list_xml_kb, list_du_kb and list_res_kb.
function list_sizes {
    local dist="$1"
    local n i root parent resdir
    local -a sizes ids names paydirs du_payload du_resources

    list_xml_kb=0
    list_du_kb=0
    list_res_kb=0

    parent="$(dirname "${dist}")"
    root="$(xmllint --xpath 'name(/*)' "${dist}" 2>/dev/null)"

    if [[ -z "${root}" ]]; then
        echo "WARNING: cannot parse ${dist}" >&2
        return 1
    fi

    if [[ "${root}" == "pkg-info" ]]; then
        # Bare component pkg: PackageInfo and Payload sit side by side
        n=1
        sizes[1]=$(xmllint --xpath 'string(/pkg-info/payload/@installKBytes)' "${dist}")
        ids[1]=$(xmllint --xpath 'string(/pkg-info/@identifier)' "${dist}")
        names[1]="$(basename "${parent}")"
        names[1]="${names[1]%_expand}"
        paydirs[1]="${parent}/Payload"
    else
        # Product archive: Distribution plus one subfolder per component
        n=$(xmllint --xpath 'count(//pkg-ref[@installKBytes])' "${dist}" 2>/dev/null)
        n="${n:-0}"

        for ((i = 1; i <= n; i++)); do
            sizes[i]=$(xmllint --xpath "string(//pkg-ref[@installKBytes][${i}]/@installKBytes)" "${dist}")
            ids[i]=$(xmllint --xpath "string(//pkg-ref[@installKBytes][${i}]/@id)" "${dist}")
            names[i]="$(pkg_ref_name "${dist}" "${i}" "${ids[i]}")"
            names[i]="$(pkg_ref_decode "${names[i]}")"
            paydirs[i]="${parent}/${names[i]}/Payload"
        done
    fi

    echo 'installKBytes   du Payload  id                                                  name'
    echo '-------------  -----------  --------------------------------------------------  -----------------------------------------'

    for ((i = 1; i <= n; i++)); do
        resdir="${paydirs[i]%/Payload}/Resources"

        du_payload[i]=$(dir_kb "${paydirs[i]}") ||
            unreadable_count=$((unreadable_count + 1))
        du_resources[i]=$(dir_kb "${resdir}") ||
            unreadable_count=$((unreadable_count + 1))

        printf '  %8.2f MB  %8.2f MB  %-50s  %s\n' \
            "$(kb_to_MB "${sizes[i]}")" \
            "$(kb_to_MB "${du_payload[i]}")" \
            "${ids[i]}" \
            "${names[i]}"
    done

    # The count check matters: bash 3.2 with set -u treats expanding an empty
    # array as an error.
    if [[ ${n} -eq 0 ]]; then
        echo "  (no packages with installKBytes found)"
    else
        list_xml_kb=$(sum_array "${sizes[@]}")
        list_du_kb=$(sum_array "${du_payload[@]}")
        list_res_kb=$(sum_array "${du_resources[@]}")
    fi

    if [[ ${n} -gt 1 ]]; then
        printf '  %8.2f MB  %8.2f MB  TOTAL\n' \
            "$(kb_to_MB "${list_xml_kb}")" \
            "$(kb_to_MB "${list_du_kb}")"
    fi

    echo ""
}

#
# Main
#

while getopts ":hv" opt; do
    case "${opt}" in
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

if [[ $# -gt 1 ]]; then
    echo "Expected one sandbox_directory argument" >&2
    short_usage
    exit 1
fi

if [[ $# -eq 1 ]]; then
    SANDBOX_ROOT_DIR="$1"
else
    SANDBOX_ROOT_DIR="${SANDBOX_ROOT_DIR:-}"
fi

if [[ -z "${SANDBOX_ROOT_DIR}" ]]; then
    echo "No sandbox_directory command line argument or SANDBOX_ROOT_DIR environment variable" >&2
    short_usage
    exit 1
fi

if [[ ! -d "${SANDBOX_ROOT_DIR}" ]]; then
    die "SANDBOX_ROOT_DIR=${SANDBOX_ROOT_DIR} does not exist"
fi

for tool in xmllint du bc; do
    if ! type -P "${tool}" >/dev/null; then
        die "${tool} not found in PATH"
    fi
done

# Where we extract-full .pkg files to. This stays pristine .pkg images.
EXPAND_DIR="${SANDBOX_ROOT_DIR}/expand"

# A working clone of EXPAND_DIR, where we expand sub packages etc.
CLONE_DIR="${SANDBOX_ROOT_DIR}/clone"

abort="FALSE"

if [[ ! -d "${EXPAND_DIR}" ]]; then
    echo "EXPAND_DIR=${EXPAND_DIR} is missing" >&2
    abort="TRUE"
fi

if [[ ! -d "${CLONE_DIR}" ]]; then
    echo "CLONE_DIR=${CLONE_DIR} is missing" >&2
    abort="TRUE"
fi

if [[ "${abort}" == "TRUE" ]]; then
    exit 1
fi

#
# Pro Tools Application.pkg
#

xml="${CLONE_DIR}/Distribution"

if [[ ! -f "${xml}" ]]; then
    die "${xml} is missing"
fi

echo "${b}${xml}${o}"
list_sizes "${xml}"

#
# All the .pkg in Pro Tools Application.pkg/Scripts, including nested .pkg
#

scripts_dir="${CLONE_DIR}/Pro Tools Application.pkg/Scripts"

for dir in "${scripts_dir}/"*_expand; do

    if [[ ! -d "${dir}" ]]; then
        die "no *_expand directories in ${scripts_dir}"
    fi

    if [[ -e "${dir}/Distribution" ]]; then
        xml="${dir}/Distribution"
    elif [[ -e "${dir}/PackageInfo" ]]; then
        xml="${dir}/PackageInfo"
    else
        die "no Distribution or PackageInfo in ${dir}"
    fi

    echo "${b}${xml}${o}"
    list_sizes "${xml}"

    total_xml_kb=$((total_xml_kb + list_xml_kb))
    total_du_kb=$((total_du_kb + list_du_kb))
    total_res_kb=$((total_res_kb + list_res_kb))
done

printf '  %8.2f MB  %8.2f MB   %8.2f MB  SCRIPTS .PKG TOTAL\n' \
    "$(kb_to_MB "${total_xml_kb}")" \
    "$(kb_to_MB "${total_du_kb}")" \
    "$(kb_to_MB "${total_res_kb}")"
echo ""

#
# The PACE iLok installers in Pro Tools Application.pkg/Payload/tmp/PACE/LicenseSupport.pkg
#

xml="${CLONE_DIR}/Pro Tools Application.pkg/Payload/tmp/PACE/LicenseSupport.pkg_expand/Distribution"

if [[ -e "${xml}" ]]; then
    echo "${b}${xml}${o}"
    list_sizes "${xml}"
else
    echo "WARNING: ${xml} is missing" >&2
fi

if [[ ${unreadable_count} -ne 0 ]]; then
    echo "WARNING: ${unreadable_count} directories could not be fully read, sizes may be low" >&2
fi

exit 0
