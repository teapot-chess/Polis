#!/bin/sh
# Puts a version of Polis in place on a box installed with install.sh, and
# puts the old one back when the new one does not answer.
#
#   sudo /opt/polis/update.sh                 the latest release
#   sudo /opt/polis/update.sh --version 0.3.0 that release
#   sudo /opt/polis/update.sh --from DIR      an unpacked release (no network)
#
# The page's "Download and install" ends up here too: the program
# writes the version it wants into a file, a systemd path unit sees the
# file, and polis-update.service runs this script with --requested.
#
# What it touches: /opt/polis (the program) and the systemd units. What it
# never touches: the data, in /var/lib/polis - with one exception that only
# adds: the state file is copied aside before the new version first reads it.
#
# The switch is one rename of a symlink (/opt/polis/current), so the box
# has either the old program or the new one, never half of each. The service
# is down from the copy of the state file until the new version answers:
# about a minute, during which nothing is printed.
#
# Everything below is inside main(), called on the last line: this file
# replaces itself while it runs, and a shell that reads its script a line at
# a time would go on reading in the new one.

set -eu

REPO="teapot-chess/Polis"
INSTALL_DIR="/opt/polis"
DATA_DIR="/var/lib/polis"
CONF_FILE="/etc/polis/polis.env"
STATUS_FILE="/var/lib/polis-update/status"
REQUEST_FILE="$DATA_DIR/update/request"
UNIT_DIR="/etc/systemd/system"
SERVICE="polis.service"

say() { printf '%s\n' "polis-update: $*"; }

# One line the page reads back: "ok 0.3.0" or "failed 0.3.0 why".
status() {
    mkdir -p "$(dirname "$STATUS_FILE")"
    printf '%s\n' "$*" >"$STATUS_FILE.new"
    chmod 0644 "$STATUS_FILE.new"
    mv -f "$STATUS_FILE.new" "$STATUS_FILE"
}

fail() {
    say "$2" >&2
    status "failed $1 $2"
    exit 1
}

is_version() {
    printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo x86_64 ;;
        aarch64 | arm64) echo aarch64 ;;
        *) echo unsupported ;;
    esac
}

port() {
    value=""
    if [ -r "$CONF_FILE" ]; then
        value=$(sed -n 's/^PORT=\([0-9][0-9]*\)$/\1/p' "$CONF_FILE" | tail -n 1)
    fi
    echo "${value:-4061}"
}

answers() {
    tries=0
    while [ "$tries" -lt 45 ]; do
        if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$(port)/" 2>/dev/null; then
            return 0
        fi
        systemctl is-failed --quiet "$SERVICE" && return 1
        tries=$((tries + 1))
        sleep 2
    done
    return 1
}

point_current_at() {
    ln -sfn "releases/$1" "$INSTALL_DIR/current.new"
    mv -Tf "$INSTALL_DIR/current.new" "$INSTALL_DIR/current"
}

# The scripts and units of the release that is now current. Renamed into
# place, never written over: this file is one of them.
refresh_tools() {
    src="$INSTALL_DIR/current"

    for name in update.sh uninstall.sh; do
        cp "$src/$name" "$INSTALL_DIR/$name.new"
        chmod 0755 "$INSTALL_DIR/$name.new"
        mv -f "$INSTALL_DIR/$name.new" "$INSTALL_DIR/$name"
    done

    changed=0
    for name in polis.service polis-update.service polis-update.path; do
        if ! cmp -s "$src/$name" "$UNIT_DIR/$name"; then
            cp "$src/$name" "$UNIT_DIR/$name.new"
            chmod 0644 "$UNIT_DIR/$name.new"
            mv -f "$UNIT_DIR/$name.new" "$UNIT_DIR/$name"
            changed=1
        fi
    done

    # A box whose system has no "dialout" group was installed without that
    # line; a new unit must not bring it back and stop the service starting.
    if ! getent group dialout >/dev/null 2>&1; then
        sed -i '/^SupplementaryGroups=dialout$/d' "$UNIT_DIR/polis.service"
        changed=1
    fi

    [ "$changed" = 1 ] && systemctl daemon-reload
    return 0
}

main() {
    from=""
    wanted=""
    requested=0
    restart=1

    while [ $# -gt 0 ]; do
        case "$1" in
            --from) from="$2"; shift 2 ;;
            --version) wanted="$2"; shift 2 ;;
            --requested) requested=1; shift ;;
            --no-restart) restart=0; shift ;;
            -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
            *) say "unknown option: $1" >&2; exit 2 ;;
        esac
    done

    [ "$(id -u)" = 0 ] || { say "run this as root: sudo $0" >&2; exit 1; }

    # The request is a version number or it is nothing. It is taken away
    # before anything else: the path unit starts this again for as long as
    # the file is there.
    if [ "$requested" = 1 ]; then
        # A regular file or nothing: a FIFO would hold this unit until its
        # timeout, and a symlink would read wherever it points.
        if [ -f "$REQUEST_FILE" ] && [ ! -L "$REQUEST_FILE" ]; then
            wanted=$(head -c 32 "$REQUEST_FILE" 2>/dev/null | tr -d ' \t\r\n' || true)
        else
            wanted=""
        fi
        rm -f "$REQUEST_FILE"
        is_version "$wanted" || fail "?" "the request did not name a version"
    fi

    if [ -n "$wanted" ] && ! is_version "$wanted"; then
        say "not a version: $wanted" >&2
        exit 2
    fi

    label="${wanted:-latest}"
    tmp=""
    trap 'if [ -n "$tmp" ]; then rm -rf "$tmp"; fi' EXIT

    if [ -n "$from" ]; then
        src="$from"
    else
        cpu=$(arch)
        [ "$cpu" != unsupported ] || fail "$label" "no build for this processor ($(uname -m))"

        file="polis-linux-$cpu.tar.gz"
        if [ -n "$wanted" ]; then
            base="https://github.com/$REPO/releases/download/v$wanted"
        else
            base="https://github.com/$REPO/releases/latest/download"
        fi

        tmp=$(mktemp -d /tmp/polis-update.XXXXXX)
        say "downloading $base/$file"
        curl -fsSL --retry 2 -o "$tmp/$file" "$base/$file" ||
            fail "$label" "the download did not succeed; nothing was changed"
        curl -fsSL --retry 2 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" ||
            fail "$label" "the checksums could not be downloaded; nothing was changed"

        # The sums come from the same place as the file: this catches a
        # download that broke, not a release that was tampered with.
        (cd "$tmp" && grep " $file\$" SHA256SUMS | sha256sum -c - >/dev/null 2>&1) ||
            fail "$label" "the download does not match its checksum; nothing was changed"

        tar -xzf "$tmp/$file" -C "$tmp"
        src="$tmp/polis"
    fi

    [ -x "$src/bin/polis" ] && [ -r "$src/VERSION" ] ||
        fail "$label" "that is not an Polis release: no bin/polis in it"

    new=$(tr -d ' \t\r\n' <"$src/VERSION")
    is_version "$new" || fail "$label" "the release does not say which version it is"

    old=""
    if [ -L "$INSTALL_DIR/current" ]; then
        old=$(basename "$(readlink "$INSTALL_DIR/current")")
    fi

    if [ "$old" = "$new" ] && [ -x "$INSTALL_DIR/releases/$new/bin/polis" ]; then
        say "$new is what is installed"
        status "ok $new"
        exit 0
    fi

    say "installing $new${old:+ over $old}"

    mkdir -p "$INSTALL_DIR/releases"
    rm -rf "$INSTALL_DIR/releases/$new.new" "$INSTALL_DIR/releases/$new"
    cp -a "$src" "$INSTALL_DIR/releases/$new.new"
    chown -R root:root "$INSTALL_DIR/releases/$new.new"
    chmod -R go-w "$INSTALL_DIR/releases/$new.new"
    mv -T "$INSTALL_DIR/releases/$new.new" "$INSTALL_DIR/releases/$new"

    if [ "$restart" = 1 ]; then
        systemctl stop "$SERVICE" || true

        # The state file as the old version left it, before the new one makes
        # of it what it will. A few kilobytes, and kept: nothing here tidies
        # up after the arbiter's data.
        #
        # This runs as root inside a folder the service user owns, so it
        # follows no symlink there: a state.json or a backups that is one
        # is skipped (with a word), not copied from or into.
        if [ -f "$DATA_DIR/state.json" ] && [ ! -L "$DATA_DIR/state.json" ]; then
            if [ -L "$DATA_DIR/backups" ] || { [ -e "$DATA_DIR/backups" ] && [ ! -d "$DATA_DIR/backups" ]; }; then
                say "$DATA_DIR/backups is not a plain folder; the state file is not copied."
            else
                keep="$DATA_DIR/backups/before-$new-$(date -u +%Y%m%dT%H%M%SZ)"
                mkdir -p "$keep"
                cp -p --no-dereference "$DATA_DIR"/state.json "$keep"/ 2>/dev/null || true
                owner=$(stat -c '%U:%G' "$DATA_DIR")
                chown -R -h "$owner" "$DATA_DIR/backups"
                say "the state file as it was is in $keep"
            fi
        fi
    fi

    point_current_at "$new"
    refresh_tools

    if [ "$restart" = 0 ]; then
        status "ok $new"
        exit 0
    fi

    systemctl start "$SERVICE" || true

    if answers; then
        say "$new is running"
        status "ok $new"

        # Keep the version before, for the day this one turns out wrong.
        for dir in "$INSTALL_DIR"/releases/*; do
            name=$(basename "$dir")
            if [ "$name" != "$new" ] && [ "$name" != "$old" ]; then
                rm -rf "$dir"
            fi
        done
        exit 0
    fi

    if [ -n "$old" ] && [ -x "$INSTALL_DIR/releases/$old/bin/polis" ]; then
        say "$new did not answer; going back to $old" >&2
        systemctl stop "$SERVICE" || true
        point_current_at "$old"
        refresh_tools
        systemctl start "$SERVICE" || true
        fail "$new" "the new version did not answer within 90 seconds; $old is running again (journalctl -u polis says why)"
    fi

    fail "$new" "it was installed but does not answer (journalctl -u polis says why)"
}

main "$@"
