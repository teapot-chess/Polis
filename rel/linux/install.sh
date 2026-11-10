#!/bin/sh
# Installs Polis on a Linux box - a small PC or a Raspberry Pi in the hall -
# as a service that starts with the machine.
#
#   curl -fsSL https://github.com/teapot-chess/Polis/releases/latest/download/install.sh | sudo sh
#
# or, in a hall without internet, from a release unpacked on a stick:
#
#   tar -xzf polis-linux-x86_64.tar.gz && sudo sh polis/install.sh
#
# Options (after `sh -s --` when piped):
#   --lan             let other machines in the hall reach the page (a box
#                     without a screen). They are asked for the access PIN,
#                     which this script prints when it is done and which
#                     stays in /var/lib/polis/access-pin.
#   --version X.Y.Z   that release instead of the latest
#
# What it does, and nothing more:
#   /opt/polis            the program, owned by root; replaced by updates
#   /var/lib/polis        the data, owned by the user "polis"; never
#                          replaced, never removed - not by an update, not by
#                          uninstall.sh
#   /etc/polis/polis.env the two settings of the service (port, network);
#                          written once and then left to you
#   a system user "polis" (printing goes through CUPS, which needs no group)
#   polis.service, polis-update.path, polis-update.service
#
# Run it again to repair an installation; it changes no setting and no data.
#
# Needs: a 64-bit system (x86_64 or arm64) with systemd and glibc 2.35 or
# newer - Debian 12, Ubuntu 22.04, Raspberry Pi OS (64-bit) "Bookworm", or
# later. The runtime is inside; nothing else is installed.

set -eu

REPO="teapot-chess/Polis"
INSTALL_DIR="/opt/polis"
DATA_DIR="/var/lib/polis"
CONF_DIR="/etc/polis"
SERVICE_USER="polis"

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "install.sh: $*" >&2; exit 1; }

main() {
    lan=0
    wanted=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --lan) lan=1; shift ;;
            --version) wanted="$2"; shift 2 ;;
            -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done

    [ "$(id -u)" = 0 ] || die "run this as root (sudo)."
    [ "$(uname -s)" = Linux ] || die "this installs on Linux. For Windows there is Polis-Setup.exe."
    command -v systemctl >/dev/null 2>&1 || die "this needs systemd, and found none."

    for tool in curl tar sha256sum getent useradd; do
        command -v "$tool" >/dev/null 2>&1 || die "this needs '$tool', which is not installed."
    done

    case "$(uname -m)" in
        x86_64 | amd64) cpu=x86_64 ;;
        aarch64 | arm64) cpu=aarch64 ;;
        armv7l | armv6l) die "this is a 32-bit system ($(uname -m)). Polis is built for 64-bit only: install the 64-bit Raspberry Pi OS." ;;
        *) die "there is no build for this processor ($(uname -m))." ;;
    esac

    # The runtime inside the release was built against glibc 2.35. On an
    # older system it dies at start with a line about GLIBC_2.3x; better to
    # say so here, in words.
    libc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    if [ -n "$libc" ]; then
        major=${libc%%.*}
        minor=${libc#*.}
        minor=${minor%%.*}
        if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 35 ]; }; then
            die "this system's C library is glibc $libc; Polis needs 2.35 or newer (Debian 12, Ubuntu 22.04, Raspberry Pi OS Bookworm)."
        fi
    else
        die "this system does not use glibc (Alpine?). There is no build for it."
    fi

    # A release this script stands in, or one to fetch.
    here=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo "")
    tmp=""
    trap 'if [ -n "$tmp" ]; then rm -rf "$tmp"; fi' EXIT

    if [ -z "$wanted" ] && [ -n "$here" ] && [ -x "$here/bin/polis" ] && [ -r "$here/VERSION" ]; then
        src="$here"
        say "Installing the release in $src."
    else
        file="polis-linux-$cpu.tar.gz"
        if [ -n "$wanted" ]; then
            base="https://github.com/$REPO/releases/download/v$wanted"
        else
            base="https://github.com/$REPO/releases/latest/download"
        fi

        tmp=$(mktemp -d /tmp/polis-install.XXXXXX)
        say "Downloading $base/$file"
        curl -fsSL --retry 2 -o "$tmp/$file" "$base/$file" || die "the download did not succeed."
        curl -fsSL --retry 2 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || die "the checksums could not be downloaded."
        (cd "$tmp" && grep " $file\$" SHA256SUMS | sha256sum -c - >/dev/null 2>&1) ||
            die "the download does not match its checksum."
        tar -xzf "$tmp/$file" -C "$tmp"
        src="$tmp/polis"
    fi

    [ -x "$src/bin/polis" ] || die "that is not a Polis release: no bin/polis in it."

    # The user the service runs as. No shell, no password; its home is the
    # data directory.
    if ! getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --user-group --home-dir "$DATA_DIR" --no-create-home \
            --shell /usr/sbin/nologin "$SERVICE_USER"
    fi

    command -v lp >/dev/null 2>&1 ||
        say "Note: there is no 'lp' on this system. Install CUPS (apt install cups) and add the printer to it; Polis prints through it."

    install -d -o root -g root -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/releases" "$CONF_DIR"
    install -d -o root -g root -m 0755 /var/lib/polis-update
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$DATA_DIR"
    # Where the page leaves its request for an update.
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$DATA_DIR/update"

    # Written once. An installation that is repaired or updated keeps what
    # the arbiter made of it.
    if [ ! -e "$CONF_DIR/polis.env" ]; then
        {
            echo "# Settings of the Polis service. Restart it after a change:"
            echo "#   sudo systemctl restart polis"
            echo "PORT=4061"
            echo ""
            echo "# Who may open the page: only this box (the default), or the hall's"
            echo "# network with POLIS_LISTEN=lan, which then asks for the PIN:"
            echo "#   sudo cat $DATA_DIR/access-pin"
            if [ "$lan" = 1 ]; then
                echo "POLIS_LISTEN=lan"
            else
                echo "#POLIS_LISTEN=lan"
            fi
        } >"$CONF_DIR/polis.env"
        chmod 0644 "$CONF_DIR/polis.env"
    fi

    # The release, the units and the two scripts: update.sh knows how, and
    # is how it is done every time after this one.
    sh "$src/update.sh" --from "$src" --no-restart

    systemctl daemon-reload
    systemctl enable polis.service polis-update.path >/dev/null 2>&1
    systemctl restart polis-update.path
    systemctl restart polis.service

    version=$(tr -d ' \t\r\n' <"$src/VERSION")
    say ""
    say "Polis $version is installed and running."
    say "  The site:    http://localhost:4061 on this box"
    if [ "$lan" = 1 ]; then
        say "               and http://<this box's address>:4061 from the hall's network."
        say "               Those computers are asked for the access PIN (see below)."
    else
        say "               (POLIS_LISTEN=lan in $CONF_DIR/polis.env opens it to the hall's network.)"
    fi
    # There is always a PIN, and a box without a screen has nowhere to show
    # it but here: Polis makes it when it starts, so give it a moment.
    pin=""
    waited=0
    while [ "$waited" -lt 20 ]; do
        if [ -r "$DATA_DIR/access-pin" ]; then
            pin=$(head -n 1 "$DATA_DIR/access-pin" | sed 's/[[:space:]]*$//')
            [ -n "$pin" ] && break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    if [ -n "$pin" ]; then
        say "  Access PIN:  $pin"
    else
        say "  Access PIN:  not made yet; once Polis has started: sudo cat $DATA_DIR/access-pin"
    fi
    say "               Kept in $DATA_DIR/access-pin; change it on the station's page,"
    say "               or before a start with a pin-request file (README)."
    say "  The data:    $DATA_DIR"
    say "  The program: $INSTALL_DIR"
    say "  Its log:     journalctl -u polis"
    say "  Update:      on the page, or: sudo $INSTALL_DIR/update.sh"
    say "  Remove:      sudo $INSTALL_DIR/uninstall.sh   (keeps the data)"
}

main "$@"
