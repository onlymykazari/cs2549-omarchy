#!/bin/sh
# Port of subhashdasyam/KiKAID-A3-linux (cs2549 libfprint driver, USB 2541:2549)
# to Omarchy / Arch Linux, with optional PAM integration for lock screen and sudo.
#
# Usage: sh port-arch.sh fetch|deps|build|install|enroll|pam [all|lock]|status|rollback
#
# Tested on: Omarchy 4.0.6 (Arch Linux), kernel 7.2.8-9-omarchy, fprintd 1.94.5,
#            OpenCV 5.0.0, glib2 2.90.1, 2026-11.
# Hardware:  MECHREVO Code 01 (TongFang Uniwill PF5NU1G) fingerprint power button,
#            USB 2541:2549 "AB2CD.COM USB FingPintComp" (KiKA/ChipSailing CS2549,
#            match-on-host raw image sensor, 112x88).
set -eu

# Operate relative to this script, so running it under sudo keeps the same context.
cd "$(dirname "$0")"

UP=KiKAID-A3-linux
# Pinned libfprint fork (SIGFM matcher) the upstream project was developed against:
PINNED_FORK_COMMIT=02b285c9703c38d308fbe47a3c566ef1e7f883ca
PINNED_FORK_SHA256=bfa07e5125803c1af6d3eb11e271649e9683781ea9d8f6dc094c331350df50cb
# Upstream driver repo commit this port was tested against:
PINNED_UPSTREAM=986b3341a2f37f433be28d2b430542395ea430ea

case "${1:-}" in
fetch)
    if [ ! -d "$UP" ]; then
        git clone https://github.com/subhashdasyam/KiKAID-A3-linux "$UP"
    fi
    if [ -d "$UP/.git" ]; then
        git -C "$UP" checkout -q "$PINNED_UPSTREAM" 2>/dev/null ||
            echo "[fetch] warning: upstream pin not found, using HEAD"
    fi
    if [ ! -d "$UP/upstream/libfprint/drivers" ]; then
        curl -fsSL "https://api.github.com/repos/archeYR/libfprint-CS9711/tarball/$PINNED_FORK_COMMIT" \
            -o "$UP/libfprint-sigfm-source.tar.gz"
        (cd "$UP" && printf '%s  %s\n' "$PINNED_FORK_SHA256" libfprint-sigfm-source.tar.gz | sha256sum -c -)
        mkdir -p "$UP/upstream"
        tar -xzf "$UP/libfprint-sigfm-source.tar.gz" -C "$UP/upstream" --strip-components=1
    fi
    echo "[fetch] done"
    ;;

deps)
    sudo pacman -S --needed --noconfirm \
        base-devel meson ninja cmake pkgconf \
        glib2 glib2-devel libgusb opencv fprintd usbutils acl
    echo "[deps] done"
    ;;

build)
    cd "$UP"
    [ -d upstream/libfprint/drivers ] || { echo "run 'sh port-arch.sh fetch' first" >&2; exit 1; }
    # Arch has no repo doctest: make sigfm unit tests optional (matcher needs only opencv)
    if ! grep -q "doctest.found()" upstream/libfprint/sigfm/meson.build; then
        sed -i "s/doctest = dependency('doctest', required: true)/doctest = dependency('doctest', required: false)/" upstream/libfprint/sigfm/meson.build
        sed -i "s|^sigfm_tests = executable|if doctest.found()\nsigfm_tests = executable|" upstream/libfprint/sigfm/meson.build
        printf 'endif\n' >> upstream/libfprint/sigfm/meson.build
        echo "[build] sigfm tests made optional (no AUR doctest needed)"
    fi
    # Arch ships OpenCV 5 (opencv5.pc); the fork expects opencv4. Try both names.
    if ! grep -q "opencv4.*opencv5" upstream/libfprint/sigfm/meson.build; then
        sed -i "s/opencv = dependency('opencv4', required: true)/opencv = dependency(['opencv4', 'opencv5'], required: true)/" upstream/libfprint/sigfm/meson.build
        echo "[build] opencv dependency widened to opencv4/opencv5"
    fi
    sh build-driver.sh sigfm
    meson install -C build-sigfm --destdir "$PWD/staging" --no-rebuild
    find staging -name 'libfprint-2.so*'
    echo "[build] done"
    ;;

install)
    [ "$(id -u)" = 0 ] || { echo "run with sudo: sudo sh port-arch.sh install" >&2; exit 1; }
    sh "$UP/install-driver.sh" --check
    sh "$UP/install-driver.sh" --install
    systemctl status fprintd --no-pager -n 5 || true
    echo "[install] done — next: fprintd-enroll -f right-index-finger (as normal user)"
    ;;

enroll)
    fprintd-list "$USER" || true
    echo "Touch the sensor as prompted; lift the finger between samples."
    echo "(Quality retries and USB timeouts are normal with this experimental driver.)"
    fprintd-enroll -f right-index-finger
    fprintd-verify -f right-index-finger
    echo "[enroll] done"
    ;;

pam)
    [ "$(id -u)" = 0 ] || { echo "run with sudo: sudo sh port-arch.sh pam all|lock" >&2; exit 1; }
    line="auth       sufficient                  pam_fprintd.so max-tries=3 timeout=10"
    add_pam() {
        f=$1
        cp -n "$f" "$f.pam.bak" 2>/dev/null || true
        if grep -q pam_fprintd "$f"; then
            echo "[pam] $f already has pam_fprintd"
        else
            # Insert after the faillock preauth line: fingerprint is tried first,
            # password stays as the fallback (sufficient).
            sed -i "/pam_faillock.so preauth/a\\
$line" "$f"
            echo "[pam] added pam_fprintd to $f (backup: $f.pam.bak)"
        fi
    }
    add_pam /etc/pam.d/omarchy-lock-password
    if [ "${2:-all}" = "all" ]; then
        add_pam /etc/pam.d/system-auth
        echo "[pam] sudo/su/login now try fingerprint first (falls back to password)"
        echo "[pam] note: over SSH, sudo waits timeout=10s for the (local) fingerprint first"
    fi
    echo "[pam] done"
    ;;

status)
    lsusb -d 2541:2549 || echo "reader not visible on USB"
    systemctl is-active fprintd || true
    fprintd-list "$USER" || true
    ;;

rollback)
    [ "$(id -u)" = 0 ] || { echo "run with sudo: sudo sh port-arch.sh rollback" >&2; exit 1; }
    rm -rf /opt/libfprint-cs2549 /etc/systemd/system/fprintd.service.d/50-cs2549.conf
    systemctl daemon-reload
    systemctl restart fprintd || true
    for f in /etc/pam.d/omarchy-lock-password /etc/pam.d/system-auth; do
        [ -f "$f.pam.bak" ] && cp "$f.pam.bak" "$f" && echo "[rollback] restored $f"
    done
    echo "[rollback] done (distro libfprint and PAM restored)"
    ;;

*)
    echo "Usage: $0 fetch|deps|build|install|enroll|pam [all|lock]|status|rollback" >&2
    exit 2
    ;;
esac
