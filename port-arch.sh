#!/bin/sh
# Port of subhashdasyam/KiKAID-A3-linux (cs2549 libfprint driver, USB 2541:2549)
# to Omarchy / Arch Linux, with optional PAM integration for lock screen and sudo.
#
# Usage: sh port-arch.sh fetch|deps|build|install|enroll|pam|status|rollback
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
    # This 112x88 sensor yields few SIFT keypoints; loosen SIGFM acceptance
    # (25 -> 12 keypoints per capture, 5 -> 3 matching pairs) so marginal
    # captures count and matches succeed more often. Trade-off: lower security
    # margin (higher false-accept chance) on an experimental driver.
    sed -i 's/sigfm_keypoints_count (data->sigfm_info) < 25/sigfm_keypoints_count (data->sigfm_info) < 12/' upstream/libfprint/fp-image.c
    sed -i 's/constexpr auto min_match = 5;/constexpr auto min_match = 3;/' upstream/libfprint/sigfm/sigfm.cpp
    echo "[build] SIGFM thresholds loosened (12 keypoints / 3 matching pairs)"
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
    [ "$(id -u)" = 0 ] || { echo "run with sudo: sudo sh port-arch.sh pam" >&2; exit 1; }
    # Omarchy canonical layout (mirrors omarchy-setup-security-fingerprint):
    # sudo/polkit get "lid gate + fingerprint first"; the lock screen detects
    # /etc/pam.d/omarchy-lock-fingerprint and enables its native fingerprint UI.
    # Do NOT add pam_fprintd to the password stacks (omarchy-lock-password /
    # system-auth): the serial PAM flow would block password checks on the
    # fingerprint timeout.
    if ! grep -q pam_fprintd.so /etc/pam.d/sudo; then
        sed -i '1i auth      sufficient pam_fprintd.so' /etc/pam.d/sudo
    fi
    if ! grep -q 'omarchy-hw-laptop-closed' /etc/pam.d/sudo; then
        # Insert immediately before pam_fprintd so success=1 skips exactly it.
        sed -i '/pam_fprintd\.so/i auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed' /etc/pam.d/sudo
    fi
    echo "[pam] /etc/pam.d/sudo configured"
    if [ ! -f /etc/pam.d/polkit-1 ]; then
        tee /etc/pam.d/polkit-1 >/dev/null <<'EOF'
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
auth      required pam_unix.so

account   required pam_unix.so
password  required pam_unix.so
session   required pam_unix.so
EOF
        echo "[pam] /etc/pam.d/polkit-1 created"
    fi
    tee /etc/pam.d/omarchy-lock-fingerprint >/dev/null <<'EOF'
#%PAM-1.0
auth       required                    pam_fprintd.so
account    include                     system-local-login
EOF
    echo "[pam] /etc/pam.d/omarchy-lock-fingerprint created (lock screen fingerprint UI enabled)"
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
    sed -i '/pam_fprintd\.so/d; /omarchy-hw-laptop-closed/d' /etc/pam.d/sudo
    rm -f /etc/pam.d/polkit-1 /etc/pam.d/omarchy-lock-fingerprint
    for f in /etc/pam.d/omarchy-lock-password /etc/pam.d/system-auth; do
        [ -f "$f.pam.bak" ] && cp "$f.pam.bak" "$f" && echo "[rollback] restored $f"
    done
    echo "[rollback] done (distro libfprint and PAM restored)"
    ;;

*)
    echo "Usage: $0 fetch|deps|build|install|enroll|pam|status|rollback" >&2
    exit 2
    ;;
esac
