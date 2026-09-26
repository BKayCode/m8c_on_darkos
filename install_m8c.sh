#!/bin/bash
# =============================================================================
# m8c Installer für R36S / DarkOS
# - Prüft auf libSDL3.so.0 und installiert ggf. SDL3-sdl2backend
# - installiert m8cr
# - Legt Starter-Skript /opt/system/m8c.sh an
# - Setzt udev-Regel für Teensy 4.1 (Vendor 16c0 / Product 04*) für User "ark"
# =============================================================================

set -euo pipefail

# ----------------------------- Konfiguration ---------------------------------
UDEV_RULE="/etc/udev/rules.d/99-teensy-m8c.rules"
TARGET_USER="ark"

# ----------------------------- Hilfsfunktionen -------------------------------
log()  { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*"; }
die()  { echo -e "\n[✗] $*" >&2; exit 1; }

need_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Needs to be run as root user! (sudo $0)"
    fi
}

# --- HARDWARE-VALIDIERUNG (R36S / RK3326-Plattform) ---
IS_SUPPORTED_HARDWARE=false

# 1. Auslesen des offiziellen Device-Tree-Modells
if [ -f "/proc/device-tree/model" ]; then
    DEVICE_MODEL=$(cat /proc/device-tree/model 2>/dev/null)
    
    # Prüft auf typische R36S / R35S Hardware-Kennungen im Device-Tree
    if echo "$DEVICE_MODEL" | grep -qiE "r36s|r35s|gameconsole|rockchip,rk3326"; then
        IS_SUPPORTED_HARDWARE=true
    fi
fi

# 2. Backup-Prüfung über die CPU-Architektur (falls der Device Tree maskiert ist)
if [ "$IS_SUPPORTED_HARDWARE" = false ] && [ -f "/proc/cpuinfo" ]; then
    # Der R36S nutzt 4x ARM Cortex-A35 Kerne unter einer aarch64/ARMv8-Architektur
    if grep -qi "Features" /proc/cpuinfo && uname -m | grep -qE "aarch64|armv7l"; then
        IS_SUPPORTED_HARDWARE=true
    fi
fi

# Abbruch, wenn es sich offensichtlich um einen x86-PC/Mac oder ein anderes Gerät handelt
if [ "$IS_SUPPORTED_HARDWARE" = false ]; then
    echo "========================================================================"
    echo "NOTICE: Script is running on the wrong device! (Your Computer)"
    echo "========================================================================"
    echo ""
    echo "You have just started this script on your own computer (PC/Mac/Laptop)."
    echo "However, this script can only be executed DIRECTLY on the R36S handheld."
    echo ""
    echo "WHAT YOU NEED TO DO NOW:"
    echo "1. Close this terminal window."
    echo "2. First, connect to your R36S handheld via SSH."
    echo "   (Command: ssh ark@<YOUR-R36S-IP>)"
    echo "3. Once you are successfully logged into the R36S, start the"
    echo "   script there again."
    echo ""
    echo "========================================================================"

    exit 1
fi

install_debs() {
echo "Get Packages..."

#SDL nur holen, wenn /usr/local/lib/libSDL3.so oder /usr/lib/aarch64-linux-gnu/libSDL3.so nicht gefunden
if [ ! -f "/usr/local/lib/libSDL3.so" ] && [ ! -f "/usr/lib/aarch64-linux-gnu/libSDL3.so" ]; then
    echo "libSDL3.so was not found. Install locales Package..."
    wget https://github.com/BKayCode/m8c_on_darkos/raw/refs/heads/main/sdl3-sdl2backend.deb -t 3 -T 60 --waitretry=10 -P /tmp/
    apt-get install -y /tmp/sdl3-sdl2backend.deb
fi

wget https://github.com/BKayCode/m8c_on_darkos/raw/refs/heads/main/m8c_v2.2.3_arm64.deb -t 3 -T 60 --waitretry=10 -P /tmp/
apt install -y /tmp/m8c_v2.2.3_arm64.deb
}

wget https://github.com/BKayCode/m8c_on_darkos/raw/refs/heads/main/config.ini -t 3 -T 60 --waitretry=10 -P /home/ark/.local/share/m8c/

# ----------------------------- 6. Launcher-Skript ----------------------------
create_launcher() {
    log "Creating Launcher..."

    cat > /opt/system/m8c.sh << 'EOF'
#!/bin/bash

# =====================================
# m8c + alsaloop mit Start+Select Exit
# =====================================

EVENT_DEVICE="/dev/input/event2"
START_CODE=704                     # Start
SELECT_CODE=705                    # Select

# --- Cleanup ---
cleanup() {
    echo "Closing m8c and alsaloop..."
    [ -n "$M8C_PID" ] && kill "$M8C_PID" 2>/dev/null
    [ -n "$LOOPBACK_PID" ] && kill "$LOOPBACK_PID" 2>/dev/null
    pkill -f "alsaloop -C hw:M8" 2>/dev/null
    pkill -x m8c 2>/dev/null
    # terminate evtest-process too
    [ -n "$EVTEST_PID" ] && kill "$EVTEST_PID" 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# --- 1. Audio-Loop ---
echo "Starting alsaloop..."
alsaloop -C hw:M8 -P hw:0 -t 50000 -f S16_LE -r 44100 -c 2 &
LOOPBACK_PID=$!
sleep 1

# --- 2. m8c ---
echo "Starting m8c..."
m8c &
M8C_PID=$!

# --- 3. Button-Überwachung mit evtest ---
echo "Monitor Start + Select..."

start_pressed=0
select_pressed=0

# evtest im Hintergrund, Ausgabe zeilenweise lesen
evtest "$EVENT_DEVICE" 2>/dev/null | while read -r line; do
    # Nur KEY-Events interessieren uns
    if [[ $line == *"type 1 (EV_KEY)"* ]]; then
        # Code extrahieren
        if [[ $line =~ code\ ([0-9]+) ]]; then
            code=${BASH_REMATCH[1]}
        else
            continue
        fi

        # Value (1 = press, 0 = release)
        if [[ $line == *"value 1"* ]]; then
            value=1
        elif [[ $line == *"value 0"* ]]; then
            value=0
        else
            continue
        fi

        # Zustände aktualisieren
        if [ "$code" -eq "$START_CODE" ]; then
            start_pressed=$value
        elif [ "$code" -eq "$SELECT_CODE" ]; then
            select_pressed=$value
        fi

        # Beide gleichzeitig gedrückt?
        if [ "$start_pressed" -eq 1 ] && [ "$select_pressed" -eq 1 ]; then
            echo "Start + Select pressed, terminating..."
            # Signal an das Hauptskript senden
            kill -TERM $$ 2>/dev/null
            break
        fi
    fi
done &
EVTEST_PID=$!

# Warten, bis m8c oder der Monitor beendet wird
wait $M8C_PID 2>/dev/null

cleanup
EOF

    chmod +x /opt/system/m8c.sh
    chown ark:ark /opt/system/m8c.sh 2>/dev/null || true
    log "wrote launcher: /opt/system/m8c.sh"
}

# ----------------------------- 7. udev-Regel Teensy 4.1 ----------------------
# Vendor 16c0 (PJRC), Product 04* deckt alle Teensy-Serial/HID-Modi ab
# (inkl. 0483 = Teensyduino Serial, 0478 = HalfKay etc.)
# OWNER = ark, damit der User ohne root/dialout-Gruppe zugreifen kann
setup_udev() {
    log "Set udev-Regel for Teensy 4.1 (Vendor 16c0 / Product 04*) → User ${TARGET_USER}..."

    cat > "${UDEV_RULE}" << EOF
# Teensy 4.1 / M8 Headless – Access for User ark
# Vendor: 16c0 (PJRC), Product: 04* (alle gängigen Teensy-Modi)
ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04*", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"
ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789a]*", ENV{MTP_NO_PROBE}="1"

# tty-Device (Serial) – Owner ark, Rechte 0660
KERNEL=="ttyACM*", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04*", OWNER:="${TARGET_USER}", MODE:="0660", RUN+="/bin/stty -F /dev/%k raw -echo"

# hidraw + USB-Geräte generell
KERNEL=="hidraw*", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04*", OWNER:="${TARGET_USER}", MODE:="0660"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04*", OWNER:="${TARGET_USER}", MODE:="0660"
EOF

    chmod 644 "${UDEV_RULE}"
    udevadm control --reload-rules
    udevadm trigger
    log "udev-Regel aktiv: ${UDEV_RULE}"
    warn "Bitte Teensy einmal ab- und wieder anstecken, damit die Regel greift."
}

cleanup(){
    rm /tmp/m8c_v2.2.3_arm64.deb /tmp/sdl3-sdl2backend.deb
}

# ----------------------------- Hauptablauf -----------------------------------
main() {
    need_root
    log "=== m8c Installer für R36S / DarkOS startet ==="

    install_debs
    create_launcher
    setup_udev
    cleanup
    log "=== Done! ==="
    echo
    echo "  Binary:     /usr/local/bin/m8c"
    echo "  Launcher:   /opt/system/m8c.sh"
    echo "  udev-rule: ${UDEV_RULE}"
    echo
}

main "$@"
