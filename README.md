# rx.sh, pt_unpack.sh, pt_sizes.sh

[![Latest Release](https://img.shields.io/github/v/release/Darryl-Ramm/Pro-Tools-PKG-Size-Tools?include_prereleases&sort=semver)](https://github.com/Darryl-Ramm/Pro-Tools-PKG-Size-Tools/releases/latest)

Three macOS bash utilities for taking apart an Avid Pro Tools macOS installer
without being afraid of what you are doing as root.

Expanding a macOS `.pkg` and working with the result as root preserves file
ownership and makes changes easier, but it also means a stray `rm -rf` run as
root could do a lot of harm. `rx.sh` puts a pair of handcuffs on that: root
shell or commands writes are confined by sandbox-exec(1) to one scratch directory.
`pt_unpack.sh` is run in that sandbox to expand the installer, and `pt_sizes.sh`
run outside of the sandbox reports on the install sizes of all the installer
.pkg and sub-pkg.

| Script         | Runs as            | What it does                                              |
|----------------|--------------------|-----------------------------------------------------------|
| `rx.sh`        | you (uses `sudo`)  | Runs a command or shell as root, writes limited to one directory |
| `pt_unpack.sh` | root, inside `rx.sh` | Expands a Pro Tools installer `.dmg` into `.pkg` contents |
| `pt_sizes.sh`  | you                | Reports installer sizes from the expanded packages        |

These tools do not include or redistribute any Avid software. You supply your
own installer `.dmg`.

## Quick start

```
./rx.sh /tmp/X ./pt_unpack.sh ../dmgs/Pro_Tools_26.4.1_Mac.dmg
./pt_sizes.sh /tmp/X
```

The first command asks for your `sudo` password, attaches the `.dmg` read-only,
expands the installer, and detaches the image again. The second reads the
result and prints the size report. Everything lands under `/tmp/X`.

To clean up afterwards, run the removal inside the sandbox too, since the
expanded files are owned by root:

```
./rx.sh /tmp/X rm -rf expand clone
```

Then `rmdir /tmp/X` as yourself.

## Requirements

* macOS 13 or later (`rx.sh` uses `realpath`, which older macOS lacks)
* An administrator account that can use `sudo`
* An APFS volume for `/tmp` (`pt_unpack.sh` makes its working copy with
  `cp -c`, which uses clonefile(2))
* The macOS system bash (3.2) is enough, the scripts avoid newer features
* `pt_sizes.sh` also needs `xmllint`, `du`, and `bc`, all of which ship with
  macOS

## Installing

Copy the three scripts into a directory and make them executable:

```
chmod +x rx.sh pt_unpack.sh pt_sizes.sh
```

The examples here run them as `./name`, from that directory.

## rx.sh

Run a command, or a bash shell, as root under `sandbox-exec`, with all file
writes confined to a sandbox directory.

```
rx.sh [-d] [-h] [-v] sandbox_work_directory [command_to_exec...]
```

* `sandbox_work_directory` **must be inside `/tmp` or `/private/tmp`**, for
  example `/tmp/pkgwork`. `/tmp` itself is not allowed. If the directory does
  not exist it is created with mode 700. If it exists it must be a directory
  you own with no group or other access, because root will be creating files
  in it. Mismatches get an error that says what is wrong.
* If you give no command you get an interactive root `bash`, with a
  `[rx-sandbox]` prompt so you can tell where you are.
* The command's arguments are not interpreted. They are passed through as
  typed.
* Options: `-d` traces the launch and shows the exact command run in the
  sandbox, `-h` prints help, `-v` prints the version.

### What the command sees

* The current directory is the sandbox directory, so relative arguments are
  relative to it.
* The directory you ran `rx.sh` from is passed in the environment variable
  `SANDBOX_RUN_FROM`. Scripts that take relative paths to files outside the
  sandbox, such as a `.dmg` somewhere else, can resolve them against it.
* A command containing a `/` is taken relative to the directory you ran
  `rx.sh` from. A plain command name is looked up only in
  `/bin:/sbin:/usr/bin:/usr/sbin:/usr/libexec`, so tools in Homebrew
  directories are not found.
* `TMPDIR` and `HOME` are both the sandbox directory, so temporary files and
  tool caches land inside it rather than touching your real home.
* Other environment variables set for the command: `SANDBOX_ROOT` (the
  sandbox directory), `SANDBOX_DEBUG`, and `RX_IN_SANDBOX`.
* The rest of your environment is cleared.

### How it stays safe

* Root only ever runs `sandbox-exec`. The script's own logic runs inside the
  sandbox.
* Your PATH is not used to find `sudo`, `env`, or `sandbox-exec`, so a
  planted program of the same name cannot capture your password.
* `rx.sh` refuses to run as root or under `sudo`, and refuses to continue if
  the sandbox is not really in effect. Inside the sandbox it checks that a
  write outside the sandbox directory is denied.
* `sudo` asks for your password on every run, and the cached credential is
  discarded when the sandbox exits.

### What it is not

This is handcuffs, not a jail. It stops root from writing or deleting files
outside the sandbox directory, which is the accident it is built for. It does
not stop a hostile program: root inside the sandbox can still read files, use
the network, signal processes, or ask system daemons (`launchctl`, `diskutil`,
and so on) to act on its behalf. Apple also lists `sandbox-exec` as
deprecated, though it still works.

## pt_unpack.sh

Expand the Pro Tools installer from a `.dmg`, leaving the expanded packages for
analysis or repackaging. It must run as root inside `rx.sh` and refuses to run
anywhere else.

```
./rx.sh /tmp/X ./pt_unpack.sh [-dhv] disk_image.dmg
```

A relative `.dmg` path is resolved against the directory you ran `rx.sh` from,
so the image can stay wherever it already is.

What it does:

1. Attaches the `.dmg` read-only (`-readonly -nobrowse`) at `mount/`.
2. Expands the main `Install Pro Tools*.pkg` with `pkgutil --expand-full`
   into `expand/`.
3. Makes a clonefile copy of `expand/` in `clone/`.
4. Expands the embedded `.pkg` files in `clone/`, each into a sibling
   directory named `<name>.pkg_expand`.
5. Detaches the image and removes `mount/` when it exits, including when it
   fails or is interrupted.

The layout it leaves under the sandbox directory:

| Directory | Contents                                                           |
|-----------|--------------------------------------------------------------------|
| `mount/`  | Where the `.dmg` is attached. Only present while the script runs. |
| `expand/` | Pristine, untouched output of `pkgutil --expand-full`. This script only ever reads from it. |
| `clone/`  | A clone of `expand/`, where edits, deletions, and sub-package expansion happen. |

It is destructive on purpose: each run removes the previous `expand/` and
`clone/` and starts again. It will not delete anything if a leftover mount
cannot be detached. Failures expanding individual embedded packages are
reported and make the final exit status nonzero, but do not stop the rest.

Options: `-d` prints debug messages, `-h` prints help, `-v` prints the
version.

## pt_sizes.sh

Report on the space each package in a Pro Tools installer says it will consume,
based on the output of `pt_unpack.sh`. It only reads, so it does not need root
or the sandbox.

```
./pt_sizes.sh [-hv] sandbox_directory
```

`sandbox_directory` is the same directory you gave to `rx.sh`, and must contain
`expand/` and `clone/`. It can also be given in the `SANDBOX_ROOT_DIR`
environment variable.

For the main installer, for every package in
`Pro Tools Application.pkg/Scripts`, and for the PACE iLok installers, it
prints a table with, for each package:

* **installKBytes**: the space the package says it needs, from the Distribution
  or PackageInfo XML file
* **du Payload**: the apparent size of the expanded Payload directory
  (`du -A`), as a sanity check on `installKBytes`

The `SCRIPTS .PKG TOTAL` line sums the installers in `Scripts`.

The reason for the extra detail: the installKBytes in the root Distribution
file is what sets the space required message users see, but Pro Tools also
packages several `.pkg` files in `Pro Tools Application.pkg/Scripts`, and
Apple's packaging tools only count the Payloads. The Pro Tools 2026.4.x
installer states 9.6 GB, which seems to be missing roughly 1.6 GB for those
nested installers.

The expanded files are owned by root. If `du` cannot read some directories,
the sizes are too low, and the script prints a warning with a count at the end.

Options: `-h` prints help, `-v` prints the version.

## Versioning

Each script carries a `@@VERSION@@` placeholder that is replaced with the git
tag when the tarball is built. A copy taken straight from the repository
reports `@@VERSION@@` for `-v`. Unfortunately currently all .sh files share
the same git tag versions. 

## License

MIT. Copyright (c) 2026 Darryl Ramm. See the header of each script for the full
text.
