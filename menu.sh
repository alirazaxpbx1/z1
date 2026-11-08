#!/bin/bash
# ==============================================================================
# ALIRAZA SSH Management Panel - one-shot installer
# Created by ALIRAZA | Support: https://t.me/ar_tricks
# Includes: custom Dropbear (SSH-2.0-AliRaza-server), WebSocket proxy, nginx, tuned OpenSSH,
# web panel (accounts, online sessions, banner, themes, Telegram bot), blocked-IP list, watchdog.
# Telegram bot = v3 (public users + referral + channel verification), parallel update handling.
# ==============================================================================
# ----------------------------------------------------------------------------- ALIRAZA installer UI
G='\033[1;92m';R='\033[1;31m';Y='\033[1;93m';N='\033[0m'
C='\033[1;96m';M='\033[1;95m';W='\033[1;97m';D='\033[2m'
LOG=${ALIRAZA_LOG:-/var/log/aliraza-install.log}      # every raw command output goes here, not on screen
IS_TTY=0; [[ -t 1 ]] && IS_TTY=1
TOTAL=6; SPIN_PID=""; STEP_N=0; STEP_LBL=""; STEP_T=0; UI_ON=""; REPLY_V=""
[[ $EUID -ne 0 ]] && { echo -e "${R}✘ Run as root:${N} sudo -i"; exit 1; }
command -v apt-get >/dev/null || { echo -e "${R}✘ Only Debian/Ubuntu (apt) is supported${N}"; exit 1; }

banner() {
  [[ $IS_TTY == 1 ]] && { clear 2>/dev/null || printf '\033c'; }
  local cols; cols=$(tput cols 2>/dev/null || echo 80)
  echo
  if [[ ${cols:-80} -ge 56 ]]; then
    local i=0 col=(51 45 39 33 99 135) l
    while IFS= read -r l; do printf '  \033[1;38;5;%sm%s\033[0m\n' "${col[i]}" "$l"; i=$((i+1)); done <<'ART'
 █████╗ ██╗     ██╗██████╗  █████╗ ███████╗ █████╗ 
██╔══██╗██║     ██║██╔══██╗██╔══██╗╚══███╔╝██╔══██╗
███████║██║     ██║██████╔╝███████║  ███╔╝ ███████║
██╔══██║██║     ██║██╔══██╗██╔══██║ ███╔╝  ██╔══██║
██║  ██║███████╗██║██║  ██║██║  ██║███████╗██║  ██║
╚═╝  ╚═╝╚══════╝╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝
ART
  else
    printf '  %b▀▄▀▄▀▄  %bA L I R A Z A%b  ▄▀▄▀▄▀%b\n' "$C" "$W" "$C" "$N"
  fi
  local w=$(( cols > 54 ? 50 : cols - 4 )); (( w < 10 )) && w=10
  printf '  %b%s%b\n' "$D" "$(printf '%*s' "$w" '' | sed 's/ /─/g')" "$N"
  printf '  %bSSH · VLESS · VMESS · TROJAN   Management Panel%b\n' "$W" "$N"
  printf '  %bby ALIRAZA  ·  t.me/ar_tricks%b\n' "$D" "$N"
}
bad() { printf '  %b✘ %s%b\n' "$R" "$1" "$N"; }
prompt() {   # prompt "Label" "hint" [s=secret]  -> REPLY_V
  local _s=""; [[ "$3" == s ]] && _s=-s
  printf '\n  %b❯ %s%b  %b%s%b\n  %b└─▶%b ' "$W" "$1" "$N" "$D" "$2" "$N" "$C" "$N"
  if { : </dev/tty; } 2>/dev/null; then IFS= read -r $_s REPLY_V </dev/tty || { echo; bad "Input closed"; exit 1; }
  else IFS= read -r $_s REPLY_V || { echo; bad "Input closed"; exit 1; }; fi
  [[ -n "$_s" ]] && echo
  return 0
}
RESERVED=" 22 80 443 109 447 2082 2299 12026 "
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )) && [[ "$RESERVED" != *" $((10#$1)) "* ]]; }

# ---- progress UI (used after all output is redirected to the log; drawn on fd 3 = the real terminal)
_spin() {
  local f=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0
  while :; do printf '\r\033[K  %b%s%b %b[%s/%s]%b %s' "$C" "${f[i%10]}" "$N" "$D" "$1" "$TOTAL" "$N" "$2" >&3; i=$((i+1)); sleep 0.1; done
}
stop_spin() { [[ -n "$SPIN_PID" ]] && { kill "$SPIN_PID" 2>/dev/null; SPIN_PID=""; sleep 0.05; }; return 0; }
start_spin() {
  if [[ $IS_TTY == 1 ]]; then _spin "$STEP_N" "$STEP_LBL" 2>/dev/null & SPIN_PID=$!; disown "$SPIN_PID" 2>/dev/null
  else printf '  ▸ [%s/%s] %s ...\n' "$STEP_N" "$TOTAL" "$STEP_LBL" >&3; fi
}
step_done() {
  [[ $STEP_N -gt 0 ]] || return 0
  stop_spin
  [[ $IS_TTY == 1 ]] && printf '\r\033[K' >&3
  printf '  %b✔%b %b[%s/%s]%b %s %b(%ss)%b\n' "$G" "$N" "$D" "$STEP_N" "$TOTAL" "$N" "$STEP_LBL" "$D" "$(( $(date +%s) - STEP_T ))" "$N" >&3
  STEP_N=0
}
step() { step_done; STEP_N=$1; STEP_LBL=$2; STEP_T=$(date +%s); start_spin; }
uiwarn() {
  local was=$STEP_N; stop_spin
  [[ $IS_TTY == 1 ]] && printf '\r\033[K' >&3
  printf '  %b⚠ %s%b\n' "$Y" "$1" "$N" >&3
  [[ $was -gt 0 && $IS_TTY == 1 ]] && start_spin
  return 0
}
on_exit() {
  local rc=$?; stop_spin
  [[ -n "$UI_ON" ]] || return 0
  [[ $IS_TTY == 1 ]] && printf '\033[?25h' >&3 2>/dev/null
  if (( rc != 0 )); then
    [[ $IS_TTY == 1 ]] && printf '\r\033[K' >&3
    printf '\n  %b✘ Installation stopped%b  (step %s/%s: %s)\n' "$R" "$N" "$STEP_N" "$TOTAL" "$STEP_LBL" >&3
    printf '  %bLast log lines — full log: %s%b\n' "$D" "$LOG" "$N" >&3
    tail -n 12 "$LOG" 2>/dev/null | cut -c1-110 | sed 's/^/    /' >&3
    printf '\n  %bFix the problem and run the installer again.  Support: https://t.me/ar_tricks%b\n\n' "$Y" "$N" >&3
  fi
}

# ---- interactive setup
banner
printf '\n  %b▌ SETUP%b  %b— answer a few quick questions%b\n' "$M" "$N" "$D" "$N"
while :; do
  prompt "Domain" "A record must point to this VPS   e.g. vpn.example.com"
  DOMAIN=${REPLY_V//[[:space:]]/}
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] && break
  bad "Invalid domain (letters, numbers, dots and dashes only)"
done
while :; do
  prompt "Panel port" "default 2083"
  PP=${REPLY_V//[[:space:]]/}; PP=${PP:-2083}
  valid_port "$PP" && { PP=$((10#$PP)); break; }
  bad "Invalid or reserved port  (reserved: 22 80 443 109 447 2082 2299 12026)"
done
while :; do
  prompt "SSH port" "default 8443"
  SP=${REPLY_V//[[:space:]]/}; SP=${SP:-8443}
  if ! valid_port "$SP"; then bad "Invalid or reserved port  (reserved: 22 80 443 109 447 2082 2299 12026)"; continue; fi
  SP=$((10#$SP))
  [[ "$SP" != "$PP" ]] && break
  bad "SSH port must differ from the panel port"
done
while :; do
  prompt "Admin username" "default admin"
  AU=${REPLY_V//[[:space:]]/}; AU=${AU:-admin}
  [[ "$AU" != *:* ]] && break
  bad "Username cannot contain ':'"
done
prompt "Admin password" "leave blank to generate a strong one" s
AP=$REPLY_V; PW_NOTE="(hidden)"
[[ -z "$AP" ]] && { AP=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12); PW_NOTE="(auto-generated)"; }
printf '\n  %b▌ REVIEW%b\n' "$M" "$N"
printf '   %b%-14s%b %b%s%b\n' "$D" "Domain" "$N" "$W" "$DOMAIN" "$N"
printf '   %b%-14s%b %b%s%b\n' "$D" "Panel port" "$N" "$W" "$PP" "$N"
printf '   %b%-14s%b %b%s%b\n' "$D" "SSH port" "$N" "$W" "$SP  (+109, 447)" "$N"
printf '   %b%-14s%b %b%s%b\n' "$D" "Admin user" "$N" "$W" "$AU" "$N"
printf '   %b%-14s%b %b%s%b\n' "$D" "Password" "$N" "$W" "$PW_NOTE" "$N"
prompt "Start installation?" "press Enter to continue · type n to cancel"
[[ "${REPLY_V,,}" == n* ]] && { printf '\n  %bCancelled.%b\n\n' "$Y" "$N"; exit 0; }

# ---- from here on nothing is printed raw: all output -> log, UI -> fd 3
printf '\n  %b▶ Installing ALIRAZA panel%b  %b(details: %s)%b\n\n' "$W" "$N" "$D" "$LOG" "$N"
mkdir -p "$(dirname "$LOG")"; : >"$LOG"; chmod 600 "$LOG"
exec 3>&1
exec >>"$LOG" 2>&1
UI_ON=1
trap on_exit EXIT
trap 'exit 130' INT TERM
[[ $IS_TTY == 1 ]] && printf '\033[?25l' >&3
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
# apt: wait up to 5 min for the dpkg lock (fresh VPS runs unattended-upgrades at first boot), retry flaky mirrors, never stop on config-file prompts
APT=(apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
step 1 "Installing system packages"
("${APT[@]}" update -y || "${APT[@]}" update -y) && "${APT[@]}" install -y curl wget jq openssl nginx dropbear certbot python3 python3-venv python3-pip python3-dev lsof iptables iproute2 net-tools psmisc build-essential zlib1g-dev bzip2 ca-certificates logrotate || { echo -e "${R}Package install failed - check internet/apt and re-run${N}"; exit 1; }
mkdir -p /etc/artricks/users /etc/artricks/ssl /opt/aliraza-panel
"${APT[@]}" install -y python3-uvloop >/dev/null 2>&1 || true
"${APT[@]}" install -y irqbalance >/dev/null 2>&1 && systemctl enable --now irqbalance >/dev/null 2>&1 || true   # spreads NIC interrupts over all cores   # optional: faster WebSocket proxy (falls back to plain asyncio)
# ---- AliRaza banner: kept in its OWN file so OS updates / re-running this installer never reset what you saved in the panel ----
BANNER_FILE=/etc/artricks/banner.txt
BANNER_MARK=/etc/artricks/.banner_set   # new SERVER BY ALIRAZA banner is applied ONCE; afterwards whatever you save in the panel is kept
write_default_banner() { cat > "$BANNER_FILE" <<'BN'
<font color="#FF0000">𝗦𝗘𝗥𝗩𝗘𝗥 <font color="#FF0000">𝗕𝗬</font> 𝗔𝗟𝗜𝗥𝗔𝗭𝗔</font>

<font color="#00FFFF">🌐 𝗦𝗦𝗛</font>  •  <font color="#00FF00">𝗩𝗟𝗘𝗦𝗦</font>
<font color="#FF1493">⚡ 𝗩𝗠𝗘𝗦</font> • <font color="#FFFF00">𝗧𝗥𝗢𝗝𝗔𝗡</font><font color="#FF0000">🔥</font>

<font color="#FF8C00">📢 𝗝𝗢𝗜𝗡 𝗖𝗛𝗔𝗡𝗘𝗟</font>
<font color='#00FF00'>↓ <a href="https://t.me/ar_tricks">CLICK HERE</a> ↓</font>
BN
}
compgen -G '/etc/artricks/.banner_v*' >/dev/null && touch "$BANNER_MARK"   # older installs: keep the banner you saved
if [[ ! -f "$BANNER_MARK" ]] || [[ ! -s "$BANNER_FILE" ]]; then
  write_default_banner
  touch "$BANNER_MARK"
fi
chmod 644 "$BANNER_FILE"
# ---- OpenSSH tuning (stability + speed) ----
sed -i 's|^Banner /etc/issue.net$|Banner /etc/artricks/banner.txt|' /etc/ssh/sshd_config 2>/dev/null   # migrate old installs
if [[ -f /etc/ssh/sshd_config ]]; then
SSHD_TUNE='# ALIRAZA tuning
Banner /etc/artricks/banner.txt
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 6
UseDNS no
GSSAPIAuthentication no
Compression no
LoginGraceTime 30
MaxStartups 100:30:200
MaxSessions 100
IPQoS lowdelay throughput
MaxAuthTries 4
PrintMotd no
PrintLastLog no
X11Forwarding no
PermitUserEnvironment no'
if [[ -d /etc/ssh/sshd_config.d ]] && grep -qiE '^\s*Include\s+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config; then
  printf '%s\n' "$SSHD_TUNE" > /etc/ssh/sshd_config.d/00-aliraza.conf; SSHD_MODE=dropin
else
  cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.aliraza.bak
  grep -q 'ALIRAZA tuning' /etc/ssh/sshd_config || printf '\n%s\n' "$SSHD_TUNE" >> /etc/ssh/sshd_config; SSHD_MODE=inline
fi
if command -v sshd >/dev/null && ! sshd -t 2>/dev/null; then
  echo -e "${R}sshd config test failed - reverting SSH tuning${N}"
  rm -f /etc/ssh/sshd_config.d/00-aliraza.conf
  [[ -f /etc/ssh/sshd_config.aliraza.bak ]] && cp /etc/ssh/sshd_config.aliraza.bak /etc/ssh/sshd_config
fi
fi
# ---- OpenSSH extra speed layer (CPU-aware cipher order, no forced re-key, trimmed forwarding). Own file, auto-reverted if sshd -t fails ----
if command -v sshd >/dev/null && [[ -f /etc/ssh/sshd_config ]]; then
  if grep -qw aes /proc/cpuinfo 2>/dev/null; then _CIPH='aes128-gcm@openssh.com,chacha20-poly1305@openssh.com'; else _CIPH='chacha20-poly1305@openssh.com,aes128-gcm@openssh.com'; fi
  SSHD_SPEED="# ALIRAZA speed layer
Ciphers ^${_CIPH}
KexAlgorithms ^curve25519-sha256,curve25519-sha256@libssh.org
RekeyLimit 4G 1d
AllowAgentForwarding no
AllowStreamLocalForwarding no"
  rm -f /etc/ssh/sshd_config.d/01-aliraza-v[0-9]*.conf 2>/dev/null   # leftovers of older installs
  if [[ "${SSHD_MODE:-}" == dropin ]]; then
    printf '%s\n' "$SSHD_SPEED" > /etc/ssh/sshd_config.d/01-aliraza-speed.conf
    sshd -t 2>/dev/null || { echo -e "${Y}sshd speed layer not supported here - skipped${N}"; rm -f /etc/ssh/sshd_config.d/01-aliraza-speed.conf; }
  else
    cp -f /etc/ssh/sshd_config /etc/ssh/sshd_config.pre
    grep -q 'ALIRAZA speed layer' /etc/ssh/sshd_config || printf '\n%s\n' "$SSHD_SPEED" >> /etc/ssh/sshd_config
    sshd -t 2>/dev/null || { echo -e "${Y}sshd speed layer not supported here - skipped${N}"; cp -f /etc/ssh/sshd_config.pre /etc/ssh/sshd_config; }
  fi
  for _u in ssh sshd; do
    if systemctl cat "$_u" >/dev/null 2>&1; then
      mkdir -p "/etc/systemd/system/$_u.service.d"
      printf '[Service]\nLimitNOFILE=1048576\nTasksMax=infinity\nOOMScoreAdjust=-500\nNice=-3\n' > "/etc/systemd/system/$_u.service.d/aliraza.conf"
      break
    fi
  done
  systemctl daemon-reload 2>/dev/null
fi
# optional OpenSSH options, each one tested alone (unsupported ones on older OpenSSH are simply skipped)
if command -v sshd >/dev/null && [[ "${SSHD_MODE:-}" == dropin ]]; then
  _EXTRA=/etc/ssh/sshd_config.d/02-aliraza-extra.conf; : > "$_EXTRA"
  for _o in "PerSourcePenalties no"; do
    echo "$_o" >> "$_EXTRA"
    sshd -t 2>/dev/null || { sed -i "\|^${_o}\$|d" "$_EXTRA"; }
  done
  [[ -s "$_EXTRA" ]] || rm -f "$_EXTRA"
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

# ---- Build Dropbear with custom identification: SSH-2.0-AliRaza-server ----
step 2 "Tuning network & building the ALIRAZA SSH engine"
build_dropbear() {
  local IDENT="SSH-2.0-AliRaza-server" W=/tmp/aliraza-dropbear LOG=/var/log/aliraza-dropbear-build.log v ok=0
  rm -rf "$W"; mkdir -p "$W"; cd "$W" || return 1
  local LATEST
  LATEST=$( { curl -fsSL -m 20 https://matt.ucc.asn.au/dropbear/ 2>/dev/null; curl -fsSL -m 20 "https://api.github.com/repos/mkj/dropbear/tags?per_page=30" 2>/dev/null; } | grep -oE '(dropbear-|DROPBEAR_)20[0-9]{2}\.[0-9]{2,3}' | grep -oE '20[0-9]{2}\.[0-9]{2,3}' | sort -uV | tail -n 6 | sort -rV | tr '\n' ' ')
  for v in $LATEST 2026.94 2026.93 2026.92 2026.91 2026.90 2025.89 2025.88 2024.86; do
    wget -q -T 25 -O db.tar.bz2 "https://matt.ucc.asn.au/dropbear/releases/dropbear-$v.tar.bz2" \
    || wget -q -T 25 -O db.tar.bz2 "https://github.com/mkj/dropbear/archive/refs/tags/DROPBEAR_$v.tar.gz" || continue
    rm -rf src; mkdir src; tar -xf db.tar.bz2 -C src --strip-components=1 2>/dev/null || tar -xzf db.tar.bz2 -C src --strip-components=1 2>/dev/null || continue
    [[ -f src/configure ]] && ok=1 && break
  done
  [[ $ok -eq 1 ]] || { echo "download failed"; return 1; }
  cd src || return 1
  # Dropbear >= 2025.87 keeps its headers in src/, older releases in the top folder: locate them
  local HD; HD=$(dirname "$(find . -name sysoptions.h 2>/dev/null | head -1)")
  [[ -f "$HD/sysoptions.h" ]] || { echo "sysoptions.h not found"; return 1; }
  printf '#define DROPBEAR_SMALL_CODE 0\n' > localoptions.h
  # force the custom identification directly in sysoptions.h (whitespace tolerant), then verify
  sed -i -E "s|^[[:space:]]*#[[:space:]]*define[[:space:]]+LOCAL_IDENT[[:space:]].*|#define LOCAL_IDENT \"$IDENT\"|" "$HD/sysoptions.h"
  grep -q "LOCAL_IDENT \"$IDENT\"" "$HD/sysoptions.h" || { echo "ident patch failed: $(grep -n LOCAL_IDENT "$HD/sysoptions.h" | head -2)"; return 1; }
  sed -i 's|^#define DROPBEAR_SMALL_CODE .*|#define DROPBEAR_SMALL_CODE 0|; s|^#define MAX_UNAUTH_CLIENTS .*|#define MAX_UNAUTH_CLIENTS 500|' "$HD/default_options.h" "$HD/options.h" 2>/dev/null
  # every WS user reaches Dropbear from 127.0.0.1, so the per-IP cap is really a GLOBAL cap: keep it high
  sed -i 's|^#define MAX_UNAUTH_PER_IP .*|#define MAX_UNAUTH_PER_IP 1000|' "$HD/default_options.h" 2>/dev/null
  # bigger default receive window + legacy-client key exchange (both are no-ops if the option does not exist in this release)
  sed -i 's|^#define DEFAULT_RECV_WINDOW .*|#define DEFAULT_RECV_WINDOW (64*1024*1024)|' "$HD/default_options.h" "$HD/options.h" 2>/dev/null
  # raise the hard cap of the -W window option (stock = 10MB) so the runtime window can be much bigger
  sed -i -E 's|^[[:space:]]*#[[:space:]]*define[[:space:]]+MAX_RECV_WINDOW[[:space:]].*|#define MAX_RECV_WINDOW (64*1024*1024)|' "$HD/sysoptions.h" "$HD/default_options.h" "$HD/options.h" 2>/dev/null
  local MAXWIN=0
  grep -qE '^#define MAX_RECV_WINDOW \(64\*1024\*1024\)' "$HD/sysoptions.h" 2>/dev/null && MAXWIN=67108864
  # bigger packet payload = fewer packets per MB (less CPU, same latency); only touched when the macro exists
  sed -i -E 's|^#define RECV_MAX_PAYLOAD_LEN .*|#define RECV_MAX_PAYLOAD_LEN 65536|' "$HD/sysoptions.h" 2>/dev/null
  sed -i 's|^#define DROPBEAR_DH_GROUP1 .*|#define DROPBEAR_DH_GROUP1 1|' "$HD/default_options.h" 2>/dev/null
  # listen() backlog of 20 overflows when many users reconnect together (-> dropped/slow connects): raise it
  find . \( -name netio.c -o -name svr-main.c \) -print0 2>/dev/null | xargs -0 -r sed -i -E 's/listen\(([A-Za-z_]+), *20\)/listen(\1, 1024)/' 2>/dev/null
  # never force a re-key (every 1h / 1GB): some mobile SSH clients freeze or drop during re-key
  sed -i 's|^#define KEX_REKEY_TIMEOUT .*|#define KEX_REKEY_TIMEOUT (3600*24*30)|; s|^#define KEX_REKEY_DATA .*|#define KEX_REKEY_DATA 4294967295U|' "$HD/sysoptions.h" 2>/dev/null
  # drop features tunnel clients never use (agent/X11 forwarding, motd); no-op if the option is absent
  sed -i 's|^#define DROPBEAR_SVR_AGENTFWD .*|#define DROPBEAR_SVR_AGENTFWD 0|; s|^#define DROPBEAR_X11FWD .*|#define DROPBEAR_X11FWD 0|; s|^#define DO_MOTD .*|#define DO_MOTD 0|' "$HD/default_options.h" "$HD/options.h" 2>/dev/null
  : > "$LOG"
  # no utmp/wtmp/lastlog writes (faster logins, no ever-growing wtmp); -O3 build; bundled crypto
  ./configure --prefix=/usr/local --enable-bundled-libtom --disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx --disable-loginfunc --disable-zlib CFLAGS="-O3 -pipe -fomit-frame-pointer -fno-plt" LDFLAGS="-Wl,-O1,--as-needed" >>"$LOG" 2>&1 || { echo "configure failed (see $LOG)"; return 1; }
  make -j"$(nproc)" PROGRAMS="dropbear dropbearkey" >>"$LOG" 2>&1 || { echo "compile failed (see $LOG)"; return 1; }
  grep -aq "$IDENT" dropbear || { echo "ident check failed"; return 1; }
  # smoke test: the new binary must start and announce the custom identification before it is installed
  ./dropbearkey -t ed25519 -f "$W/test_key" >/dev/null 2>&1 || { echo "keygen failed"; return 1; }
  ./dropbear -F -E -r "$W/test_key" -p 127.0.0.1:22999 -W "$((MAXWIN>0?MAXWIN:1048576))" >/dev/null 2>&1 &
  local DP=$! BL
  sleep 1
  BL=$(timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22999; head -n1 <&3' 2>/dev/null | tr -d '\r')
  kill "$DP" 2>/dev/null; wait "$DP" 2>/dev/null
  [[ "$BL" == "$IDENT" ]] || { echo "smoke test failed (got: ${BL:-nothing})"; return 1; }
  install -m 755 dropbear /usr/local/sbin/dropbear
  mkdir -p /etc/artricks; echo "$MAXWIN" > /etc/artricks/dbmaxwin
  /usr/local/sbin/dropbear -V 2>&1 | head -n1 > /etc/artricks/dbversion 2>/dev/null
  echo "built dropbear $v, max window ${MAXWIN}"
}
# compile in the background (CPU-bound) while the network-bound steps below run; joined right before Dropbear is configured
DB_OUT=/tmp/aliraza-db-build.out
( build_dropbear ) >"$DB_OUT" 2>&1 &
DB_PID=$!
# later you can update Dropbear alone with:  bash /usr/local/bin/aliraza-dbupdate.sh
{ echo '#!/bin/bash'; echo '[[ $EUID -ne 0 ]] && { echo "run as root"; exit 1; }'; declare -f build_dropbear
  echo 'cd /root 2>/dev/null || cd /'
  echo 'if ( build_dropbear ); then systemctl restart dropbear aliraza-ban-ssh 2>/dev/null; echo "Dropbear updated: $(cat /etc/artricks/dbversion 2>/dev/null)"; else echo "Update failed, current Dropbear kept. Log: /var/log/aliraza-dropbear-build.log"; fi'
} > /usr/local/bin/aliraza-dbupdate.sh
chmod +x /usr/local/bin/aliraza-dbupdate.sh
cd /root 2>/dev/null || cd /
# nginx: more connections (safe - reverted if nginx -t fails)
if [[ -f /etc/nginx/nginx.conf ]]; then
  cp -n /etc/nginx/nginx.conf /etc/nginx/nginx.conf.aliraza.bak
  grep -q worker_rlimit_nofile /etc/nginx/nginx.conf || sed -i '1i worker_rlimit_nofile 524288;' /etc/nginx/nginx.conf
  sed -i -E 's/^worker_rlimit_nofile[[:space:]]+[0-9]+;/worker_rlimit_nofile 524288;/' /etc/nginx/nginx.conf
  sed -i 's/worker_connections [0-9]*;/worker_connections 16384;/' /etc/nginx/nginx.conf
  sed -i -E 's/^[[:space:]]*worker_processes[[:space:]].*/worker_processes auto;/' /etc/nginx/nginx.conf
  grep -q worker_cpu_affinity /etc/nginx/nginx.conf || sed -i '1i worker_cpu_affinity auto;' /etc/nginx/nginx.conf
  sed -i -E 's|^error_log .*|error_log /var/log/nginx/error.log crit;|' /etc/nginx/nginx.conf
  nginx -t >/dev/null 2>&1 || cp /etc/nginx/nginx.conf.aliraza.bak /etc/nginx/nginx.conf
fi
# nginx http-level tuning (reverted automatically if nginx -t fails)
cat > /etc/nginx/conf.d/00-aliraza-tune.conf <<'NT'
tcp_nodelay on;
tcp_nopush on;
reset_timedout_connection on;
keepalive_timeout 120s;
keepalive_requests 10000;
server_tokens off;
ssl_session_cache shared:SSL:20m;
ssl_session_timeout 1d;
ssl_session_tickets on;
ssl_buffer_size 4k;
access_log off;
gzip off;
sendfile on;
server_names_hash_bucket_size 128;
client_header_timeout 15s;
client_body_timeout 30s;
large_client_header_buffers 4 16k;
client_body_buffer_size 1m;
proxy_buffer_size 16k;
proxy_buffers 8 16k;
proxy_connect_timeout 5s;
proxy_next_upstream off;
NT
nginx -t >/dev/null 2>&1 || rm -f /etc/nginx/conf.d/00-aliraza-tune.conf
# optional extras: each line is kept only if this nginx build accepts it (nginx -t), otherwise it is dropped silently
if [[ -f /etc/nginx/conf.d/00-aliraza-tune.conf ]]; then
  _ngopt() { cp /etc/nginx/conf.d/00-aliraza-tune.conf /tmp/.aliraza-ng.bak; echo "$1" >> /etc/nginx/conf.d/00-aliraza-tune.conf; nginx -t >/dev/null 2>&1 || cp /tmp/.aliraza-ng.bak /etc/nginx/conf.d/00-aliraza-tune.conf; }
  _ngopt 'proxy_socket_keepalive on;'
  _ngopt 'ssl_early_data on;'
  _ngopt 'resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;'
  _ngopt 'resolver_timeout 3s;'
  _ngopt 'ssl_stapling on;'
  _ngopt 'ssl_stapling_verify on;'
  nginx -V 2>&1 | grep -q -- --with-threads && _ngopt 'aio threads;'
  rm -f /tmp/.aliraza-ng.bak; unset -f _ngopt
fi
if [[ -f /etc/nginx/nginx.conf ]] && ! grep -Eq '^\s*multi_accept on' /etc/nginx/nginx.conf; then
  sed -i '0,/worker_connections 16384;/s//worker_connections 16384;\n    multi_accept on;\n    use epoll;/' /etc/nginx/nginx.conf
  nginx -t >/dev/null 2>&1 || cp /etc/nginx/nginx.conf.aliraza.bak /etc/nginx/nginx.conf
fi
# keep logs from filling the disk
cat > /etc/logrotate.d/aliraza <<'LR'
/var/log/ws-proxy.log {
    weekly
    rotate 2
    size 20M
    missingok
    notifempty
    copytruncate
    compress
}
LR
mkdir -p /etc/systemd/journald.conf.d && printf '[Journal]\nSystemMaxUse=200M\nRateLimitIntervalSec=0\n' > /etc/systemd/journald.conf.d/aliraza.conf
systemctl restart systemd-journald 2>/dev/null
# ---- swap: avoids OOM-kills (random disconnects) on small VPS ----
if [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]]; then
  MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')
  if [[ $MEM_MB -le 2048 && $FREE_MB -gt 4096 ]]; then
    if { fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; } \
       && chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      echo -e "${G}1G swap enabled${N}"
    else
      rm -f /swapfile
    fi
  fi
fi
# ---- file-descriptor limits ----
cat > /etc/security/limits.d/99-aliraza.conf <<'LIM'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIM
mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nDefaultLimitNOFILE=1048576\n' > /etc/systemd/system.conf.d/aliraza.conf
# ---- nginx: auto-restart + limits ----
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/aliraza.conf <<'NGD'
[Unit]
StartLimitIntervalSec=0
[Service]
Restart=always
RestartSec=2
LimitNOFILE=1048576
OOMScoreAdjust=-300
NGD
# core services (WebSocket, auto-kill, tuning)
cat > /etc/sysctl.d/99-artricks-ssh.conf <<'SYSCTL_EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 60
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_orphan_retries = 3
net.core.somaxconn = 131072
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 6

# 🚀 EXTREME SPEED TUNING (Read/Write Buffers) - baseline 256MB, scaled down by RAM below
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 268435456
net.ipv4.tcp_wmem = 4096 1048576 268435456
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1

# Stability / many connections
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_tw_buckets = 500000
net.core.netdev_max_backlog = 32768
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.ip_local_reserved_ports = 12026
fs.file-max = 2097152
fs.nr_open = 2097152

# Latency / stability extras
net.ipv4.tcp_notsent_lowat = 524288
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_max_orphans = 32768
net.core.optmem_max = 131072
kernel.pid_max = 4194304
vm.swappiness = 1
vm.vfs_cache_pressure = 200

# Extras (unknown keys on older/newer kernels are skipped)
net.ipv4.tcp_limit_output_bytes = 4194304
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_recovery = 1
net.core.netdev_budget = 1200

# Extras
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_frto = 2
net.core.netdev_budget_usecs = 16000
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 8192
vm.dirty_ratio = 10
vm.dirty_background_ratio = 2

# Extras
kernel.sched_autogroup_enabled = 0

# Extras
vm.overcommit_memory = 1
SYSCTL_EOF
# window size is RAM-adaptive (file baseline = 256MB): <1.5GB RAM = 64MB ceiling, <3.5GB = 128MB, bigger = 256MB (autotuned, only used under load)
_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if [[ ${_MB:-0} -lt 1500 ]]; then sed -i 's/268435456/67108864/g' /etc/sysctl.d/99-artricks-ssh.conf; elif [[ ${_MB:-0} -lt 3500 ]]; then sed -i 's/268435456/134217728/g' /etc/sysctl.d/99-artricks-ssh.conf; fi
modprobe tcp_bbr 2>/dev/null; echo tcp_bbr > /etc/modules-load.d/bbr.conf
# BBR needs kernel support (not on OpenVZ/LXC): fall back to cubic instead of leaving a broken setting
grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || sed -i 's/= bbr$/= cubic/' /etc/sysctl.d/99-artricks-ssh.conf
sysctl -e -p /etc/sysctl.d/99-artricks-ssh.conf &>/dev/null
echo -e "${G}TCP congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) | qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null) | max window: $(sysctl -n net.core.rmem_max 2>/dev/null) bytes${N}"
# conntrack table full = packets silently dropped = random disconnects under load (only if conntrack is active)
cat > /usr/local/bin/aliraza-conntrack.sh <<'CT'
#!/bin/sh
# ALIRAZA runtime tuning (qdisc, NIC, IRQ spread, CPU governor, THP, conntrack). Every step is best-effort: OpenVZ/LXC just skip it.
ifc=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
if [ -n "$ifc" ]; then
  # --- B) qdisc: cake > fq_codel > fq ---
  if command -v tc >/dev/null 2>&1; then
    if tc qdisc replace dev "$ifc" root cake bandwidth 1gbit besteffort triple-isolate nat wash ingress 2>/dev/null; then :
    elif tc qdisc replace dev "$ifc" root fq_codel quantum 300 2>/dev/null; then :
    elif tc qdisc show dev "$ifc" root 2>/dev/null | grep -qE 'qdisc (fq_codel|pfifo_fast)'; then
      tc qdisc replace dev "$ifc" root fq 2>/dev/null
    fi
  fi
  # --- C) NIC tuning ---
  if command -v ethtool >/dev/null 2>&1; then
    ethtool -G "$ifc" rx 4096 tx 4096 2>/dev/null
    ethtool -K "$ifc" gro on gso on tso on 2>/dev/null
    ethtool -K "$ifc" rx-udp-gro-forwarding on 2>/dev/null
  fi
  ip link set dev "$ifc" txqueuelen 10000 2>/dev/null
fi
# IRQ spread: rotate every IRQ over the CPUs
ncpu=$(nproc 2>/dev/null || echo 1); n=0
for f in /proc/irq/*/smp_affinity_list; do
  [ -w "$f" ] || continue
  echo $((n % ncpu)) > "$f" 2>/dev/null
  n=$((n+1))
done
# --- D) CPU governor + transparent hugepages ---
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$g" ] && echo performance > "$g" 2>/dev/null; done
echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
[ -e /proc/sys/net/netfilter/nf_conntrack_max ] || exit 0
mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
want=262144; [ "$mem" -gt 2048 ] && want=524288
cur=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
[ "$cur" -lt "$want" ] && sysctl -qw net.netfilter.nf_conntrack_max=$want
[ -w /sys/module/nf_conntrack/parameters/hashsize ] && echo $((want/4)) > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null
# default established timeout is 5 days: dead tunnels would fill the table. 2h is safe (keepalives are 15-60s)
[ -e /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established ] && sysctl -qw net.netfilter.nf_conntrack_tcp_timeout_established=7200 net.netfilter.nf_conntrack_tcp_timeout_time_wait=30 net.netfilter.nf_conntrack_tcp_timeout_close_wait=30 net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30 2>/dev/null
exit 0
CT
chmod +x /usr/local/bin/aliraza-conntrack.sh
# C) tune_nic: best-effort NIC/IRQ/CPU tuning now + persisted (the same script runs at every boot from aliraza-tune.service)
tune_nic() {
  command -v ethtool >/dev/null 2>&1 || { apt-get install -y -qq ethtool >/dev/null 2>&1 || true; }
  local ifc; ifc=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  [[ -n "$ifc" ]] || return 0
  modprobe sch_cake 2>/dev/null; modprobe sch_fq_codel 2>/dev/null
  echo -e "${G}NIC tuning on $ifc (best effort)${N}"
  return 0
}
tune_nic || true
cat > /etc/systemd/system/aliraza-tune.service <<'TU'
[Unit]
Description=ALIRAZA runtime tuning (qdisc, NIC, IRQ, CPU governor, THP, conntrack)
After=network-online.target ufw.service netfilter-persistent.service nftables.service
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/aliraza-conntrack.sh
[Install]
WantedBy=multi-user.target
TU
/usr/local/bin/aliraza-conntrack.sh
# ---- Blocked IPs get a notice (never a login) ----
BAN_BANNER=/etc/artricks/ban_banner.txt
if [[ ! -s "$BAN_BANNER" ]]; then
cat > "$BAN_BANNER" <<'BANBN'
<font color="#FF0000">🚫 𝗬𝗢𝗨 𝗛𝗔𝗩𝗘 𝗕𝗘𝗘𝗡 𝗕𝗔𝗡𝗡𝗘𝗗 𝗕𝗬 𝗔𝗟𝗜𝗥𝗔𝗭𝗔</font>

<font color="#FFFF00">First apologize for your mistake,</font>
<font color="#00FF00">and then enjoy.</font>

<font color="#00FFFF">Contact: <a href="https://t.me/alirazax0">t.me/alirazax0</a></font>
BANBN
fi
chmod 644 "$BAN_BANNER"
touch /etc/artricks/banned.txt; chmod 644 /etc/artricks/banned.txt
cat > /usr/local/bin/aliraza-ban.sh <<'BANSH'
#!/bin/bash
# Rebuilds the ALIRAZA_BAN nat chain from /etc/artricks/banned.txt (one line per IP: ip<TAB>time<TAB>note).
# Blocked IPs hitting the SSH ports are redirected to the notice-only SSH server (port 2299).
CF=/etc/artricks/panel.json; BF=/etc/artricks/banned.txt; BP=2299
SP=$(jq -r '.ssh_port // 8443' "$CF" 2>/dev/null); [[ "$SP" =~ ^[0-9]+$ ]] || SP=8443
PORTS="22,109,447,$SP"
for T in iptables ip6tables; do
  command -v $T >/dev/null 2>&1 || continue
  $T -t nat -N ALIRAZA_BAN 2>/dev/null
  $T -t nat -F ALIRAZA_BAN 2>/dev/null
  $T -t nat -C PREROUTING -j ALIRAZA_BAN 2>/dev/null || $T -t nat -I PREROUTING 1 -j ALIRAZA_BAN 2>/dev/null
done
[[ -s "$BF" ]] || exit 0
while IFS=$'\t' read -r ip ts note; do
  [[ -z "$ip" ]] && continue
  if [[ "$ip" == *:* ]]; then T=ip6tables; else T=iptables; fi
  command -v $T >/dev/null 2>&1 || continue
  $T -t nat -A ALIRAZA_BAN -s "$ip" -p tcp -m multiport --dports "$PORTS" -j REDIRECT --to-ports $BP 2>/dev/null
done < "$BF"
exit 0
BANSH
chmod +x /usr/local/bin/aliraza-ban.sh
cat > /usr/local/bin/aliraza-ban-ssh.sh <<'BANSSH'
#!/bin/sh
# Notice-only SSH server: shows the ban banner, password login disabled, one auth try, short idle timeout.
B=/usr/local/sbin/dropbear; [ -x "$B" ] || B=/usr/sbin/dropbear
set --
for k in rsa ecdsa ed25519; do [ -f "/etc/dropbear/dropbear_${k}_host_key" ] && set -- "$@" -r "/etc/dropbear/dropbear_${k}_host_key"; done
exec "$B" -F -s -w -j -k -T 1 -I 20 -K 10 -p 2299 -b /etc/artricks/ban_banner.txt "$@"
BANSSH
chmod +x /usr/local/bin/aliraza-ban-ssh.sh
cat > /etc/systemd/system/aliraza-ban-ssh.service <<'BANSVC'
[Unit]
Description=ALIRAZA ban notice SSH (shows the ban message, never allows login)
After=network.target dropbear.service
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/local/bin/aliraza-ban-ssh.sh
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
BANSVC
cat > /etc/systemd/system/aliraza-ban.service <<'BANRULES'
[Unit]
Description=ALIRAZA blocked-IP firewall rules
After=network.target ufw.service netfilter-persistent.service nftables.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/aliraza-ban.sh
[Install]
WantedBy=multi-user.target
BANRULES
cat > /usr/local/bin/aliraza-watchdog.sh <<'WD'
#!/bin/bash
# ALIRAZA watchdog: if Dropbear / ws-proxy are running but stop answering (hung), restart them.
# Stopped services are left alone (systemd Restart=always handles crashes, and a manual stop stays stopped).
fd=0; fw=0
while true; do
  sleep 30
  # a slow answer under heavy load is NOT a hang. 10s probes, 4 failures in a row (~2 min) before any restart.
  b=$(timeout 15 bash -c 'exec 3<>/dev/tcp/127.0.0.1/109; head -n1 <&3' 2>/dev/null | tr -d '\r')
  if [[ "$b" == SSH-* ]]; then fd=0; else fd=$((fd+1)); fi
  if [[ $fd -ge 4 ]]; then systemctl is-active --quiet dropbear && systemctl restart dropbear; fd=0; sleep 5; fi
  if timeout 15 bash -c 'exec 3<>/dev/tcp/127.0.0.1/2082' 2>/dev/null; then fw=0; else fw=$((fw+1)); fi
  if [[ $fw -ge 4 ]]; then systemctl is-active --quiet ws-proxy && systemctl restart ws-proxy; fw=0; fi
done
WD
chmod +x /usr/local/bin/aliraza-watchdog.sh
cat > /etc/systemd/system/aliraza-watchdog.service <<'WDS'
[Unit]
Description=ALIRAZA watchdog (dropbear / ws-proxy hang detection)
After=network.target network-online.target dropbear.service ws-proxy.service
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/local/bin/aliraza-watchdog.sh
Restart=always
RestartSec=5
Nice=10
[Install]
WantedBy=multi-user.target
WDS
cat > /usr/local/bin/ws-proxy.py <<'WS_EOF'
# ---- ALIRAZA ws-proxy: throughput build (1MB chunks) -------------------------------------------
# SAFETY NOTES (read before changing CHUNK / LIMIT):
#  - CHUNK=1MB requires VPS RAM >= 4GB and 100-300 concurrent users.
#  - If running on 1-2GB RAM, reduce CHUNK to 524288 (512KB) (and LIMIT to 2097152).
#  - Keep kernel net.core.rmem_max >= 4MB for CHUNK to be effective.
# -------------------------------------------------------------------------------------------------
import asyncio, socket, time, os
try:
    import uvloop
    asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())
except Exception: pass
PORT = 2082
TARGET_HOST = '127.0.0.1'
TARGET_PORT = 109
LOG_FILE = '/var/log/ws-proxy.log'
MAP_DIR = '/run/aliraza/ws'
BAN_FILE = '/etc/artricks/banned.txt'
BAN_PORT = 2299
_B = [0, 0.0, set()]
def is_banned(ip):
    # blocked IPs are sent to the notice-only SSH server (shows the ban message, no login); list is reloaded when the file changes
    now = time.time()
    if now - _B[1] > 2:
        _B[1] = now
        try:
            m = os.stat(BAN_FILE).st_mtime
            if m != _B[0]:
                s = set()
                for l in open(BAN_FILE, encoding='utf-8'):
                    a = l.split('\t')[0].strip()
                    if a: s.add(a)
                _B[2] = s; _B[0] = m
        except Exception:
            _B[2] = set(); _B[0] = 0
    if ip.startswith('::ffff:'): ip = ip[7:]
    return ip in _B[2]
CHUNK = 1048576        # 1 MB
LIMIT = 4194304        # 4 MB (4x CHUNK for safe headroom)
WORKERS = min(8, max(2, os.cpu_count() or 2))
SOCKBUF = 4194304      # SO_RCVBUF / SO_SNDBUF (kernel doubles it; capped by net.core.rmem_max / wmem_max)
DRAIN_EVERY = 8        # await drain() only every 8th write (fewer syscalls under load)
LOG_EVERY = 100        # write the client IP to the log on 1 of every 100 connections
_LOGN = [0]
RESP = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
_LF = [None]
def log_client_ip(ip):
    # one long-lived line-buffered handle per worker (no open/close per connection); throttled to 1/100 connections
    # (online-user / IP-limit tracking uses MAP_DIR, not this log)
    _LOGN[0] += 1
    if _LOGN[0] % LOG_EVERY != 1: return
    try:
        if _LF[0] is None: _LF[0] = open(LOG_FILE, 'a', buffering=1)
        _LF[0].write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - REAL_IP:{ip}\n")
    except Exception: _LF[0] = None
def tune(w, client=False):
    try:
        s = w.get_extra_info('socket')
        if s is not None:
            if client:
                try: s.setsockopt(socket.IPPROTO_TCP, getattr(socket, 'TCP_QUICKACK', 12), 1)
                except Exception: pass
            try: s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, SOCKBUF)
            except Exception: pass
            try: s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, SOCKBUF)
            except Exception: pass
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 20)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 10)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 5)
            s.setsockopt(socket.IPPROTO_TCP, 18, 90000)  # TCP_USER_TIMEOUT: drop dead peers after 90s of unacked data
    except Exception: pass
    try: w.transport.set_write_buffer_limits(high=LIMIT, low=CHUNK)
    except Exception: pass
async def pump(r, w):
    # one direction only: a slow receiver here can never stall the opposite direction
    n = 0
    try:
        while True:
            data = await r.read(CHUNK)
            if not data: break
            w.write(data)
            n += 1
            if n % DRAIN_EVERY == 0: await w.drain()
    except Exception: pass
    finally:
        # still drain on exit so the tail of the stream is flushed
        try: await w.drain()
        except BaseException: pass
async def handle(reader, writer):
    peer = writer.get_extra_info('peername')
    real_ip = peer[0] if peer else '0.0.0.0'
    t_writer = None
    lport = None
    try:
        tune(writer, client=True)
        # HTTP header may arrive in several TCP pieces (payload [split]); read until the blank line (max 16KB, 10s)
        request = b""
        try:
            while b"\r\n\r\n" not in request and len(request) < 16384:
                chunk = await asyncio.wait_for(reader.read(4096), 10)
                if not chunk: break
                request += chunk
                if request.startswith(b"SSH-"): break
        except asyncio.TimeoutError:
            if not request: return
        if not request: return
        xr = xf = None
        for line in request.decode('utf-8', errors='ignore').split('\r\n'):
            low = line.lower()
            if low.startswith('x-real-ip:') and xr is None:
                xr = line.split(':', 1)[1].strip().split(',')[0].strip()
            elif low.startswith('x-forwarded-for:') and xf is None:
                xf = line.split(':', 1)[1].strip().split(',')[0].strip()
        real_ip = xr or xf or real_ip
        log_client_ip(real_ip)
        tport = BAN_PORT if is_banned(real_ip) else TARGET_PORT
        writer.write(RESP)
        await writer.drain()
        t_reader = None
        for _try in range(3):
            try:
                t_reader, t_writer = await asyncio.wait_for(asyncio.open_connection(TARGET_HOST, tport, limit=LIMIT), 6)
                break
            except Exception: await asyncio.sleep(0.3)
        if t_reader is None: return
        tune(t_writer)
        # client sent its SSH banner in the same packet as the HTTP header: do not lose it
        rest = request.partition(b"\r\n\r\n")[2]
        if rest.startswith(b"SSH-"): t_writer.write(rest)
        try:
            lport = t_writer.get_extra_info('sockname')[1]
            with open(f"{MAP_DIR}/{lport}", "w") as mf: mf.write(real_ip)
        except Exception: lport = None
        a = asyncio.ensure_future(pump(reader, t_writer))
        b = asyncio.ensure_future(pump(t_reader, writer))
        await asyncio.wait([a, b], return_when=asyncio.FIRST_COMPLETED)
        a.cancel(); b.cancel()
    except Exception: pass
    finally:
        for w in (writer, t_writer):
            try:
                if w is not None: w.close()
            except Exception: pass
        if lport:
            try: os.remove(f"{MAP_DIR}/{lport}")
            except Exception: pass
def init_map():
    try:
        os.makedirs(MAP_DIR, exist_ok=True)
        for f in os.listdir(MAP_DIR): os.remove(os.path.join(MAP_DIR, f))
    except Exception: pass
async def serve():
    server = await asyncio.start_server(handle, '0.0.0.0', PORT, limit=LIMIT, backlog=8192,
                                        reuse_address=True, reuse_port=(WORKERS > 1))
    # best-effort listener options (each one is skipped silently if the kernel/container refuses it)
    for ls in (server.sockets or []):
        for lvl, opt, val in ((socket.SOL_SOCKET, getattr(socket, 'SO_BUSY_POLL', 46), 50),
                              (socket.IPPROTO_TCP, getattr(socket, 'TCP_FASTOPEN', 23), 4096),
                              (socket.IPPROTO_TCP, getattr(socket, 'TCP_DEFER_ACCEPT', 9), 1)):
            try: ls.setsockopt(lvl, opt, val)
            except Exception: pass
    async with server:
        await server.serve_forever()
def run():
    try: asyncio.run(serve())
    finally: os._exit(1)
def supervise():
    kids = set()
    while True:
        while len(kids) < WORKERS:
            pid = os.fork()
            if pid == 0: run()
            kids.add(pid)
        try: pid, _ = os.wait()
        except ChildProcessError:
            kids.clear(); continue
        kids.discard(pid); time.sleep(0.5)
init_map()
if WORKERS > 1: supervise()
else: run()
WS_EOF
cat > /usr/local/bin/autokill.py <<'PY_EOF'
import os
import time
import subprocess
import re

USER_DIR = "/etc/artricks/users"
WSMAP = "/run/aliraza/ws"
LOCALS = ("127.0.0.1", "::1", "::ffff:127.0.0.1")
# Multi-login rule (IP_LIMIT = max different client IPs at the same time):
#  - counts distinct IPs, NOT sessions (a reconnect of the same device never counts as a 2nd login)
#  - must persist for GRACE_CYCLES checks (10s each) so reconnect overlaps are ignored
#  - NEWEST login wins: only the older extra IP(s) are disconnected (stale session after wifi<->mobile switch)
#  - LOCK_ON_VIOLATION=True restores the old harsh behaviour (lock account + kill every session)
LOCK_ON_VIOLATION = False
GRACE_CYCLES = 8

RE_A = re.compile(r"\]: \[(\d+)\] .*?auth succeeded for '?([\w.-]+)'? from (\S+)")
RE_B = re.compile(r"dropbear\[(\d+)\]: .*?auth succeeded for '?([\w.-]+)'? from (\S+)")

def run(cmd, t=15):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=t).decode("utf-8", errors="ignore")
    except Exception:
        return ""

def get_auth_logs():
    raw = run(["journalctl", "-u", "dropbear", "--no-pager", "-g", "auth succeeded", "-n", "5000"])
    if not raw.strip() or raw.lstrip().startswith("-- No entries"):
        raw = run(["journalctl", "-u", "dropbear", "--no-pager", "-n", "2000"])
    if "auth succeeded" not in raw and os.path.exists("/var/log/auth.log"):   # journal already has it -> skip the 2MB file read
        try:
            with open("/var/log/auth.log", "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 2097152))
                raw += "\n" + f.read().decode("utf-8", errors="ignore")
        except Exception:
            pass
    return raw

# pid -> (user, "ip:port", last seen age). A dropbear process authenticates exactly once, so the journal only has to be
# scanned when a NEW pid appears (or every RESCAN_CYCLES checks to guard against pid reuse), not on every 10s cycle.
_PIDMAP = {}
_SCANS = [0]
RESCAN_CYCLES = 6

def get_sessions():
    """user -> [(pid, real_client_ip, age_seconds)]"""
    procs = [p for p in (l.split() for l in run(["ps", "-eo", "pid=,etimes=,comm="]).splitlines()) if len(p) >= 3 and p[2] == "dropbear"]
    if not procs:
        _PIDMAP.clear()
        return {}   # nobody connected: skip the expensive journal scan
    ages = {p[0]: (int(p[1]) if p[1].isdigit() else 0) for p in procs}
    for pid in list(_PIDMAP):
        if pid not in ages or ages[pid] + 2 < _PIDMAP[pid][2]:   # process gone, or its pid was reused by a newer process
            del _PIDMAP[pid]
    _SCANS[0] += 1
    if _SCANS[0] >= RESCAN_CYCLES or any(pid not in _PIDMAP for pid in ages):
        _SCANS[0] = 0
        last = {}
        for line in get_auth_logs().splitlines():
            m = RE_A.search(line) or RE_B.search(line)
            if m:
                last[m.group(1)] = (m.group(2), m.group(3))
        for pid in ages:
            if pid in last:
                _PIDMAP[pid] = (last[pid][0], last[pid][1], ages[pid])
    for pid in ages:
        if pid in _PIDMAP:
            _PIDMAP[pid] = (_PIDMAP[pid][0], _PIDMAP[pid][1], ages[pid])
    out = {}
    for p in procs:
        if p[0] not in _PIDMAP:
            continue
        user, frm = _PIDMAP[p[0]][0], _PIDMAP[p[0]][1]
        ip, _, port = frm.rpartition(":")
        ip = ip.strip("[]")
        real = ip
        if ip in LOCALS and port.isdigit():
            try:
                with open(f"{WSMAP}/{port}") as f:
                    real = f.read().strip() or ip
            except Exception:
                pass
        age = int(p[1]) if p[1].isdigit() else 0
        out.setdefault(user, []).append((p[0], real, age))
    return out

def get_pid_io_bytes(pid):
    total = 0
    try:
        with open(f"/proc/{pid}/io", "r") as f:
            for line in f:
                if line.startswith("rchar:") or line.startswith("wchar:"):
                    total += int(line.split(":")[1].strip())
    except Exception:
        pass
    return total

def kill_pid(pid):
    try:
        os.kill(int(pid), 9)
    except Exception:
        pass

def lock_user(user):
    subprocess.call(["passwd", "-l", user], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def parse_conf(lines):
    ip_limit, gb_limit, used_mb = 0, "Unlimited", 0.0
    for line in lines:
        if line.startswith("IP_LIMIT="):
            try: ip_limit = int(line.strip().split("=")[1])
            except Exception: pass
        elif line.startswith("GB_LIMIT="):
            gb_limit = line.strip().split("=")[1]
        elif line.startswith("USED_MB="):
            try: used_mb = float(line.strip().split("=")[1])
            except Exception: pass
    return ip_limit, gb_limit, used_mb

def save_usage(conf_path, used_mb):
    # re-read right before writing so a panel edit made meanwhile is not overwritten; atomic replace
    if not os.path.exists(conf_path):
        return  # account was deleted meanwhile: never resurrect its conf
    with open(conf_path, "r") as f:
        lines = f.readlines()
    out, seen = [], False
    for line in lines:
        if line.startswith("USED_MB="):
            out.append(f"USED_MB={used_mb:.2f}\n"); seen = True
        elif line.startswith("LAST_SEEN="):
            continue
        else:
            out.append(line if line.endswith("\n") else line + "\n")
    if not seen:
        out.append(f"USED_MB={used_mb:.2f}\n")
    out.append(f"LAST_SEEN={int(time.time())}\n")
    tmp = conf_path + ".tmp"
    with open(tmp, "w") as f:
        f.writelines(out)
    os.replace(tmp, conf_path)

def extra_ip_sessions(sessions, ip_limit):
    """sessions: [(pid, ip, age)]. Returns pids to disconnect (older extra IPs), [] if within the limit."""
    by_ip = {}
    for pid, ip, age in sessions:
        by_ip.setdefault(ip, []).append((pid, age))
    if len(by_ip) <= ip_limit:
        return []
    order = sorted(by_ip.items(), key=lambda kv: min(a for _, a in kv[1]))  # newest IP first
    victims = []
    for ip, ss in order[ip_limit:]:
        victims += [pid for pid, _ in ss]
    return victims

def main():
    last_pid_bytes = {}
    strikes = {}
    while True:
        try:
            sess = get_sessions()
            live = set()
            if os.path.isdir(USER_DIR):
                for fname in os.listdir(USER_DIR):
                    if not fname.endswith(".conf"):
                        continue
                    uname = fname[:-5]
                    conf_path = os.path.join(USER_DIR, fname)
                    try:
                        with open(conf_path, "r") as f:
                            ip_limit, gb_limit, used_mb = parse_conf(f.readlines())
                        sl = sess.get(uname, [])
                        pids = [x[0] for x in sl]
                        live.update(pids)
                        if not pids:
                            strikes.pop(uname, None)
                            continue
                        for pid in pids:
                            cur = get_pid_io_bytes(pid)
                            if pid in last_pid_bytes and cur > last_pid_bytes[pid]:
                                used_mb += (cur - last_pid_bytes[pid]) / (1024.0 * 1024.0)
                            last_pid_bytes[pid] = cur
                        save_usage(conf_path, used_mb)

                        if gb_limit != "Unlimited":
                            try:
                                if used_mb >= float(gb_limit) * 1024.0:
                                    lock_user(uname)
                                    for pid in pids: kill_pid(pid)
                                    continue
                            except Exception:
                                pass

                        if ip_limit > 0:
                            victims = extra_ip_sessions(sl, ip_limit)
                            if victims:
                                strikes[uname] = strikes.get(uname, 0) + 1
                                if strikes[uname] >= GRACE_CYCLES:
                                    if LOCK_ON_VIOLATION:
                                        lock_user(uname)
                                        victims = pids
                                    for pid in victims: kill_pid(pid)
                                    strikes[uname] = 0
                            else:
                                strikes.pop(uname, None)
                    except Exception:
                        continue
            for pid in [p for p in last_pid_bytes if p not in live]:
                del last_pid_bytes[pid]
        except Exception:
            pass
        time.sleep(10)

if __name__ == "__main__":
    main()
PY_EOF
cat > /usr/local/bin/tgbot.py <<'TG_EOF'
import os
import re
import json
import asyncio
import subprocess
import html
import time
import pwd
import sqlite3
import logging
from datetime import datetime, timedelta, date
from collections import defaultdict
from contextlib import contextmanager

from urllib.parse import quote
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, BotCommand, BotCommandScopeChat
from telegram.error import BadRequest, Forbidden, NetworkError, RetryAfter, TelegramError
from telegram.ext import (
    Application, CommandHandler, CallbackQueryHandler,
    MessageHandler, ContextTypes, filters,
)

PANEL_NAME = "ALIRAZA VPN Panel"
CONFIG_FILE = "/etc/artricks/tgbot/config.json"
ADMINS_FILE = "/etc/artricks/tgbot/admins.json"
USERS_DIR = "/etc/artricks/users"
DOMAIN_FILE = "/etc/artricks/domain.conf"
BANNER_FILE = "/etc/artricks/banner.txt"

NGINX_TEMPLATE = """server {{
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name {dom} _;
    location / {{
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        tcp_nodelay on;
        access_log off;
    }}
    location /artricks {{
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        tcp_nodelay on;
        access_log off;
    }}
}}
server {{
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name {dom} _;
    ssl_certificate /etc/letsencrypt/live/{dom}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{dom}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {{
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        tcp_nodelay on;
        access_log off;
    }}
    location /artricks {{
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        tcp_nodelay on;
        access_log off;
    }}
}}
"""

FLOWS = {
    "add_user": [
        ("username", "\U0001F464 Username enter karein:"),
        ("password", "\U0001F511 Password enter karein:"),
        ("days", "\U0001F4C5 Expiry days enter karein (e.g. 30):"),
        ("ip_limit", "\U0001F310 Max IP Limit enter karein (e.g. 1):"),
        ("gb_limit", "\U0001F4BE Data Limit GB enter karein (e.g. 5, ya Unlimited):"),
    ],
    "del_user": [("username", "\U0001F464 Delete karne ke liye Username enter karein:")],
    "renew_user": [
        ("username", "\U0001F464 Username enter karein jise renew karna hai:"),
        ("days", "\U0001F4C5 Kitne additional days add karne hain?"),
    ],
    "ip_limit": [
        ("username", "\U0001F464 Username enter karein:"),
        ("value", "\U0001F310 Naya IP Limit enter karein:"),
    ],
    "gb_limit": [
        ("username", "\U0001F464 Username enter karein:"),
        ("value", "\U0001F4BE Naya GB Limit enter karein:"),
    ],
    "domain": [("value", "\U0001F30D Naya domain enter karein (e.g. sub.example.com):")],
    "banner": [("value", "\U0001F4E2 Naya SSH banner text bhejein:")],
    "add_admin": [("value", "\U0001F451 Naye Admin ka Telegram User ID enter karein:")],
    "remove_admin": [("value", "\U0001F5D1 Remove karne ke liye Admin ka Telegram User ID enter karein:")],
}

def load_config():
    with open(CONFIG_FILE) as f: return json.load(f)
def load_admins():
    if not os.path.exists(ADMINS_FILE): return []
    with open(ADMINS_FILE) as f: return json.load(f)
def save_admins(admins):
    with open(ADMINS_FILE, "w") as f: json.dump(admins, f)
def is_admin(uid): return uid in load_admins()
def is_super(uid): return uid == load_config().get("super_admin")
def sh(cmd_list, input_data=None, timeout=90):
    try: return subprocess.run(cmd_list, capture_output=True, text=True, input=input_data, timeout=timeout)
    except subprocess.TimeoutExpired: return subprocess.CompletedProcess(cmd_list, 124, "", "timeout")
    except FileNotFoundError: return subprocess.CompletedProcess(cmd_list, 127, "", "not found")
def run(cmd_str): return subprocess.run(cmd_str, shell=True, capture_output=True, text=True)

def get_domain():
    if os.path.exists(DOMAIN_FILE):
        with open(DOMAIN_FILE) as f:
            d = f.read().strip()
            return d if d else "No Domain Set"
    return "No Domain Set"

PANEL_DIR = "/opt/aliraza-panel"
PANEL_PY = PANEL_DIR + "/venv/bin/python"

def panel_call(code):
    if not os.path.exists(PANEL_PY): return False
    r = sh(["bash", "-c", f"cd {PANEL_DIR} && {PANEL_PY} -c 'import app; {code}'"])
    return r.returncode == 0

def apply_nginx_config():
    dom = get_domain()
    if dom == "No Domain Set": return
    if panel_call("app.apply_nginx()"): return
    os.makedirs("/etc/nginx/conf.d", exist_ok=True)
    conf = NGINX_TEMPLATE.format(dom=dom)
    if not os.path.exists(f"/etc/letsencrypt/live/{dom}/fullchain.pem"):
        conf = conf.replace(f"/etc/letsencrypt/live/{dom}/fullchain.pem", "/etc/artricks/ssl/self.crt").replace(f"/etc/letsencrypt/live/{dom}/privkey.pem", "/etc/artricks/ssl/self.key")
    with open("/etc/nginx/conf.d/vpn.conf", "w") as f:
        f.write(conf)
    sh(["rm", "-f", "/etc/nginx/sites-enabled/default"])
    if sh(["nginx", "-t"]).returncode == 0:
        sh(["systemctl", "restart", "nginx"])

def valid_username(u): return bool(u) and len(u)<=32 and u not in (".","..") and u[0]!="-" and not re.search(r"[\s:/\\\x00-\x1f\x7f]", u)

def add_user(username, password, days, ip_limit, gb_limit):
    if not valid_username(username): return False, "Invalid username."
    try: exp_date = (datetime.now() + timedelta(days=int(days))).strftime("%Y-%m-%d")
    except ValueError: return False, "Invalid days value."
    r = sh(["useradd", "-M", "-s", "/bin/bash", "-e", exp_date, "--", username])
    if r.returncode != 0: r = sh(["useradd", "--badname", "-M", "-s", "/bin/bash", "-e", exp_date, "--", username])
    if r.returncode != 0: return False, (r.stderr.strip() or "User create failed.")
    sh(["chpasswd"], input_data=f"{username}:{password}\n")
    os.makedirs(USERS_DIR, exist_ok=True)
    with open(f"{USERS_DIR}/{username}.conf", "w") as f:
        f.write(f"IP_LIMIT={ip_limit}\nGB_LIMIT={gb_limit}\nUSED_MB=0.0\n")
    return True, exp_date

def delete_user(username):
    """Delete a script-managed account. Returns True on success. Refuses names without a managed conf file (never touches root/system users)."""
    if not valid_username(username) or not os.path.exists(f"{USERS_DIR}/{username}.conf"): return False
    sh(["pkill", "-KILL", "-u", username])
    sh(["userdel", "-f", username])
    if sh(["id", username]).returncode == 0: return False
    try: os.remove(f"{USERS_DIR}/{username}.conf")
    except FileNotFoundError: pass
    try:
        with dbc() as c: c.execute("DELETE FROM accounts WHERE username=?", (username,))
    except Exception: pass
    _OC[0] = 0
    return True

def renew_user(username, days):
    if sh(["id", username]).returncode != 0: return False
    try: new_exp = (datetime.now() + timedelta(days=int(days))).strftime("%Y-%m-%d")
    except ValueError: return False
    sh(["usermod", "-e", new_exp, username])
    sh(["passwd", "-u", username])
    return True

def update_conf_field(username, field, value):
    path = f"{USERS_DIR}/{username}.conf"
    if not os.path.exists(path): return False
    lines = open(path).readlines()
    new_lines = []
    found = False
    for line in lines:
        if line.startswith(f"{field}="):
            new_lines.append(f"{field}={value}\n")
            found = True
        else: new_lines.append(line)
    if not found: new_lines.append(f"{field}={value}\n")
    with open(path, "w") as f: f.writelines(new_lines)
    sh(["passwd", "-u", username])
    return True

def list_users_text():
    if not os.path.isdir(USERS_DIR): return "Koi user nahi mila."
    entries = []
    shadow = shadow_info()
    for fname in sorted(os.listdir(USERS_DIR)):
        if not fname.endswith(".conf"): continue
        uname = fname[:-5]
        data = {}
        try:
            with open(f"{USERS_DIR}/{fname}") as fh:
                for l in fh:
                    if "=" in l:
                        k, v = l.strip().split("=", 1)
                        data[k] = v
        except OSError: pass
        status = "Deleted"
        if uname in shadow: status = "LOCKED" if shadow[uname][0] else "Active"
        used_mb = 0.0
        try: used_mb = float(data.get("USED_MB", "0") or 0)
        except ValueError: pass
        used_gb = round(used_mb / 1024, 2)
        entries.append(f"\U0001F464 {uname} | IP:{data.get('IP_LIMIT', '?')} | Used:{used_gb}GB / {data.get('GB_LIMIT', '?')}GB | {status}")
    if not entries: return "Koi user nahi mila."
    out = "\n".join(entries)
    return out if len(out) <= 3900 else out[:3900].rsplit("\n", 1)[0] + f"\n… (+{len(entries) - out[:3900].count(chr(10)) - 1} more)"

def connected_ips_text():
    r = sh(["ss", "-tnp"])
    ports = {"109", "447", "22"}
    try: ports.add(str(json.load(open("/etc/artricks/panel.json")).get("ssh_port")))
    except Exception: pass
    lines = [l for l in r.stdout.splitlines() if "ESTAB" in l and len(l.split()) > 3 and l.split()[3].rsplit(":", 1)[-1] in ports]
    return f"\U0001F50C Active SSH/WS sessions (approx): {len(lines)}"

def status_text():
    def st(svc):
        r = sh(["systemctl", "is-active", svc])
        return "\U0001F7E2 ACTIVE" if r.stdout.strip() == "active" else "\U0001F534 INACTIVE"
    return f"\U0001F30D Domain: {get_domain()}\n\nNginx: {st('nginx')}\nDropbear: {st('dropbear')}\nWS Proxy: {st('ws-proxy')}\nAuto-Kill: {st('autokill')}"

def set_domain(new_domain):
    os.makedirs("/etc/artricks", exist_ok=True)
    with open(DOMAIN_FILE, "w") as f: f.write(new_domain)
    try:
        pj = "/etc/artricks/panel.json"
        c = json.load(open(pj)) if os.path.exists(pj) else {}
        c["domain"] = new_domain
        with open(pj, "w") as f: json.dump(c, f)
    except Exception: pass
    apply_nginx_config()

def setup_ssl():
    dom = get_domain()
    if dom == "No Domain Set": return False, "Pehle domain set karein."
    sh(["systemctl", "stop", "nginx"])
    sh(["certbot", "certonly", "-n", "--standalone", "--preferred-challenges", "http", "--agree-tos", "--register-unsafely-without-email", "-d", dom], timeout=300)
    if os.path.exists(f"/etc/letsencrypt/live/{dom}/fullchain.pem"):
        apply_nginx_config()
        sh(["systemctl", "start", "nginx"])
        return True, "SSL issued successfully."
    sh(["systemctl", "start", "nginx"])
    return False, "SSL fail ho gaya."

def fix_websocket():
    sh(["systemctl", "restart", "dropbear"])
    sh(["systemctl", "daemon-reload"])
    sh(["systemctl", "restart", "ws-proxy"])
    sh(["systemctl", "restart", "autokill"])
    apply_nginx_config()
    return "WebSocket & Bandwidth engine restarted."

WS_PROXY_SRC = """import socket, threading, select, time
PORT = 2082
TARGET_HOST = '127.0.0.1'
TARGET_PORT = 109
LOG_FILE = '/var/log/ws-proxy.log'
def log_client_ip(ip):
    try:
        with open(LOG_FILE, 'a') as f: f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - REAL_IP:{ip}\\n")
    except Exception: pass
def handle_client(client_socket, client_addr):
    real_ip = client_addr[0]
    try:
        client_socket.settimeout(10)
        client_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        request = client_socket.recv(4096).decode('utf-8', errors='ignore')
        if not request:
            client_socket.close()
            return
        for line in request.split('\\r\\n'):
            if line.lower().startswith('x-forwarded-for:') or line.lower().startswith('x-real-ip:'):
                real_ip = line.split(':')[1].strip().split(',')[0].strip()
                break
        log_client_ip(real_ip)
        response = "HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n\\r\\n"
        client_socket.sendall(response.encode('utf-8'))
        target_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        target_socket.connect((TARGET_HOST, TARGET_PORT))
        sockets = [client_socket, target_socket]
        client_socket.settimeout(None)
        while True:
            readable, _, _ = select.select(sockets, [], [])
            for s in readable:
                other = target_socket if s is client_socket else client_socket
                data = s.recv(65536)
                if not data: return
                other.sendall(data)
    except Exception: pass
    finally: client_socket.close()
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', PORT))
server.listen(200)
while True:
    client, addr = server.accept()
    threading.Thread(target=handle_client, args=(client, addr), daemon=True).start()
"""

WS_PROXY_SERVICE = """[Unit]
Description=ALIRAZA WebSocket Proxy Service
After=network.target network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
RestartSec=2
LimitNOFILE=1048576
LimitMEMLOCK=infinity
TasksMax=infinity
Nice=-15
OOMScoreAdjust=-500
[Install]
WantedBy=multi-user.target
"""

AUTOKILL_SRC = open("/usr/local/bin/autokill.py").read() if os.path.exists("/usr/local/bin/autokill.py") else ""

AUTOKILL_SERVICE = """[Unit]
Description=ARTRICKS Auto-Kill & Bandwidth Tracking Service
After=network.target network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/autokill.py
Restart=always
RestartSec=3
Nice=19
CPUWeight=20
IOSchedulingClass=idle
[Install]
WantedBy=multi-user.target
"""

DEFAULT_BANNER = """<font color="#FF0000">𝗦𝗘𝗥𝗩𝗘𝗥 <font color="#FF0000">𝗕𝗬</font> 𝗔𝗟𝗜𝗥𝗔𝗭𝗔</font>

<font color="#00FFFF">🌐 𝗦𝗦𝗛</font>  •  <font color="#00FF00">𝗩𝗟𝗘𝗦𝗦</font>
<font color="#FF1493">⚡ 𝗩𝗠𝗘𝗦</font> • <font color="#FFFF00">𝗧𝗥𝗢𝗝𝗔𝗡</font><font color="#FF0000">🔥</font>

<font color="#FF8C00">📢 𝗝𝗢𝗜𝗡 𝗖𝗛𝗔𝗡𝗘𝗟</font>
<font color='#00FF00'>↓ <a href="https://t.me/ar_tricks">CLICK HERE</a> ↓</font>
"""

def install_components_sync():
    sh(["apt-get", "-o", "DPkg::Lock::Timeout=300", "update", "-y"], timeout=900)
    sh(["apt-get", "-o", "DPkg::Lock::Timeout=300", "install", "-y", "curl", "wget", "unzip", "tar", "net-tools", "socat", "jq", "openssl", "nginx", "dropbear", "certbot", "python3", "python3-pip", "lsof", "iptables"], timeout=1800)
    if not os.path.exists(BANNER_FILE) or os.path.getsize(BANNER_FILE) == 0:
        with open(BANNER_FILE, "w", encoding="utf-8") as f: f.write(DEFAULT_BANNER)
    panel_call("app.apply_dropbear()")
    sh(["systemctl", "restart", "ssh"])
    if not os.path.exists("/usr/local/bin/ws-proxy.py"):
        with open("/usr/local/bin/ws-proxy.py", "w") as f: f.write(WS_PROXY_SRC)
    sh(["chmod", "+x", "/usr/local/bin/ws-proxy.py"])
    with open("/etc/systemd/system/ws-proxy.service", "w") as f: f.write(WS_PROXY_SERVICE)
    if AUTOKILL_SRC:
        with open("/usr/local/bin/autokill.py", "w") as f: f.write(AUTOKILL_SRC)
    sh(["chmod", "+x", "/usr/local/bin/autokill.py"])
    with open("/etc/systemd/system/autokill.service", "w") as f: f.write(AUTOKILL_SERVICE)
    sh(["systemctl", "daemon-reload"])
    sh(["systemctl", "enable", "ws-proxy"])
    sh(["systemctl", "restart", "ws-proxy"])
    sh(["systemctl", "enable", "autokill"])
    sh(["systemctl", "restart", "autokill"])
    apply_nginx_config()

def uninstall_all():
    sh(["systemctl", "stop", "aliraza-panel"]); sh(["systemctl", "disable", "aliraza-panel"])
    sh(["systemctl", "stop", "ws-proxy"]); sh(["systemctl", "stop", "autokill"]); sh(["systemctl", "stop", "dropbear"])
    sh(["systemctl", "disable", "ws-proxy"]); sh(["systemctl", "disable", "autokill"])
    for f in ["/etc/systemd/system/ws-proxy.service", "/etc/systemd/system/autokill.service", "/etc/systemd/system/dropbear.service.d/override.conf", "/usr/local/bin/ws-proxy.py", "/usr/local/bin/autokill.py", "/etc/nginx/conf.d/vpn.conf", "/etc/nginx/conf.d/panel.conf", "/etc/systemd/system/aliraza-panel.service"]:
        try: os.remove(f)
        except FileNotFoundError: pass
    sh(["systemctl", "daemon-reload"]); sh(["systemctl", "restart", "nginx"])
    if os.path.isdir(USERS_DIR):
        for fname in os.listdir(USERS_DIR):
            if fname.endswith(".conf"): sh(["userdel", "-f", fname[:-5]])
    sh(["rm", "-rf", "/etc/artricks"]); sh(["rm", "-rf", "/opt/rr-tgbot-venv"]); sh(["rm", "-rf", "/opt/aliraza-panel"])
    for f in ["/usr/local/bin/menu", "/usr/bin/menu"]:
        try: os.remove(f)
        except FileNotFoundError: pass

def schedule_self_removal():
    subprocess.Popen(["bash", "-c", "sleep 3 && systemctl disable tgbot 2>/dev/null; systemctl stop tgbot 2>/dev/null; rm -f /etc/systemd/system/tgbot.service /usr/local/bin/tgbot.py; systemctl daemon-reload"])


# =====================================================================
#  v3: public users + referral + channel verification + admin panel
# =====================================================================
logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(name)s %(levelname)s %(message)s")
log = logging.getLogger("tgbot")

DB_FILE = "/etc/artricks/tgbot/bot.db"
WSMAP = "/run/aliraza/ws"
DEFAULTS = {"ppr": "1", "rpa": "3", "days": "7", "gb": "5", "ip": "1"}
PAGE = 8
LOCKS = defaultdict(asyncio.Lock)
ULOCKS = {}          # per-user update serialisation (different users run in parallel)
_JOINED = {}         # uid -> time until which a positive channel check is trusted
JOIN_TTL = 90
_SC = {}             # settings cache (only this process writes settings)
BG = set()
_OC = [0, {}]
_IPC = [0, ""]


def e(s): return html.escape(str(s), quote=False)
def aio(fn, *a): return asyncio.to_thread(fn, *a)
def B(text, data=None, url=None, style=None):
    return InlineKeyboardButton(text, callback_data=data, url=url, api_kwargs={"style": style} if style else None)
def KB(rows): return InlineKeyboardMarkup(rows)


# ---------------------------------------------------------------- database
@contextmanager
def dbc():
    c = sqlite3.connect(DB_FILE, timeout=20)
    c.row_factory = sqlite3.Row
    try:
        c.execute("PRAGMA synchronous=NORMAL")
        yield c
        c.commit()
    finally:
        c.close()


def db_init():
    os.makedirs(os.path.dirname(DB_FILE), exist_ok=True)
    with dbc() as c:
        try: c.execute("PRAGMA journal_mode=WAL")
        except sqlite3.DatabaseError: pass
        c.executescript("""
        CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, username TEXT, name TEXT, points INTEGER DEFAULT 0,
            referrer INTEGER, refs INTEGER DEFAULT 0, verified INTEGER DEFAULT 0, ref_paid INTEGER DEFAULT 0,
            banned INTEGER DEFAULT 0, joined INTEGER);
        CREATE TABLE IF NOT EXISTS accounts(username TEXT PRIMARY KEY, owner INTEGER, created INTEGER);
        CREATE TABLE IF NOT EXISTS channels(id INTEGER PRIMARY KEY AUTOINCREMENT, chat_id TEXT, title TEXT, link TEXT);
        CREATE TABLE IF NOT EXISTS settings(k TEXT PRIMARY KEY, v TEXT);
        CREATE INDEX IF NOT EXISTS idx_users_ref ON users(referrer);
        CREATE INDEX IF NOT EXISTS idx_users_uname ON users(lower(username));
        CREATE INDEX IF NOT EXISTS idx_acc_owner ON accounts(owner);
        """)
    try: os.chmod(DB_FILE, 0o600)
    except Exception: pass


def get_set(k):
    v = _SC.get(k)
    if v is not None: return v
    with dbc() as c:
        r = c.execute("SELECT v FROM settings WHERE k=?", (k,)).fetchone()
    v = r["v"] if r else DEFAULTS[k]
    _SC[k] = v
    return v


def set_set(k, v):
    with dbc() as c: c.execute("INSERT INTO settings(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, str(v)))
    _SC.pop(k, None)


def cost_points(): return int(get_set("ppr")) * int(get_set("rpa"))
def eff_cost(uid): return 0 if is_admin(uid) else cost_points()
def gb_text(g): return "Unlimited" if str(g).lower() == "unlimited" else f"{g} GB"


def upsert_user(u, referrer=None):
    """Create/update the bot user. A referrer is only accepted for brand-new users. Returns True if new."""
    uname, name = (u.username or ""), (u.full_name or "")[:64]
    with dbc() as c:
        c.execute("BEGIN IMMEDIATE")
        if c.execute("SELECT 1 FROM users WHERE id=?", (u.id,)).fetchone():
            c.execute("UPDATE users SET username=?, name=? WHERE id=?", (uname, name, u.id))
            return False
        ref = None
        if referrer and referrer != u.id and c.execute("SELECT 1 FROM users WHERE id=? AND banned=0", (referrer,)).fetchone():
            ref = referrer
        c.execute("INSERT INTO users(id,username,name,referrer,joined) VALUES(?,?,?,?,?)", (u.id, uname, name, ref, int(time.time())))
        return True


def get_user(uid):
    with dbc() as c: return c.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()


def mark_verified(uid):
    """Mark verified. Pays the referrer exactly once. Returns (referrer, points) when a referral was paid now."""
    pts = int(get_set("ppr"))
    with dbc() as c:
        c.execute("BEGIN IMMEDIATE")
        u = c.execute("SELECT verified, referrer, ref_paid FROM users WHERE id=?", (uid,)).fetchone()
        if not u: return None
        c.execute("UPDATE users SET verified=1 WHERE id=?", (uid,))
        if u["ref_paid"] or not u["referrer"]: return None
        c.execute("UPDATE users SET ref_paid=1 WHERE id=?", (uid,))
        c.execute("UPDATE users SET points=points+?, refs=refs+1 WHERE id=?", (pts, u["referrer"]))
        return (u["referrer"], pts)


def add_points(uid, n):
    """Add (or subtract) points, never below 0. Returns (old, new) or None if user unknown."""
    with dbc() as c:
        c.execute("BEGIN IMMEDIATE")
        r = c.execute("SELECT points FROM users WHERE id=?", (uid,)).fetchone()
        if not r: return None
        new = max(0, r["points"] + n)
        c.execute("UPDATE users SET points=? WHERE id=?", (new, uid))
        return (r["points"], new)


def finalize_purchase(uid, username, cost):
    with dbc() as c:
        c.execute("BEGIN IMMEDIATE")
        r = c.execute("SELECT points FROM users WHERE id=?", (uid,)).fetchone()
        if not r or r["points"] < cost: return False
        c.execute("UPDATE users SET points=points-? WHERE id=?", (cost, uid))
        c.execute("INSERT INTO accounts(username,owner,created) VALUES(?,?,?)", (username, uid, int(time.time())))
        return True


def sync_accounts():
    """Forget accounts that were removed elsewhere (panel / admin tools / expiry cleanup)."""
    with dbc() as c:
        for r in c.execute("SELECT username FROM accounts").fetchall():
            if not os.path.exists(f"{USERS_DIR}/{r['username']}.conf"):
                c.execute("DELETE FROM accounts WHERE username=?", (r["username"],))


def own_accounts(uid):
    sync_accounts()
    with dbc() as c:
        return [r["username"] for r in c.execute("SELECT username FROM accounts WHERE owner=? ORDER BY created", (uid,))]


def acc_owner(name):
    with dbc() as c:
        r = c.execute("SELECT owner FROM accounts WHERE username=?", (name,)).fetchone()
    return r["owner"] if r else None


def get_channels():
    with dbc() as c: return c.execute("SELECT * FROM channels ORDER BY id").fetchall()


def save_channel(chat_id, title, link):
    with dbc() as c:
        if c.execute("SELECT 1 FROM channels WHERE chat_id=?", (str(chat_id),)).fetchone(): return False
        c.execute("INSERT INTO channels(chat_id,title,link) VALUES(?,?,?)", (str(chat_id), title or str(chat_id), link))
        _JOINED.clear()
        return True


# ------------------------------------------------- system helpers (VPS side)
def panel_cfg():
    try:
        with open("/etc/artricks/panel.json") as f: return json.load(f)
    except Exception: return {}


def public_ip():
    if _IPC[1] and time.time() - _IPC[0] < 3600: return _IPC[1]
    r = sh(["curl", "-4", "-s", "--max-time", "3", "ifconfig.me"])
    ip = r.stdout.strip() if r.returncode == 0 else ""
    if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", ip): _IPC[0], _IPC[1] = time.time(), ip
    return _IPC[1]


RE_A = re.compile(r"\]: \[(\d+)\] .*?auth succeeded for '?([\w.-]+)'? from (\S+)")
RE_B = re.compile(r"dropbear\[(\d+)\]: .*?auth succeeded for '?([\w.-]+)'? from (\S+)")


def get_online(force=False):
    """user -> number of distinct client IPs currently connected (same detection as the panel / auto-kill)."""
    if not force and time.time() - _OC[0] < 4: return _OC[1]
    out = {}
    try:
        procs = [p for p in (l.split() for l in sh(["ps", "-eo", "pid=,etimes=,comm="]).stdout.splitlines()) if len(p) >= 3 and p[2] == "dropbear"]
        if procs:
            raw = sh(["journalctl", "-u", "dropbear", "--no-pager", "-g", "auth succeeded", "-n", "5000"]).stdout
            if not raw.strip() or raw.lstrip().startswith("-- No entries"):
                raw = sh(["journalctl", "-u", "dropbear", "--no-pager", "-n", "2000"]).stdout
            last = {}
            for line in raw.splitlines():
                m = RE_A.search(line) or RE_B.search(line)
                if m: last[m.group(1)] = (m.group(2), m.group(3))
            ips = {}
            for p in procs:
                if p[0] not in last: continue
                user, frm = last[p[0]]
                ip, _, port = frm.rpartition(":")
                ip = ip.strip("[]")
                if ip in ("127.0.0.1", "::1", "::ffff:127.0.0.1") and port.isdigit():
                    try:
                        with open(f"{WSMAP}/{port}") as f: ip = f.read().strip() or ip
                    except Exception: pass
                ips.setdefault(user, set()).add(ip)
            out = {u: len(s) for u, s in ips.items()}
    except Exception:
        log.exception("get_online")
    _OC[0], _OC[1] = time.time(), out
    return out


def shadow_info():
    m = {}
    try:
        with open("/etc/shadow") as f:
            for l in f:
                p = l.split(":")
                if len(p) > 7: m[p[0]] = (p[1].startswith("!"), p[7])
    except Exception: pass
    return m


def read_conf(u):
    d = {"IP_LIMIT": "1", "GB_LIMIT": "Unlimited", "USED_MB": "0"}
    try:
        with open(f"{USERS_DIR}/{u}.conf") as f:
            for l in f:
                if "=" in l:
                    k, v = l.strip().split("=", 1)
                    d[k] = v
    except Exception: pass
    return d


def acc_info(u, online, shadow):
    d = read_conf(u)
    lk, ex = shadow.get(u, (False, ""))
    exp = date(1970, 1, 1) + timedelta(days=int(ex)) if ex.strip().isdigit() else None
    left = (exp - date.today()).days if exp else None
    try: used = round(float(d.get("USED_MB") or 0) / 1024, 2)
    except ValueError: used = 0.0
    return dict(u=u, exists=u in shadow, locked=lk, exp=exp, left=left, expired=bool(exp and left < 0),
                ip=d["IP_LIMIT"], gb=d["GB_LIMIT"], used=used, on=online.get(u, 0))


def acc_state(a):
    if not a["exists"]: return "off", "⚪", "Removed"
    if a["expired"]: return "off", "🟠", "Expired"
    if a["locked"]: return "off", "🔒", "Locked"
    if a["on"]: return "on", "🟢", f"Online ({a['on']} device{'s' if a['on'] > 1 else ''})"
    return "off", "🔴", "Offline"


def acc_line(a):
    _, icon, st = acc_state(a)
    left = "never" if a["exp"] is None else (f"{a['left']}d left" if a["left"] >= 0 else "expired")
    return f"{icon} <b>{e(a['u'])}</b> — {st}\n      📅 {left} • 💾 {a['used']}/{e(gb_text(a['gb']).replace(' GB', ''))} GB • 🌐 IP {e(a['ip'])}"


def account_card(u, p, exp, ip_limit, gb_limit, title="✅ <b>Account Created</b>"):
    c = panel_cfg()
    try: sp = int(c.get("ssh_port") or 8443)
    except ValueError: sp = 8443
    host = (c.get("domain") or "").strip()
    if not host:
        d = get_domain()
        host = d if d != "No Domain Set" else (public_ip() or "your-server")
    payload = f"GET /artricks HTTP/1.1[crlf]Host: {host}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
    ports = ", ".join(dict.fromkeys(str(x) for x in (sp, 109, 447)))
    return (f"{title}\n\nHost: <code>{e(host)}</code>\nUsername: <code>{e(u)}</code>\nPassword: <code>{e(p)}</code>\n"
            f"Expiry: <code>{e(exp)}</code>\nIP Limit: <code>{e(ip_limit)}</code>\nData: <code>{e(gb_text(gb_limit))}</code>\n\n"
            f"SSH Direct: {ports}\nSSH WS (HTTP): 80\nSSH WS (SSL): 443\n\nPayload:\n<code>{e(payload)}</code>")


# ---------------------------------------------------------------- validators
def v_new_username(s):
    s = s.strip().lower()
    if not re.match(r"^[a-z][a-z0-9_]{2,19}$", s): return False, "Username must be 3–20 chars: a-z, 0-9, _ and start with a letter."
    try:
        pwd.getpwnam(s); return False, "This username is already taken. Try another one."
    except KeyError: pass
    if os.path.exists(f"{USERS_DIR}/{s}.conf") or acc_owner(s) is not None: return False, "This username is already taken. Try another one."
    return True, s


def v_password(s):
    s = s.strip()
    if not re.match(r"^[A-Za-z0-9@#%+=_.,!-]{4,32}$", s): return False, "Password must be 4–32 chars (letters, numbers, @ # % + = _ . , ! -), no spaces."
    return True, s


def v_uid(s):
    s = s.strip()
    if s.startswith("@"):
        with dbc() as c: r = c.execute("SELECT id FROM users WHERE lower(username)=?", (s[1:].lower(),)).fetchone()
        return (True, r["id"]) if r else (False, "Is username ka user bot database mein nahi mila.")
    if not s.isdigit(): return False, "Sirf numeric Telegram ID (ya @username) bhejein."
    if not get_user(int(s)): return False, "Ye user bot database mein nahi hai (usne bot start nahi kiya)."
    return True, int(s)


def v_int(lo, hi):
    def f(s):
        s = s.strip()
        if not s.isdigit() or not (lo <= int(s) <= hi): return False, f"Number {lo} se {hi} ke beech bhejein."
        return True, int(s)
    return f


def v_gb(s):
    s = s.strip().lower()
    if s in ("unlimited", "0", "unl"): return True, "Unlimited"
    try: f = float(s)
    except ValueError: return False, "Number bhejein (e.g. 5) ya Unlimited."
    if not (0 < f <= 100000): return False, "GB 0 se zyada hona chahiye."
    return True, f"{f:g}"


def v_old_username(s):
    s = s.strip()
    return (True, s) if valid_username(s) else (False, "Invalid username.")


def v_link(s):
    s = s.strip()
    return (True, s) if re.match(r"^https://t\.me/\S+$", s) else (False, "Link https://t.me/... format mein bhejein.")


# ---------------------------------------------------------------------- flows
FLOWS.update({
    "credit_add": [("uid", "👤 Jis user ko points dene hain uska Telegram ID (ya @username) bhejein:"), ("amount", "💰 Kitne points add karne hain?")],
    "credit_rm": [("uid", "👤 Jis user ke points kaatne hain uska Telegram ID (ya @username) bhejein:"), ("amount", "➖ Kitne points remove karne hain?")],
    "set_ppr": [("value", "🎁 Ek refer par kitne points milen? (number)")],
    "set_rpa": [("value", "🔗 Ek SSH account banane ke liye kitne refer chahiye? (number)")],
    "set_days": [("value", "📅 Bot se bane account ki validity kitne days ki ho? (number)")],
    "set_gb": [("value", "💾 Account ka data limit kitne GB ho? (number ya Unlimited)")],
    "set_ip": [("value", "🌐 Account ki IP limit kitni ho? (number)")],
    "user_info": [("uid", "🔎 User ka Telegram ID (ya @username) bhejein:")],
    "ban": [("uid", "🚫 Ban karne wale user ka Telegram ID (ya @username) bhejein:")],
    "unban": [("uid", "✅ Unban karne wale user ka Telegram ID (ya @username) bhejein:")],
    "chan_add": [("value", "📺 Channel ka @username ya ID (-100...) bhejein.\n⚠️ Pehle bot ko us channel mein <b>Admin</b> banayein, warna join check nahi ho sakta.")],
    "chan_link": [("value", "🔗 Is channel ka invite link bhejein (https://t.me/...):")],
    "broadcast": [("msg", "📢 Jo message sab users ko bhejna hai wo bhejein (text / photo / video — jaisa hai waisa jayega).\n/cancel se cancel.")],
    "u_add": [("username", "✍️ Send the <b>username</b> for your new account.\n(3–20 chars: a-z, 0-9, _ — must start with a letter)"),
              ("password", "🔑 Now send the <b>password</b> (4–32 chars: letters, numbers, @ # _ . -).")],
})

VALID = {
    ("u_add", "username"): v_new_username, ("u_add", "password"): v_password,
    ("credit_add", "uid"): v_uid, ("credit_add", "amount"): v_int(1, 1000000),
    ("credit_rm", "uid"): v_uid, ("credit_rm", "amount"): v_int(1, 1000000),
    ("user_info", "uid"): v_uid, ("ban", "uid"): v_uid, ("unban", "uid"): v_uid,
    ("set_ppr", "value"): v_int(1, 1000), ("set_rpa", "value"): v_int(1, 1000),
    ("set_days", "value"): v_int(1, 3650), ("set_gb", "value"): v_gb, ("set_ip", "value"): v_int(1, 100),
    ("chan_link", "value"): v_link,
    ("add_user", "username"): v_old_username, ("add_user", "password"): v_password,
    ("add_user", "days"): v_int(1, 3650), ("add_user", "ip_limit"): v_int(1, 100), ("add_user", "gb_limit"): v_gb,
    ("renew_user", "username"): v_old_username, ("renew_user", "days"): v_int(1, 3650),
    ("ip_limit", "username"): v_old_username, ("ip_limit", "value"): v_int(1, 100),
    ("gb_limit", "username"): v_old_username, ("gb_limit", "value"): v_gb,
    ("del_user", "username"): v_old_username,
}
ADMIN_ONLY_FLOWS = {"add_admin", "remove_admin"}  # super admin only


# ------------------------------------------------------------------- screens
async def screen(update, text, markup=None, parse="HTML"):
    q = update.callback_query
    try:
        if q: await q.edit_message_text(text, parse_mode=parse, reply_markup=markup, disable_web_page_preview=True)
        else: await update.effective_message.reply_text(text, parse_mode=parse, reply_markup=markup, disable_web_page_preview=True)
    except BadRequest as ex:
        if "not modified" in str(ex).lower(): return
        log.warning("screen edit failed: %s", ex)
        await update.effective_chat.send_message(text, parse_mode=parse, reply_markup=markup, disable_web_page_preview=True)


async def alert(update, context, text):
    q = update.callback_query
    if q and not context.user_data.get("_ans"):
        context.user_data["_ans"] = True
        try: await q.answer(text, show_alert=True)
        except TelegramError: pass


def back_kb(data="back_main", label="⬅️ Back"): return KB([[B(label, data)]])


# ---------------- user side
async def _is_member(bot, ch, uid):
    try:
        m = await bot.get_chat_member(int(ch["chat_id"]), uid)
        return m.status in ("member", "administrator", "creator") or (m.status == "restricted" and getattr(m, "is_member", False))
    except Exception as ex:
        log.warning("join check failed for %s: %s", ch["title"], ex)
        return False


async def check_joined(bot, uid, force=False):
    chs = get_channels()
    if not chs: return True, []
    if not force and _JOINED.get(uid, 0) > time.time(): return True, []
    res = await asyncio.gather(*(_is_member(bot, ch, uid) for ch in chs))
    missing = [ch for ch, ok in zip(chs, res) if not ok]
    if missing: _JOINED.pop(uid, None)
    else:
        if len(_JOINED) > 5000:
            now = time.time()
            for k in [k for k, t in _JOINED.items() if t <= now]: _JOINED.pop(k, None)
        _JOINED[uid] = time.time() + JOIN_TTL
    return (not missing), missing


def join_screen(missing=None):
    chs = missing if missing else get_channels()
    rows = [[B(f"📢 Join {c['title']}", url=c["link"])] for c in chs if str(c["link"]).startswith("http")]
    rows.append([B("✅ Verify", "u_verify")])
    return ("👋 <b>Welcome to AliRaza SSH MANAGEMENT</b>\n\n📢 Please join all the channels below, then press <b>✅ Verify</b> to continue."), KB(rows)


async def gate(update, context, force=False):
    """Every user action passes here: banned -> stop, channels not joined -> join screen, else returns the user row."""
    u = update.effective_user
    row = get_user(u.id)
    if not row:
        upsert_user(u)
        row = get_user(u.id)
    if row["banned"]:
        await alert(update, context, "🚫 You are banned from this bot.")
        if not update.callback_query: await update.effective_message.reply_text("🚫 You are banned from this bot.")
        return None
    if is_admin(u.id): return row   # admins skip channel verification
    ok, missing = await check_joined(context.bot, u.id, force)
    if not ok:
        await alert(update, context, "❌ You have not joined all channels yet.")
        txt, kb = join_screen(missing)
        await screen(update, txt, kb)
        return None
    if row["verified"]: return row          # already verified: no DB write on every click
    paid = mark_verified(u.id)
    if paid:
        try: await context.bot.send_message(paid[0], f"🎉 <b>New referral!</b> A user joined with your link.\n💰 +{paid[1]} point(s) added.", parse_mode="HTML")
        except Exception: pass
    return get_user(u.id)


def ref_link(botname, uid): return f"https://t.me/{botname}?start=ref{uid}"


def user_panel(row, botname):
    ppr, rpa = int(get_set("ppr")), int(get_set("rpa"))
    cost_line = "Free (admin)" if is_admin(row["id"]) else f"{ppr * rpa} point(s) ({rpa} referral(s))"
    txt = (f"🔥 <b>AliRaza SSH MANAGEMENT</b>\n\n👤 ID: <code>{row['id']}</code>\n💰 Points: <b>{row['points']}</b>\n👥 Referrals: <b>{row['refs']}</b>\n\n"
           f"🎁 1 referral = {ppr} point(s)\n🛒 1 account = {cost_line}\n"
           f"📦 Plan: {get_set('days')} days • {e(gb_text(get_set('gb')))} • {get_set('ip')} IP")
    rows = [[B("➕ Add Account", "u_add"), B("🗑 Delete Account", "u_del")], [B("📋 My Accounts", "u_my"), B("🎁 Invite Center", "u_inv")]]
    if is_admin(row["id"]): rows.append([B("🛠 Admin Panel", "back_main")])
    return txt, KB(rows)


def invite_kb():
    return KB([[B("🟢 Invite Link", "u_link", style="success"), B("🔴 Check Invite Stat", "u_stat", style="danger")], [B("⬅️ Back", "u_home")]])


async def invite_center(update, context, row):
    ppr = int(get_set("ppr"))
    await screen(update, f"🎁 <b>Invite Center</b>\n\nInvite friends with your link. When a friend joins the channels and verifies, you get <b>{ppr}</b> point(s).\n\n"
                         f"💰 Your points: <b>{row['points']}</b>", invite_kb())


async def invite_link(update, context, row):
    link = ref_link(context.bot.username, row["id"])
    share = "https://t.me/share/url?url=" + quote(link, safe="") + "&text=" + quote("Get a free SSH account on AliRaza SSH MANAGEMENT!", safe="")
    await screen(update, f"🔗 <b>Your Invite Link</b>\n\n<code>{link}</code>\n\nShare it with your friends. Each verified friend = <b>{int(get_set('ppr'))}</b> point(s).",
                 KB([[B("📤 Share Link", url=share)], [B("⬅️ Invite Center", "u_inv")]]))


def invite_stat_text(uid):
    with dbc() as c:
        tot = c.execute("SELECT COUNT(*) FROM users WHERE referrer=?", (uid,)).fetchone()[0]
        paid = c.execute("SELECT COUNT(*) FROM users WHERE referrer=? AND ref_paid=1", (uid,)).fetchone()[0]
        recent = c.execute("SELECT name, username, ref_paid FROM users WHERE referrer=? ORDER BY joined DESC LIMIT 10", (uid,)).fetchall()
        pts = c.execute("SELECT points FROM users WHERE id=?", (uid,)).fetchone()["points"]
    lines = "\n".join(f"{'✅' if r['ref_paid'] else '⏳'} {e(r['name'] or '?')}" + (f" (@{e(r['username'])})" if r["username"] else "") for r in recent)
    return (f"📊 <b>Invite Stats</b>\n\n👥 Total invited: <b>{tot}</b>\n✅ Verified (points paid): <b>{paid}</b>\n⏳ Pending (not verified yet): <b>{tot - paid}</b>\n"
            f"💰 Your points: <b>{pts}</b>  (1 referral = {int(get_set('ppr'))} point(s))" + (f"\n\n<b>Recent invites</b>\n{lines}" if lines else ""))


async def invite_stat(update, context, row):
    await screen(update, await aio(invite_stat_text, row["id"]), KB([[B("🔄 Refresh", "u_stat")], [B("⬅️ Invite Center", "u_inv")]]))


async def user_home(update, context, force=False):
    row = await gate(update, context, force)
    if not row: return
    txt, kb = user_panel(row, context.bot.username)
    await screen(update, txt, kb)


async def user_my(update, context, row):
    names = await aio(own_accounts, row["id"])
    if not names:
        await screen(update, "📋 <b>My Accounts</b>\n\nYou have no accounts yet.", back_kb("u_home"))
        return
    online, sh_ = await aio(get_online, True), await aio(shadow_info)
    infos = [acc_info(n, online, sh_) for n in names]
    on = sum(1 for a in infos if acc_state(a)[0] == "on")
    body = "\n\n".join(acc_line(a) for a in infos[:15])
    more = f"\n\n…and {len(infos) - 15} more" if len(infos) > 15 else ""
    await screen(update, f"📋 <b>My Accounts</b>  (🟢 {on} online / {len(infos)})\n\n{body}{more}", KB([[B("🔄 Refresh", "u_my")], [B("⬅️ Back", "u_home")]]))


async def user_add_start(update, context, row):
    cost = eff_cost(row["id"])
    if row["points"] < cost:
        link = ref_link(context.bot.username, row["id"])
        need = cost - row["points"]
        ppr = int(get_set("ppr"))
        await screen(update, f"❌ <b>Not enough points</b>\n\nAn account costs <b>{cost}</b> point(s), you have <b>{row['points']}</b>.\n"
                             f"You need <b>{need}</b> more (≈ {-(-need // ppr)} referral(s)).\n\n🔗 Share your link:\n<code>{link}</code>", back_kb("u_home"))
        return
    context.user_data.update(flow="u_add", step=0, data={})
    await screen(update, FLOWS["u_add"][0][1], back_kb("u_home", "❌ Cancel"))


async def user_confirm(update, context, data):
    row = get_user(update.effective_user.id)
    context.user_data["pending"] = {"username": data["username"], "password": data["password"]}
    cost = eff_cost(row["id"])
    await screen(update, f"🛒 <b>Confirm new account</b>\n\n👤 Username: <code>{e(data['username'])}</code>\n🔑 Password: <code>{e(data['password'])}</code>\n"
                         f"📅 Validity: {get_set('days')} days\n💾 Data: {e(gb_text(get_set('gb')))}\n🌐 IP limit: {get_set('ip')}\n\n"
                         + ("💰 Cost: <b>Free</b> (admin)" if not cost else f"💰 Cost: <b>{cost}</b> point(s) (you have {row['points']})"),
                 KB([[B("✅ Confirm", "u_addok"), B("❌ Cancel", "u_home")]]))


async def user_create(update, context):
    uid = update.effective_user.id
    pend = context.user_data.pop("pending", None)
    if not pend:
        await screen(update, "⌛ Session expired. Please start again.", back_kb("u_home"))
        return
    async with LOCKS[uid]:
        row = get_user(uid)
        cost = eff_cost(uid)
        if row["points"] < cost:
            await screen(update, "❌ Not enough points.", back_kb("u_home"))
            return
        ok, name = v_new_username(pend["username"])
        if not ok:
            await screen(update, f"❌ {e(name)}", back_kb("u_home"))
            return
        days, gb, ipl = int(get_set("days")), get_set("gb"), int(get_set("ip"))
        ok, info = await aio(add_user, name, pend["password"], days, ipl, gb)
        if not ok:
            await screen(update, f"❌ Account could not be created: {e(info)}", back_kb("u_home"))
            return
        if not await aio(finalize_purchase, uid, name, cost):
            await aio(delete_user, name)
            await screen(update, "❌ Not enough points.", back_kb("u_home"))
            return
        _OC[0] = 0
    card = await aio(account_card, name, pend["password"], info, ipl, gb)
    await screen(update, card + f"\n\n💰 Points left: {get_user(uid)['points']}", back_kb("u_home"))


async def user_del_list(update, context, row):
    names = await aio(own_accounts, row["id"])
    if not names:
        await screen(update, "🗑 <b>Delete Account</b>\n\nYou have no accounts to delete.", back_kb("u_home"))
        return
    rows, line = [], []
    for n in names[:40]:
        line.append(B(f"🗑 {n}", f"u_dsel:{n}"))
        if len(line) == 2: rows.append(line); line = []
    if line: rows.append(line)
    rows.append([B("⬅️ Back", "u_home")])
    await screen(update, "🗑 <b>Delete Account</b>\n\nSelect the account you want to delete (only accounts you created are listed):", KB(rows))


async def user_callbacks(update, context, data):
    uid = update.effective_user.id
    if data in ("u_verify", "u_home"):
        context.user_data["flow"] = None
        return await user_home(update, context, force=(data == "u_verify"))
    row = await gate(update, context)
    if not row: return
    if data == "u_my": return await user_my(update, context, row)
    if data == "u_inv": return await invite_center(update, context, row)
    if data == "u_link": return await invite_link(update, context, row)
    if data == "u_stat": return await invite_stat(update, context, row)
    if data == "u_add": return await user_add_start(update, context, row)
    if data == "u_addok": return await user_create(update, context)
    if data == "u_del": return await user_del_list(update, context, row)
    if data.startswith("u_dsel:") or data.startswith("u_ddo:"):
        act, name = data.split(":", 1)
        if acc_owner(name) != uid:
            await alert(update, context, "This account is not yours.")
            return
        if act == "u_dsel":
            await screen(update, f"⚠️ Delete account <code>{e(name)}</code>?\n\nThis cannot be undone and points are <b>not</b> refunded.",
                         KB([[B("✅ Yes, delete", f"u_ddo:{name}"), B("❌ Cancel", "u_home")]]))
        else:
            ok = await aio(delete_user, name)
            await screen(update, "✅ Account deleted." if ok else "❌ Delete failed, please try again or contact admin.", back_kb("u_home"))


# ---------------- admin side
def stats():
    sync_accounts()
    with dbc() as c:
        g = lambda q: c.execute(q).fetchone()[0] or 0
        s = dict(users=g("SELECT COUNT(*) FROM users"), verified=g("SELECT COUNT(*) FROM users WHERE verified=1"),
                 banned=g("SELECT COUNT(*) FROM users WHERE banned=1"), pts=g("SELECT SUM(points) FROM users"),
                 accs=g("SELECT COUNT(*) FROM accounts"))
        names = [r["username"] for r in c.execute("SELECT username FROM accounts")]
    on = get_online(True)
    s["on"] = sum(1 for n in names if on.get(n))
    return s


def admin_keyboard(uid):
    rows = [
        [B("➕ Add Credit", "credit_add"), B("➖ Remove Credit", "credit_rm")],
        [B("👥 All Accounts", "al:all:0"), B("🔎 User Info", "user_info")],
        [B("📢 Broadcast", "broadcast"), B("📺 Channels", "ch")],
        [B("⚙️ Bot Settings", "st"), B("🛠 VPS Tools", "tools")],
        [B("🚫 Ban User", "ban"), B("✅ Unban User", "unban")],
        [B("👤 User Panel", "u_home")],
    ]
    if is_super(uid): rows.append([B("👑 Admin Management", "admin_mgmt")])
    rows.append([B("🔄 Refresh Panel", "refresh")])
    return KB(rows)


async def admin_home(update, context):
    s = await aio(stats)
    txt = (f"👋 <b>Welcome to {e(PANEL_NAME)} — Admin Panel</b>\n\n👥 Users: <b>{s['users']}</b>  (✅ {s['verified']} verified • 🚫 {s['banned']} banned)\n"
           f"🔑 Bot accounts: <b>{s['accs']}</b>  (🟢 {s['on']} online)\n💰 Points in wallets: <b>{s['pts']}</b>\n"
           f"🛒 Account cost: {cost_points()} point(s)\n\n🕒 Updated: {datetime.now().strftime('%H:%M:%S')}")
    await screen(update, txt, admin_keyboard(update.effective_user.id))


def tools_keyboard():
    return KB([
        [B("➕ Add User", "add_user"), B("🗑 Delete User", "del_user")],
        [B("📋 User List", "list_users"), B("⏳ Renew User", "renew_user")],
        [B("🌐 IP Limit", "ip_limit"), B("💾 GB Limit", "gb_limit")],
        [B("🔌 Connected IPs", "conn_ips"), B("⚙️ Status", "sys_status")],
        [B("🌍 Domain", "domain"), B("🔒 SSL", "ssl")],
        [B("📢 Banner", "banner"), B("🛠 Fix WebSocket", "fix_ws")],
        [B("📦 Install Components", "install"), B("🧨 Uninstall Panel", "uninstall")],
        [B("⬅️ Back", "back_main")],
    ])


def settings_screen():
    ppr, rpa = int(get_set("ppr")), int(get_set("rpa"))
    txt = (f"⚙️ <b>Bot Settings</b>\n\n🎁 Points per referral: <b>{ppr}</b>\n🔗 Referrals per account: <b>{rpa}</b>\n"
           f"🛒 Account cost: <b>{ppr * rpa}</b> point(s)\n📅 Validity: <b>{get_set('days')}</b> days\n💾 Data: <b>{e(gb_text(get_set('gb')))}</b>\n🌐 IP limit: <b>{get_set('ip')}</b>")
    kb = KB([[B("🎁 Points / refer", "set_ppr"), B("🔗 Refers / account", "set_rpa")],
             [B("📅 Days", "set_days"), B("💾 GB", "set_gb")], [B("🌐 IP limit", "set_ip")], [B("⬅️ Back", "back_main")]])
    return txt, kb


def channels_screen():
    chs = get_channels()
    txt = "📺 <b>Required Channels</b>\n\n" + ("\n".join(f"{i}. {e(c['title'])}  <code>{e(c['chat_id'])}</code>" for i, c in enumerate(chs, 1)) if chs else "Koi channel set nahi hai (verification off).")
    rows = [[B(f"❌ Remove {c['title'][:24]}", f"ch_rm:{c['id']}")] for c in chs]
    rows += [[B("➕ Add Channel", "chan_add")], [B("⬅️ Back", "back_main")]]
    return txt, KB(rows)


def accounts_view(filt, page):
    sync_accounts()
    online, shadow = get_online(True), shadow_info()
    with dbc() as c:
        rows = c.execute("SELECT a.username, a.owner, u.name, u.username AS tg FROM accounts a LEFT JOIN users u ON u.id=a.owner ORDER BY a.created DESC").fetchall()
    items = []
    for r in rows:
        a = acc_info(r["username"], online, shadow)
        items.append((acc_state(a)[0], a, r))
    n_on = sum(1 for i in items if i[0] == "on")
    sel = [i for i in items if filt == "all" or i[0] == filt]
    pages = max(1, -(-len(sel) // PAGE))
    page = min(max(page, 0), pages - 1)
    chunk = sel[page * PAGE:(page + 1) * PAGE]
    lines = []
    for _, a, r in chunk:
        owner = f"{e(r['name'] or '?')}" + (f" (@{e(r['tg'])})" if r["tg"] else "") + f" <code>{r['owner']}</code>"
        lines.append(f"{acc_line(a)}\n      👤 {owner}")
    title = {"all": "All", "on": "🟢 Online", "off": "🔴 Offline"}[filt]
    txt = (f"👥 <b>Bot Users' Accounts — {title}</b>\n🟢 Online: <b>{n_on}</b>  •  🔴 Offline: <b>{len(items) - n_on}</b>  •  Total: <b>{len(items)}</b>\n\n"
           + ("\n\n".join(lines) if lines else "Koi account nahi mila."))
    nav = []
    if page > 0: nav.append(B("◀️ Prev", f"al:{filt}:{page - 1}"))
    nav.append(B(f"{page + 1}/{pages}", f"al:{filt}:{page}"))
    if page < pages - 1: nav.append(B("Next ▶️", f"al:{filt}:{page + 1}"))
    kb = KB([[B("All", "al:all:0"), B("🟢 Online", "al:on:0"), B("🔴 Offline", "al:off:0")], nav, [B("🔄 Refresh", f"al:{filt}:{page}"), B("⬅️ Back", "back_main")]])
    return txt[:4000], kb


def user_info_text(uid):
    r = get_user(uid)
    accs = own_accounts(uid)
    ref = f"<code>{r['referrer']}</code>" if r["referrer"] else "—"
    return (f"🔎 <b>User Info</b>\n\n👤 {e(r['name'] or '?')}" + (f" (@{e(r['username'])})" if r["username"] else "") + f"\n🆔 <code>{r['id']}</code>\n"
            f"💰 Points: <b>{r['points']}</b>\n👥 Referrals: <b>{r['refs']}</b>\n🔗 Referred by: {ref}\n✅ Verified: {'yes' if r['verified'] else 'no'}\n"
            f"🚫 Banned: {'yes' if r['banned'] else 'no'}\n🔑 Accounts ({len(accs)}): " + (", ".join(f"<code>{e(a)}</code>" for a in accs) or "—"))


async def run_broadcast(bot, admin_id, src_chat, src_msg):
    with dbc() as c: ids = [r["id"] for r in c.execute("SELECT id FROM users WHERE banned=0")]
    ok = blocked = fail = 0
    for uid in ids:
        try:
            await bot.copy_message(uid, src_chat, src_msg)
            ok += 1
        except RetryAfter as ex:
            ra = ex.retry_after
            await asyncio.sleep((ra.total_seconds() if hasattr(ra, "total_seconds") else ra) + 1)
            try:
                await bot.copy_message(uid, src_chat, src_msg)
                ok += 1
            except Exception: fail += 1
        except Forbidden: blocked += 1
        except Exception: fail += 1
        await asyncio.sleep(0.05)
    try: await bot.send_message(admin_id, f"📢 <b>Broadcast complete</b>\n\n✅ Sent: {ok}\n🚫 Blocked bot: {blocked}\n⚠️ Failed: {fail}", parse_mode="HTML")
    except Exception: pass


async def add_channel(raw, update, context):
    raw = raw.strip()
    m = re.match(r"^https?://t\.me/([A-Za-z0-9_]{4,})/?$", raw)
    ref = "@" + m.group(1) if m else (raw if raw.startswith("@") or re.match(r"^-?\d+$", raw) else "@" + raw)
    if re.match(r"^-?\d+$", ref): ref = int(ref)
    msg = update.effective_message
    try: chat = await context.bot.get_chat(ref)
    except TelegramError as ex:
        await msg.reply_text(f"❌ Channel nahi mila: {ex}", reply_markup=back_kb())
        return
    if chat.type not in ("channel", "supergroup", "group"):
        await msg.reply_text("❌ Ye channel/group nahi hai.", reply_markup=back_kb())
        return
    try: me = await context.bot.get_chat_member(chat.id, context.bot.id)
    except TelegramError: me = None
    if not me or me.status not in ("administrator", "creator"):
        await msg.reply_text("❌ Bot is channel mein Admin nahi hai. Pehle bot ko Admin banayein, phir dobara Add Channel karein.", reply_markup=back_kb())
        return
    link = f"https://t.me/{chat.username}" if chat.username else (chat.invite_link or None)
    if not link:
        try: link = await context.bot.export_chat_invite_link(chat.id)
        except TelegramError: link = None
    if not link:
        context.user_data.update(flow="chan_link", step=0, data={}, pending=(chat.id, chat.title))
        await msg.reply_text(FLOWS["chan_link"][0][1], parse_mode="HTML")
        return
    if save_channel(chat.id, chat.title, link): await msg.reply_text(f"✅ Channel added: {e(chat.title)}", parse_mode="HTML", reply_markup=back_kb("ch", "⬅️ Channels"))
    else: await msg.reply_text("⚠️ Ye channel pehle se added hai.", reply_markup=back_kb("ch", "⬅️ Channels"))


async def finish_flow(flow, data, update, context):
    msg = update.effective_message
    ok_kb = back_kb()
    if flow == "u_add": return await user_confirm(update, context, data)
    if flow in ("credit_add", "credit_rm"):
        amt = data["amount"] if flow == "credit_add" else -data["amount"]
        r = add_points(data["uid"], amt)
        if not r:
            await msg.reply_text("❌ User nahi mila.", reply_markup=ok_kb)
            return
        done = r[1] - r[0]
        await msg.reply_text(f"✅ {'Added' if done >= 0 else 'Removed'} <b>{abs(done)}</b> point(s) • User <code>{data['uid']}</code>: {r[0]} → <b>{r[1]}</b>", parse_mode="HTML", reply_markup=ok_kb)
        if done:
            try: await context.bot.send_message(data["uid"], f"💰 Admin ne aapke account mein <b>{abs(done)}</b> point(s) {'add' if done > 0 else 'remove'} kiye.\nBalance: <b>{r[1]}</b>", parse_mode="HTML")
            except Exception: pass
        return
    if flow in ("set_ppr", "set_rpa", "set_days", "set_gb", "set_ip"):
        set_set(flow[4:], data["value"])
        txt, kb = settings_screen()
        await msg.reply_text("✅ Saved.\n\n" + txt, parse_mode="HTML", reply_markup=kb)
        return
    if flow == "user_info":
        await msg.reply_text(await aio(user_info_text, data["uid"]), parse_mode="HTML", reply_markup=ok_kb)
        return
    if flow in ("ban", "unban"):
        if flow == "ban" and (is_admin(data["uid"])):
            await msg.reply_text("❌ Admin ko ban nahi kar sakte.", reply_markup=ok_kb)
            return
        with dbc() as c: c.execute("UPDATE users SET banned=? WHERE id=?", (1 if flow == "ban" else 0, data["uid"]))
        await msg.reply_text(f"✅ User <code>{data['uid']}</code> {'banned' if flow == 'ban' else 'unbanned'}.", parse_mode="HTML", reply_markup=ok_kb)
        return
    if flow == "chan_add": return await add_channel(data["value"], update, context)
    if flow == "chan_link":
        pend = context.user_data.pop("pending", None)
        if not pend:
            await msg.reply_text("⌛ Session expired.", reply_markup=ok_kb)
            return
        save_channel(pend[0], pend[1], data["value"])
        await msg.reply_text(f"✅ Channel added: {e(pend[1])}", parse_mode="HTML", reply_markup=back_kb("ch", "⬅️ Channels"))
        return
    if flow == "broadcast":
        context.user_data["bc"] = (update.effective_chat.id, data["msg"])
        with dbc() as c: n = c.execute("SELECT COUNT(*) FROM users WHERE banned=0").fetchone()[0]
        await msg.reply_text(f"📢 Ye message <b>{n}</b> users ko bheja jayega. Confirm?", parse_mode="HTML",
                             reply_markup=KB([[B("✅ Send to all", "bc_go"), B("❌ Cancel", "back_main")]]))
        return
    # ---- existing VPS tools (admin) ----
    if flow == "del_user":
        kb = KB([[B("✅ Confirm Delete", f"do_del:{data['username']}"), B("❌ Cancel", "back_main")]])
        await msg.reply_text(f"⚠️ '{data['username']}' delete karna confirm karein:", reply_markup=kb)
        return
    if flow == "remove_admin":
        target = int(data["value"]) if str(data["value"]).lstrip("-").isdigit() else None
        if target is None:
            await msg.reply_text("❌ Invalid ID.")
            return
        if target == load_config().get("super_admin"):
            await msg.reply_text("❌ Super admin remove nahi ho sakta.")
            return
        kb = KB([[B("✅ Confirm Remove", f"rm_admin:{target}"), B("❌ Cancel", "back_main")]])
        await msg.reply_text(f"⚠️ Admin {target} remove karna confirm karein:", reply_markup=kb)
        return
    if flow == "add_user":
        ok, info = await aio(add_user, data["username"], data["password"], data["days"], data["ip_limit"], data["gb_limit"])
        if ok: await msg.reply_text(await aio(account_card, data["username"], data["password"], info, data["ip_limit"], data["gb_limit"]), parse_mode="HTML", reply_markup=ok_kb)
        else: await msg.reply_text(f"❌ User create fail: {info}", reply_markup=ok_kb)
    elif flow == "renew_user":
        ok = await aio(renew_user, data["username"], data["days"])
        await msg.reply_text("✅ Renewed." if ok else "❌ User not found.", reply_markup=ok_kb)
    elif flow == "ip_limit":
        ok = await aio(update_conf_field, data["username"], "IP_LIMIT", data["value"])
        await msg.reply_text("✅ IP limit updated." if ok else "❌ User config not found.", reply_markup=ok_kb)
    elif flow == "gb_limit":
        ok = await aio(update_conf_field, data["username"], "GB_LIMIT", data["value"])
        await msg.reply_text("✅ GB limit updated." if ok else "❌ User config not found.", reply_markup=ok_kb)
    elif flow == "domain":
        if not re.match(r"^[A-Za-z0-9.-]+$", data["value"]):
            await msg.reply_text("❌ Invalid domain.", reply_markup=ok_kb)
            return
        await aio(set_domain, data["value"])
        await msg.reply_text(f"✅ Domain set to {data['value']}", reply_markup=ok_kb)
    elif flow == "banner":
        txt = data["value"]
        if len(txt.encode()) > 2000:
            await msg.reply_text("❌ Banner bohat bara hai (max 2000 bytes).", reply_markup=ok_kb)
            return
        old = open(BANNER_FILE, encoding="utf-8").read() if os.path.exists(BANNER_FILE) else None
        with open(BANNER_FILE, "w", encoding="utf-8") as f: f.write(txt if txt.strip() else "\n")
        await aio(sh, ["systemctl", "restart", "dropbear"])
        await asyncio.sleep(1)
        if (await aio(sh, ["systemctl", "is-active", "dropbear"])).stdout.strip() != "active":
            if old is not None:
                with open(BANNER_FILE, "w", encoding="utf-8") as f: f.write(old)
            await aio(sh, ["systemctl", "restart", "dropbear"])
            await msg.reply_text("❌ Dropbear start nahi hua, purana banner restore kar diya.", reply_markup=ok_kb)
            return
        await msg.reply_text("✅ Banner updated.", reply_markup=ok_kb)
    elif flow == "add_admin":
        try: new_id = int(data["value"])
        except ValueError:
            await msg.reply_text("❌ Invalid ID.")
            return
        admins = load_admins()
        if new_id in admins: await msg.reply_text("⚠️ Already an admin.")
        else:
            admins.append(new_id)
            save_admins(admins)
            await set_admin_cmds(context.bot, new_id)
            await msg.reply_text(f"✅ Admin {new_id} added.", reply_markup=admin_menu_keyboard())


# ------------------------------------------------------------- old keyboards
def back_keyboard(): return InlineKeyboardMarkup([[InlineKeyboardButton("\u2B05\uFE0F Back to Menu", callback_data="back_main")]])


def admins_text():
    admins = load_admins()
    lines = ["\U0001F451 *Admin Management*\n"]
    for a in admins:
        tag = " (Super Admin)" if a == load_config().get("super_admin") else ""
        lines.append(f"\u2022 `{a}`{tag}")
    return "\n".join(lines)


def admin_menu_keyboard():
    return InlineKeyboardMarkup([[InlineKeyboardButton("\u2795 Add Admin", callback_data="add_admin"), InlineKeyboardButton("\u2796 Remove Admin", callback_data="remove_admin")], [InlineKeyboardButton("\u2B05\uFE0F Back", callback_data="back_main")]])


# ------------------------------------------------------------------ handlers
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    u = update.effective_user
    arg = context.args[0] if context.args else ""
    ref = int(arg[3:]) if arg.startswith("ref") and arg[3:].isdigit() else None
    upsert_user(u, ref)
    context.user_data["flow"] = None
    if is_admin(u.id): return await admin_home(update, context)
    await user_home(update, context)


USER_CMDS = [BotCommand("start", "Open the menu"), BotCommand("user", "User panel"), BotCommand("invite", "Invite Center"),
             BotCommand("link", "My invite link"), BotCommand("stat", "Check invite stat"), BotCommand("accounts", "My accounts"),
             BotCommand("cancel", "Cancel current action")]


async def set_admin_cmds(bot, uid):
    try: await bot.set_my_commands(USER_CMDS[:1] + [BotCommand("admin", "Admin panel")] + USER_CMDS[1:], scope=BotCommandScopeChat(uid))
    except Exception as ex: log.warning("set admin commands for %s failed: %s", uid, ex)


async def post_init(app):
    try: await app.bot.set_my_commands(USER_CMDS)
    except Exception as ex: log.warning("set commands failed: %s", ex)
    for a in load_admins(): await set_admin_cmds(app.bot, a)


async def cmd_admin(update: Update, context: ContextTypes.DEFAULT_TYPE):
    context.user_data["flow"] = None
    if not is_admin(update.effective_user.id):
        await update.effective_message.reply_text("⛔ Admin only.")
        return
    upsert_user(update.effective_user)
    await admin_home(update, context)


def user_cmd(fn):
    async def run(update: Update, context: ContextTypes.DEFAULT_TYPE):
        upsert_user(update.effective_user)
        context.user_data["flow"] = None
        row = await gate(update, context)
        if row: await fn(update, context, row)
    return run


async def _home(update, context, row):
    txt, kb = user_panel(row, context.bot.username)
    await screen(update, txt, kb)


cmd_user, cmd_invite = user_cmd(_home), user_cmd(invite_center)
cmd_link, cmd_stat, cmd_accounts = user_cmd(invite_link), user_cmd(invite_stat), user_cmd(user_my)


async def cancel(update: Update, context: ContextTypes.DEFAULT_TYPE):
    context.user_data["flow"] = None
    await update.effective_message.reply_text("Cancelled.")


async def msg_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    u, m = update.effective_user, update.effective_message
    if not u or not m: return
    flow = context.user_data.get("flow")
    if not flow:
        if not is_admin(u.id): await m.reply_text("Press /start to open the menu.")
        return
    if flow.startswith("u_"):
        row = await gate(update, context)
        if not row:
            context.user_data["flow"] = None
            return
    elif not is_admin(u.id) or (flow in ADMIN_ONLY_FLOWS and not is_super(u.id)):
        context.user_data["flow"] = None
        return
    steps = FLOWS[flow]
    step = context.user_data.get("step", 0)
    field, _ = steps[step]
    if flow == "broadcast": value = m.message_id
    else:
        value = (m.text or "").strip()
        if not value:
            await m.reply_text("Please send text only.")
            return
        v = VALID.get((flow, field))
        if v:
            ok, res = v(value)
            if not ok:
                await m.reply_text(f"❌ {res}\n\n{steps[step][1]}", parse_mode="HTML")
                return
            value = res
    context.user_data.setdefault("data", {})[field] = value
    step += 1
    if step < len(steps):
        context.user_data["step"] = step
        await m.reply_text(steps[step][1], parse_mode="HTML")
        return
    data = context.user_data["data"]
    context.user_data["flow"] = None
    await finish_flow(flow, data, update, context)


async def admin_callbacks(update, context, data):
    q, uid = update.callback_query, update.effective_user.id
    if data in ("back_main", "refresh"):
        context.user_data["flow"] = None
        return await admin_home(update, context)
    if data in FLOWS and not data.startswith("u_") and data not in ("chan_link",):
        if data in ADMIN_ONLY_FLOWS and not is_super(uid): return
        context.user_data.update(flow=data, step=0, data={})
        return await screen(update, FLOWS[data][0][1], back_kb("back_main", "❌ Cancel"))
    if data == "tools": return await screen(update, "🛠 <b>VPS Tools</b>", tools_keyboard())
    if data == "st": return await screen(update, *settings_screen())
    if data == "ch": return await screen(update, *channels_screen())
    if data.startswith("ch_rm:"):
        with dbc() as c: c.execute("DELETE FROM channels WHERE id=?", (int(data.split(":", 1)[1]),))
        _JOINED.clear()
        return await screen(update, *channels_screen())
    if data.startswith("al:"):
        _, filt, page = data.split(":")
        txt, kb = await aio(accounts_view, filt if filt in ("all", "on", "off") else "all", int(page))
        return await screen(update, txt, kb)
    if data == "bc_go":
        bc = context.user_data.pop("bc", None)
        if not bc: return await screen(update, "⌛ Session expired.", back_kb())
        t = asyncio.create_task(run_broadcast(context.bot, uid, bc[0], bc[1]))
        BG.add(t)
        t.add_done_callback(BG.discard)
        return await screen(update, "📢 Broadcast shuru ho gaya. Complete hone par report milegi.", back_kb())
    if data == "list_users": await q.edit_message_text(await aio(list_users_text), reply_markup=back_keyboard())
    elif data == "conn_ips": await q.edit_message_text(await aio(connected_ips_text), reply_markup=back_keyboard())
    elif data == "sys_status": await q.edit_message_text(await aio(status_text), reply_markup=back_keyboard())
    elif data == "ssl":
        await q.edit_message_text("\U0001F512 SSL issue ho raha hai, wait karein...")
        ok, msg = await asyncio.to_thread(setup_ssl)
        await q.message.reply_text(("\u2705 " if ok else "\u274C ") + msg, reply_markup=back_keyboard())
    elif data == "fix_ws":
        msg = await aio(fix_websocket)
        await q.edit_message_text(f"\u2705 {msg}", reply_markup=back_keyboard())
    elif data == "install":
        await q.edit_message_text("\U0001F4E6 Poora system install ho raha hai, 2-5 min lagega...")
        await asyncio.to_thread(install_components_sync)
        await q.message.reply_text("\u2705 Installation complete!", reply_markup=back_keyboard())
    elif data == "uninstall":
        kb = InlineKeyboardMarkup([[InlineKeyboardButton("\u2705 Haan, Uninstall karein", callback_data="do_uninstall"), InlineKeyboardButton("\u274C Cancel", callback_data="back_main")]])
        await q.edit_message_text("\u26A0\uFE0F Yeh sab kuch permanently remove kar dega. Confirm karein:", reply_markup=kb)
    elif data == "do_uninstall":
        await q.edit_message_text("\U0001F9E8 Uninstalling...")
        await asyncio.to_thread(uninstall_all)
        await q.message.reply_text("\u2705 Uninstall complete.")
        schedule_self_removal()
    elif data == "admin_mgmt":
        if not is_super(uid): return
        await q.edit_message_text(admins_text(), parse_mode="Markdown", reply_markup=admin_menu_keyboard())
    elif data.startswith("do_del:"):
        ok = await aio(delete_user, data.split(":", 1)[1])
        await q.edit_message_text("\u2705 User deleted." if ok else "\u274C Delete nahi hua (account script ka nahi hai ya nahi mila).", reply_markup=back_keyboard())
    elif data.startswith("rm_admin:"):
        if not is_super(uid): return
        target = int(data.split(":", 1)[1])
        admins = load_admins()
        if target in admins and target != load_config().get("super_admin"):
            admins.remove(target)
            save_admins(admins)
        await q.edit_message_text(admins_text(), parse_mode="Markdown", reply_markup=admin_menu_keyboard())


async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    uid, data = q.from_user.id, q.data or ""
    context.user_data["_ans"] = False
    try:
        if data.startswith("u_"):
            await user_callbacks(update, context, data)
        else:
            if not is_admin(uid):
                await alert(update, context, "Access denied.")
                return
            context.user_data["_ans"] = True
            try: await q.answer()
            except TelegramError: pass
            await admin_callbacks(update, context, data)
    except Exception:
        log.exception("button_handler error (%s)", data)
    finally:
        if not context.user_data.get("_ans"):
            try: await q.answer()
            except TelegramError: pass


async def on_error(update, context):
    if isinstance(context.error, NetworkError):
        log.warning("network issue: %s", context.error)
        return
    log.error("Unhandled error", exc_info=context.error)


def serial(fn):
    """Updates of ONE user run strictly in order (flows keep their state); different users run in parallel."""
    async def w(update, context):
        u = update.effective_user
        if not u: return await fn(update, context)
        if len(ULOCKS) > 20000:
            for k in [k for k, l in ULOCKS.items() if not l.locked()]: ULOCKS.pop(k, None)
        lk = ULOCKS.setdefault(u.id, asyncio.Lock())
        async with lk: return await fn(update, context)
    w.__name__ = getattr(fn, "__name__", "handler")
    return w


def main():
    db_init()
    app = (Application.builder().token(load_config()["token"]).post_init(post_init)
           .concurrent_updates(True)            # one slow admin job (install / SSL) no longer freezes every other user
           .connect_timeout(10).read_timeout(20).write_timeout(20).pool_timeout(10)
           .build())
    priv = filters.ChatType.PRIVATE
    app.add_handler(CommandHandler("start", serial(start), filters=priv))
    app.add_handler(CommandHandler("cancel", serial(cancel), filters=priv))
    for name, fn in (("admin", cmd_admin), ("user", cmd_user), ("invite", cmd_invite), ("link", cmd_link), ("stat", cmd_stat), ("accounts", cmd_accounts)):
        app.add_handler(CommandHandler(name, serial(fn), filters=priv))
    app.add_handler(CallbackQueryHandler(serial(button_handler)))
    app.add_handler(MessageHandler(priv & ~filters.COMMAND, serial(msg_handler)))
    app.add_error_handler(on_error)
    app.run_polling(allowed_updates=[Update.MESSAGE, Update.CALLBACK_QUERY], bootstrap_retries=-1)


if __name__ == "__main__":
    main()
TG_EOF
cat > /etc/systemd/system/ws-proxy.service <<'U1'
[Unit]
Description=ALIRAZA WebSocket Proxy
After=network.target network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
RestartSec=2
LimitNOFILE=1048576
LimitMEMLOCK=infinity
TasksMax=infinity
Nice=-15
OOMScoreAdjust=-500
[Install]
WantedBy=multi-user.target
U1
cat > /etc/systemd/system/autokill.service <<'U2'
[Unit]
Description=ALIRAZA Auto-Kill & Bandwidth
After=network.target network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/autokill.py
Restart=always
RestartSec=3
Nice=19
CPUWeight=20
IOSchedulingClass=idle
[Install]
WantedBy=multi-user.target
U2
cat > /etc/systemd/system/tgbot.service <<'U3'
[Unit]
Description=ALIRAZA Telegram Bot
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/rr-tgbot-venv/bin/python3 /usr/local/bin/tgbot.py
Restart=always
RestartSec=3
Nice=5
CPUWeight=50
LimitNOFILE=65535
TimeoutStopSec=15
[Install]
WantedBy=multi-user.target
U3
cat > /etc/systemd/system/aliraza-panel.service <<'U4'
[Unit]
Description=ALIRAZA SSH Panel
After=network.target
StartLimitIntervalSec=0
[Service]
WorkingDirectory=/opt/aliraza-panel
ExecStart=/opt/aliraza-panel/venv/bin/gunicorn -k gthread -w 1 --threads 64 --timeout 120 -b 127.0.0.1:12026 --chdir /opt/aliraza-panel app:app
Restart=always
RestartSec=3
Nice=5
CPUWeight=50
[Install]
WantedBy=multi-user.target
U4
step 3 "Deploying the ALIRAZA control panel"
cat > /opt/aliraza-panel/app.py <<'APP_EOF'
# ALIRAZA SSH Panel backend | Support: @ar_tricks
import os,re,json,time,sqlite3,subprocess,secrets,threading,pty,select,struct,fcntl,termios,codecs,datetime,socket
import psutil
from flask import Flask,request,session,jsonify,send_file
from flask_sock import Sock
from werkzeug.security import generate_password_hash,check_password_hash
D="/etc/artricks";UD=D+"/users";CFG=D+"/panel.json";DB=D+"/panel.db";BANNER=D+"/banner.txt"
DEF={"domain":"","panel_port":2083,"ssh_port":8443}
def cfg():
    try: return {**DEF,**json.load(open(CFG))}
    except Exception: return dict(DEF)
def savecfg(c):
    os.makedirs(D,exist_ok=True);json.dump(c,open(CFG,"w"))
    open(D+"/domain.conf","w").write(c["domain"])
def sh(a,inp=None,t=60):
    try:
        r=subprocess.run(a,input=inp,capture_output=True,text=True,timeout=t);return r.returncode==0,(r.stdout+r.stderr).strip()
    except Exception as e: return False,str(e)
def later(f,s=1.5): threading.Timer(s,f).start()
def ufw(p):
    if sh(["ufw","status"])[1].startswith("Status: active"): sh(["ufw","allow",f"{p}/tcp"])
SSLP='ssl_protocols TLSv1.2 TLSv1.3;ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;ssl_prefer_server_ciphers off;'
PROXY="""        proxy_pass http://127.0.0.1:%s;proxy_http_version 1.1;proxy_set_header Upgrade $http_upgrade;proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;proxy_set_header X-Real-IP $remote_addr;proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;proxy_send_timeout 86400s;proxy_buffering off;proxy_request_buffering off;proxy_connect_timeout 5s;proxy_next_upstream off;proxy_socket_keepalive on;proxy_buffer_size 16k;proxy_buffers 8 16k;"""
def nginx_ver():
    try:
        m=re.search(r"nginx/(\d+)\.(\d+)\.(\d+)",sh(["nginx","-v"])[1]);return tuple(int(x) for x in m.groups())
    except Exception: return (0,0,0)
def apply_nginx():
    c=cfg();d=c["domain"];le=f"/etc/letsencrypt/live/{d}"
    crt,key=(le+"/fullchain.pem",le+"/privkey.pem") if os.path.exists(le+"/fullchain.pem") else (D+"/ssl/self.crt",D+"/ssl/self.key")
    ip6=os.path.exists("/proc/net/if_inet6")
    def L(port,extra=""):
        x=" ".join(t for t in ("listen",str(port),extra) if t)+";"
        return x+(x.replace("listen "+str(port),"listen [::]:"+str(port),1) if ip6 else "")
    H2=nginx_ver()>=(1,25,1);H2D="ssl" if H2 else "ssl http2";H2L="http2 on;" if H2 else ""
    ws=PROXY%2082
    # HTTP/3 (QUIC) only if this nginx build has it (>=1.25.1 with http_v3_module); needs UDP 443 open. WebSocket itself keeps using TCP h1.
    _nv=sh(["nginx","-V"])[1]
    Q=("http_v3" in _nv) and nginx_ver()>=(1,25,1)
    QL=L(443,"quic reuseport") if Q else ""
    QD="http3 on;quic_retry on;add_header Alt-Svc 'h3=\":443\"; ma=86400';" if Q else ""
    if Q and sh(["ufw","status"])[1].startswith("Status: active"): sh(["ufw","allow","443/udp"])
    open("/etc/nginx/conf.d/vpn.conf","w").write(f"""server{{{L(80,"default_server backlog=4096 so_keepalive=20s:10s:5")}server_name {d} _;
 location /{{\n{ws}\n }}\n location /artricks{{\n{ws}\n }}}}
server{{{L(443,"ssl default_server backlog=4096 so_keepalive=20s:10s:5")}{QL}server_name {d} _;ssl_certificate {crt};ssl_certificate_key {key};{SSLP}{QD}
 location /{{\n{ws}\n }}\n location /artricks{{\n{ws}\n }}}}""")
    if Q:
        ok,o=sh(["nginx","-t"])
        if not ok: Q=False;QL=QD="";open("/etc/nginx/conf.d/vpn.conf","w").write(open("/etc/nginx/conf.d/vpn.conf").read().replace("listen 443 quic reuseport;","").replace("listen [::]:443 quic reuseport;","").replace("http3 on;quic_retry on;","").replace("add_header Alt-Svc 'h3=\":443\"; ma=86400';",""))
    open("/etc/nginx/conf.d/panel.conf","w").write(f"""server{{{L(c['panel_port'],H2D)}{H2L}server_name _;ssl_certificate {crt};ssl_certificate_key {key};{SSLP}
 location /{{\n{PROXY%12026}\n }}}}""")
    try: os.remove("/etc/nginx/sites-enabled/default")
    except Exception: pass
    ok,o=sh(["nginx","-t"])
    if ok: ok,o=sh(["systemctl","restart","nginx"])
    return ok,o
BANNER_MAX=2000  # Dropbear refuses to START if the banner file is bigger than this
DEF_BANNER="""<font color="#FF0000">𝗦𝗘𝗥𝗩𝗘𝗥 <font color="#FF0000">𝗕𝗬</font> 𝗔𝗟𝗜𝗥𝗔𝗭𝗔</font>

<font color="#00FFFF">🌐 𝗦𝗦𝗛</font>  •  <font color="#00FF00">𝗩𝗟𝗘𝗦𝗦</font>
<font color="#FF1493">⚡ 𝗩𝗠𝗘𝗦</font> • <font color="#FFFF00">𝗧𝗥𝗢𝗝𝗔𝗡</font><font color="#FF0000">🔥</font>

<font color="#FF8C00">📢 𝗝𝗢𝗜𝗡 𝗖𝗛𝗔𝗡𝗘𝗟</font>
<font color='#00FF00'>↓ <a href="https://t.me/ar_tricks">CLICK HERE</a> ↓</font>
"""
def set_banner(t):
    # Dropbear reads the banner file only when it starts, so saving the file is not enough: restart it.
    # KillMode=process (see apply_dropbear) keeps connected users online during the restart.
    t=str(t).replace("\r\n","\n")
    if len(t.encode())>BANNER_MAX: raise ValueError(f"Banner bohat bara hai ({len(t.encode())} bytes). Max {BANNER_MAX} bytes.")
    if not t.strip(): t="\n"
    try: old=open(BANNER,encoding="utf-8").read()
    except Exception: old=None
    def put(x): os.makedirs(D,exist_ok=True);tmp=BANNER+".tmp";open(tmp,"w",encoding="utf-8").write(x);os.chmod(tmp,0o644);os.replace(tmp,BANNER)
    put(t);sh(["systemctl","restart","dropbear"]);time.sleep(1)
    if sh(["systemctl","is-active","dropbear"])[1]!="active":
        if old is not None: put(old)
        sh(["systemctl","restart","dropbear"]);raise ValueError("Dropbear restart fail hua, purana banner wapas laga diya")
def apply_dropbear():
    c=cfg();os.makedirs("/etc/dropbear",exist_ok=True)
    if not os.path.exists(BANNER): open(BANNER,"w",encoding="utf-8").write(DEF_BANNER)
    _m=psutil.virtual_memory().total;W=67108864 if _m>=3800*2**20 else 33554432 if _m>=1900*2**20 else 16777216
    for k in("rsa","ecdsa","ed25519"):
        f=f"/etc/dropbear/dropbear_{k}_host_key"
        if not os.path.exists(f): sh(["dropbearkey","-t",k,"-f",f])
    os.makedirs("/etc/systemd/system/dropbear.service.d",exist_ok=True)
    sp=int(c["ssh_port"]);ports=list(dict.fromkeys([sp,109,447]))
    binp="/usr/local/sbin/dropbear" if os.path.exists("/usr/local/sbin/dropbear") else "/usr/sbin/dropbear"
    # only use a window the installed binary really supports (custom build: up to 64MB, stock dropbear caps at 10MB)
    try: _mx=int(open("/etc/artricks/dbmaxwin").read().strip() or 0)
    except Exception: _mx=0
    if not binp.startswith("/usr/local"): _mx=0
    W=min(W,_mx if _mx>0 else 8388608)
    args="-F "+" ".join(f"-p {p}" for p in ports)+f" -b {BANNER} -W {W} -K 60 -I 0"
    open("/etc/systemd/system/dropbear.service.d/override.conf","w").write("[Unit]\nAfter=network-online.target\nWants=network-online.target\nStartLimitIntervalSec=0\n[Service]\nType=simple\nPIDFile=\nRemainAfterExit=no\nExecStart=\nExecStop=\nExecReload=\nKillMode=process\nExecStart="+binp+" "+args+"\nLimitNOFILE=1048576\nTasksMax=infinity\nNice=-10\nRestart=always\nRestartSec=3\nOOMScoreAdjust=-300\n")
    open("/etc/default/dropbear","w").write(f'NO_START=0\nDROPBEAR_PORT={sp}\nDROPBEAR_BANNER="{BANNER}"\nDROPBEAR_RECEIVE_WINDOW={W}\nDROPBEAR_EXTRA_ARGS="-p 109 -p 447 -b {BANNER} -W {W} -K 60 -I 0"\n')
    ufw(sp);sh(["systemctl","daemon-reload"]);sh(["systemctl","enable","dropbear"]);return sh(["systemctl","restart","dropbear"])
app=Flask(__name__);sock=Sock(app)
def key():
    f=D+"/secret.key"
    if not os.path.exists(f): open(f,"w").write(secrets.token_hex(32));os.chmod(f,0o600)
    return open(f).read()
app.secret_key=key();app.config.update(SESSION_COOKIE_SAMESITE="Strict",SESSION_COOKIE_HTTPONLY=True,SESSION_COOKIE_SECURE=True,PERMANENT_SESSION_LIFETIME=86400)
def db():
    c=sqlite3.connect(DB);c.execute("create table if not exists admins(u text primary key,p text,role text default 'admin')")
    try: c.execute("alter table admins add column role text default 'admin'");c.commit()
    except Exception: pass
    try: c.execute("alter table admins add column exp integer");c.commit()
    except Exception: pass
    try: os.chmod(DB,0o600)
    except Exception: pass
    return c
def api(f):
    def w(*a,**k):
        if not session.get("u"): return jsonify(error="login"),401
        if session.get("r")!="admin":
            _e=db().execute("select exp from admins where u=?",(session.get("u"),)).fetchone()
            if not _e or (_e[0] and _e[0]<time.time()): session.clear();return jsonify(error="login"),401
        if request.method!="GET" and request.headers.get("X-Panel")!="1": return jsonify(error="bad request"),403
        if session.get("r")!="admin" and (request.method!="GET" or request.path not in("/api/overview","/api/accounts","/api/sessions")): return jsonify(error="View-only login: sirf admin yeh kar sakta hai"),403
        try: return f(*a,**k)
        except Exception as e: return jsonify(error=str(e)),400
    w.__name__=f.__name__;return w
fails={}
@app.route("/")
def index():
    r=send_file("/opt/aliraza-panel/index.html");r.headers["Cache-Control"]="no-store";return r
@app.post("/api/login")
def login():
    ip=request.headers.get("X-Real-IP",request.remote_addr);n,t=fails.get(ip,(0,0))
    if n>=5 and time.time()-t<300: return jsonify(error="Too many attempts. Wait 5 minutes."),429
    j=request.get_json(silent=True) or {};r=db().execute("select p,role,exp from admins where u=?",(j.get("u",""),)).fetchone()
    want="admin" if j.get("role")=="admin" else "user"
    if r and (r[1] or "admin")==want=="user" and r[2] and r[2]<time.time() and check_password_hash(r[0],j.get("p","")): return jsonify(error="This key has expired. Get a new key from AliRaza: t.me/alirazax0"),403
    if r and (r[1] or "admin")==want and check_password_hash(r[0],j.get("p","")): fails.pop(ip,None);session.clear();session.permanent=True;session["u"]=j["u"];session["r"]=want;return jsonify(ok=1)
    fails[ip]=(n+1,time.time());return jsonify(error="Wrong username or password"),401
@app.post("/api/logout")
def logout(): session.clear();return jsonify(ok=1)
@app.get("/api/me")
def me(): return jsonify(u=session.get("u"),role=session.get("r"))
def pub_ip():
    try: return subprocess.check_output(["curl","-4","-s","--max-time","3","ifconfig.me"],text=True).strip()
    except Exception: return ""
IP=[0,""]
SV=[0,{}]
psutil.cpu_percent(None)
def readconf(u):
    d={"IP_LIMIT":"1","GB_LIMIT":"Unlimited","USED_MB":"0"}
    try:
        for l in open(f"{UD}/{u}.conf"):
            if "=" in l: a,b=l.strip().split("=",1);d[a]=b
    except Exception: pass
    return d
def writeconf(u,d): os.makedirs(UD,exist_ok=True);open(f"{UD}/{u}.conf","w").write("".join(f"{k}={v}\n" for k,v in d.items()))
WSMAP="/run/aliraza/ws"
RE_A=re.compile(r"\]: \[(\d+)\] .*?auth succeeded for '?([\w.-]+)'? from (\S+)")
RE_B=re.compile(r"dropbear\[(\d+)\]: .*?auth succeeded for '?([\w.-]+)'? from (\S+)")
_SC=[0,[]]
def kill_pid(pid):
    try: os.kill(int(pid),9);return True
    except Exception: return False
def get_sessions(force=False):
    if not force and time.time()-_SC[0]<4: return _SC[1]
    procs=[p for p in (l.split() for l in sh(["ps","-eo","pid=,etimes=,comm="])[1].splitlines()) if len(p)>=3 and p[2]=="dropbear"]
    if not procs: _SC[0]=time.time();_SC[1]=[];return []   # nobody connected: skip the expensive journal scan
    last={}
    r=sh(["journalctl","-u","dropbear","--no-pager","-g","auth succeeded","-n","5000"])
    if not r[0] and not r[1].strip().startswith("-- No entries"): r=sh(["journalctl","-u","dropbear","--no-pager","-n","2000"])
    for l in r[1].splitlines():
        m=RE_A.search(l) or RE_B.search(l)
        if m: last[m.group(1)]=(m.group(2),m.group(3))
    out=[]
    for p in procs:
        if p[0] not in last: continue
        u,frm=last[p[0]];ip,_,port=frm.rpartition(":");ip=ip.strip("[]");real,via=ip,"ssh"
        if ip in("127.0.0.1","::1","::ffff:127.0.0.1"):
            via="ws"
            if port.isdigit():
                try: real=open(f"{WSMAP}/{port}").read().strip() or ip
                except Exception: pass
        out.append(dict(pid=p[0],u=u,ip=real,via=via,secs=int(p[1]) if p[1].isdigit() else 0))
    out.sort(key=lambda x:(x["u"],x["ip"]))
    _SC[0]=time.time();_SC[1]=out;return out
def online():
    m={}
    for x in get_sessions(): m[x["u"]]=m.get(x["u"],0)+1
    return m
def shadow():
    m={}
    for l in open("/etc/shadow"):
        p=l.split(":")
        if len(p)>7: m[p[0]]=(p[1].startswith("!"),p[7])
    return m
def pt():
    try: d=json.load(open(D+"/traffic.json"));return int(d.get("rx",0)),int(d.get("tx",0)),int(d.get("since",0))
    except Exception: return 0,0,0
@app.get("/api/overview")
@api
def overview():
    if session.get("r")!="admin": return jsonify(users=len(os.listdir(UD)) if os.path.isdir(UD) else 0,online=sum(online().values()),viewonly=True)
    c=cfg();v=psutil.virtual_memory();dk=psutil.disk_usage("/");n=psutil.net_io_counters()
    if time.time()-IP[0]>600: IP[1]=pub_ip();IP[0]=time.time()
    if time.time()-SV[0]>5: _n=("nginx","dropbear","ws-proxy","autokill","tgbot","aliraza-ban-ssh");_o=sh(["systemctl","is-active",*_n])[1].split();SV[1]={s:(i<len(_o) and _o[i]=="active") for i,s in enumerate(_n)};SV[0]=time.time()
    svc=SV[1]
    try: os_=[l.split("=",1)[1].strip().strip('"') for l in open("/etc/os-release") if l.startswith("PRETTY_NAME")][0]
    except Exception: os_=""
    return jsonify(host=socket.gethostname(),os=os_,kernel=os.uname().release,ip=IP[1],cpu=psutil.cpu_percent(None),cores=psutil.cpu_count(),ram=[v.used,v.total],disk=[dk.used,dk.total],
      up=int(time.time()-psutil.boot_time()),load=os.getloadavg(),rx=pt()[0],tx=pt()[1],since=pt()[2],nic_rx=n.bytes_recv,nic_tx=n.bytes_sent,svc=svc,cfg=c,users=len(os.listdir(UD)) if os.path.isdir(UD) else 0,online=sum(online().values()))
@app.get("/api/accounts")
@api
def accounts():
    by={}
    for x in get_sessions(): by.setdefault(x["u"],[]).append(x)
    sd=shadow();out=[];today=datetime.date.today()
    for f in sorted(os.listdir(UD) if os.path.isdir(UD) else []):
        if not f.endswith(".conf"): continue
        u=f[:-5];d=readconf(u);lk,ex=sd.get(u,(False,""))
        ed=(datetime.date(1970,1,1)+datetime.timedelta(days=int(ex))) if ex.isdigit() else None
        ss=by.get(u,[])
        try: ls=int(float(d.get("LAST_SEEN","0") or 0))
        except Exception: ls=0
        out.append(dict(u=u,ip=d["IP_LIMIT"],gb=d["GB_LIMIT"],used=round(float(d["USED_MB"] or 0)/1024,2),exp=ed.isoformat() if ed else "never",days=(ed-today).days if ed else None,expired=bool(ed and ed<today),locked=lk,online=len(ss),ips=sorted({x["ip"] for x in ss}),last=ls,exists=u in sd))
    return jsonify(out)
@app.get("/api/sessions")
@api
def sessions_api():
    ss=get_sessions(True)
    return jsonify(sessions=ss,users=len({x["u"] for x in ss}),ips=len({x["ip"] for x in ss}))
@app.post("/api/kick")
@api
def kick():
    j=request.get_json() or {};n=0
    if not (j.get("pid") or j.get("u") or j.get("ip")): raise ValueError("Nothing to kick")
    for x in get_sessions(True):
        if (j.get("pid") and str(j["pid"])==x["pid"]) or (j.get("u") and j["u"]==x["u"]) or (j.get("ip") and j["ip"]==x["ip"]):
            if kill_pid(x["pid"]): n+=1
    _SC[0]=0
    return jsonify(ok=1,killed=n)
@app.post("/api/accounts/cleanup")
@api
def cleanup():
    sd=shadow();today=datetime.date.today();n=0
    for f in (os.listdir(UD) if os.path.isdir(UD) else []):
        if not f.endswith(".conf"): continue
        u=f[:-5];ex=sd.get(u,(False,""))[1]
        if UN.match(u) and ex.isdigit() and datetime.date(1970,1,1)+datetime.timedelta(days=int(ex))<today:
            sh(["pkill","-KILL","-u",u]);sh(["userdel","-f",u])
            try: os.remove(f"{UD}/{u}.conf")
            except Exception: pass
            n+=1
    return jsonify(ok=1,deleted=n)
UN=re.compile(r"^(?!-)(?!\.{1,2}$)[^\s:/\\\x00-\x1f\x7f]{1,32}$")  # same rules as uname(); was missing -> delete/cleanup crashed with NameError
def uname(j):
    u=str(j.get("u","")).strip()
    # sirf wo cheezein roki hain jo Linux/system ko tor sakti hain
    if not u or len(u)>32 or u in(".","..") or u[0]=="-" or re.search(r"[\s:/\\\x00-\x1f\x7f]",u): raise ValueError("Username khali na ho, max 32 chars, space / : \\ allowed nahi")
    return u
def pw(p):
    p=str(p)
    if not p or "\n" in p or "\r" in p or "\x00" in p: raise ValueError("Password khali nahi ho sakta")
    return p
def setexp(u,days): sh(["usermod","-e",(datetime.date.today()+datetime.timedelta(days=int(days))).isoformat(),u])
@app.post("/api/accounts")
@api
def acc_add():
    j=request.get_json();u=uname(j);p=pw(j.get("p",""));days=int(j.get("days") or 30);ipl=int(j.get("ip") or 1)
    ok,o=sh(["useradd","-M","-s","/bin/bash","--",u])
    if not ok: ok,o=sh(["useradd","--badname","-M","-s","/bin/bash","--",u])
    if not ok: raise ValueError(o)
    sh(["chpasswd"],f"{u}:{p}\n");setexp(u,days)
    gbl=j.get("gb") or "Unlimited";writeconf(u,{"IP_LIMIT":ipl,"GB_LIMIT":gbl,"USED_MB":"0.0"})
    # build the complete account card on the server so the popup never depends on a second request
    c=cfg();sp=int(c.get("ssh_port") or 8443)
    if not IP[1]:
        try: IP[1]=pub_ip();IP[0]=time.time()
        except Exception: pass
    try: rh=request.host.rsplit(":",1)[0] if not request.host.startswith("[") else request.host
    except Exception: rh=""
    host=c.get("domain") or IP[1] or rh
    pl=f"GET /artricks HTTP/1.1[crlf]Host: {host}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
    info=dict(u=u,p=p,exp=(datetime.date.today()+datetime.timedelta(days=days)).isoformat(),days=days,ip=ipl,gb=gbl,host=host,domain=c.get("domain") or "",server_ip=IP[1] or "",ssh_port=sp,ports=list(dict.fromkeys([sp,109,447])),ws=80,wss=443,payload=pl)
    return jsonify(ok=1,info=info)
@app.put("/api/accounts/<u>")
@api
def acc_edit(u):
    j=request.get_json();d=readconf(u)
    if not os.path.exists(f"{UD}/{u}.conf"): raise ValueError("Account not found")
    if j.get("p"): sh(["chpasswd"],f"{u}:{pw(j['p'])}\n")
    if j.get("days") not in(None,""): setexp(u,j["days"])
    if j.get("ip") not in(None,""): d["IP_LIMIT"]=int(j["ip"])
    if j.get("gb") not in(None,""): d["GB_LIMIT"]=j["gb"]
    if j.get("reset"): d["USED_MB"]="0.0"
    writeconf(u,d)
    if j.get("lock") is True:
        sh(["passwd","-l",u])
        for x in get_sessions(True):
            if x["u"]==u: kill_pid(x["pid"])
    else: sh(["passwd","-u",u])
    return jsonify(ok=1)
@app.delete("/api/accounts/<u>")
@api
def acc_del(u):
    if not UN.match(u): raise ValueError("bad name")
    for x in get_sessions(True):
        if x["u"]==u: kill_pid(x["pid"])
    sh(["pkill","-KILL","-u",u])
    ok,o=sh(["userdel","-f",u])
    if sh(["id",u])[0]: raise ValueError("Delete failed: "+(o or "userdel error"))
    try: os.remove(f"{UD}/{u}.conf")
    except Exception: pass
    _SC[0]=0
    return jsonify(ok=1)
@app.route("/api/banner",methods=["GET","PUT"])
@api
def banner():
    if request.method=="PUT": set_banner((request.get_json() or {}).get("t",""));return jsonify(ok=1)
    return jsonify(t=open(BANNER,encoding="utf-8").read() if os.path.exists(BANNER) else "")
TB=D+"/tgbot"
@app.route("/api/tg",methods=["GET","POST"])
@api
def tg():
    if request.method=="POST":
        j=request.get_json();t=j.get("token","").strip();a=int(j.get("admin"))
        if not re.match(r"^\d+:[\w-]{20,}$",t): raise ValueError("Invalid bot token")
        os.makedirs(TB,exist_ok=True);json.dump({"token":t,"super_admin":a},open(TB+"/config.json","w"));json.dump([a],open(TB+"/admins.json","w"));os.chmod(TB+"/config.json",0o600)
        sh(["systemctl","enable","tgbot"]);ok,o=sh(["systemctl","restart","tgbot"]);return jsonify(ok=ok,msg=o)
    if request.args.get("act") in("start","stop","restart"): sh(["systemctl",request.args["act"],"tgbot"])
    try: c=json.load(open(TB+"/config.json"));tok=c["token"][:6]+"…"+c["token"][-4:];adm=c["super_admin"]
    except Exception: tok=adm=None
    return jsonify(active=sh(["systemctl","is-active","tgbot"])[1]=="active",token=tok,admin=adm)
@app.post("/api/service/<s>/<act>")
@api
def service(s,act):
    if s not in("nginx","dropbear","ws-proxy","autokill","tgbot","aliraza-ban-ssh") or act not in("start","stop","restart"): raise ValueError("bad")
    ok,o=sh(["systemctl",act,s]);return jsonify(ok=ok,msg=o)
RF=[0]
def do_refresh():
    def sv(*a):
        try: sh(list(a))
        except Exception: pass
    try:
        sv("pkill","-KILL","-x","dropbear")   # every tunnel session ends -> clients reconnect fresh. SSH accounts / limits / usage are NOT touched
        _SC[0]=0;IP[0]=0;SV[0]=0
        try: apply_dropbear()
        except Exception: sv("systemctl","restart","dropbear")
        try: apply_ban()
        except Exception: pass
        for s_ in("aliraza-ban-ssh","ws-proxy","autokill","aliraza-watchdog","aliraza-traffic"): sv("systemctl","restart",s_)
        if sh(["systemctl","is-active","tgbot"])[1]=="active": sv("systemctl","restart","tgbot")
        sv("sysctl","-e","-p","/etc/sysctl.d/99-artricks-ssh.conf")
        sv("/usr/local/bin/aliraza-conntrack.sh")
        sv("journalctl","--vacuum-size=100M")
        try: open("/var/log/ws-proxy.log","w").close()
        except Exception: pass
        try: os.sync();open("/proc/sys/vm/drop_caches","w").write("1")
        except Exception: pass
        try: apply_nginx()
        except Exception: pass
    finally:
        sv("systemctl","restart","--no-block","aliraza-panel")
@app.post("/api/refresh")
@api
def refresh_all():
    if session.get("r")!="admin": raise ValueError("Sirf admin")
    if time.time()-RF[0]<30: raise ValueError("Refresh already in progress, wait 30 seconds")
    RF[0]=time.time();later(do_refresh,0.6);return jsonify(ok=1)
@app.post("/api/fix")
@api
def fix(): apply_dropbear();apply_ban();sh(["systemctl","restart","aliraza-ban-ssh"]);sh(["systemctl","restart","ws-proxy"]);sh(["systemctl","restart","autokill"]);return jsonify(ok=1,msg=apply_nginx()[1])
def freeport(p,own):
    if p in(80,443,109,447,2082,2299,12026) or not 1<=p<=65535: raise ValueError("Port reserved/invalid")
    if p!=own and sh(["ss","-ltn",f"sport = :{p}"])[1].count("\n")>=1: raise ValueError(f"Port {p} is already in use")
@app.post("/api/settings")
@api
def settings():
    j=request.get_json();c=cfg();msg=[];nw=dict(c)
    if j.get("panel_port"): p=int(j["panel_port"]);freeport(p,c["panel_port"]);nw["panel_port"]=p
    if j.get("ssh_port"): p=int(j["ssh_port"]);freeport(p,c["ssh_port"]);nw["ssh_port"]=p
    if nw["panel_port"]==nw["ssh_port"]: raise ValueError("Panel and SSH port must differ")
    if j.get("domain"):
        d=j["domain"].strip().lower()
        if not re.match(r"^[a-z0-9.-]+$",d): raise ValueError("Invalid domain")
        nw["domain"]=d
    savecfg(nw)
    if nw["domain"]!=c["domain"] and j.get("ssl"):
        sh(["systemctl","stop","nginx"]);ok,o=sh(["certbot","certonly","-n","--standalone","--agree-tos","--register-unsafely-without-email","-d",nw["domain"]],t=180);msg.append("SSL issued" if ok else "SSL failed (self-signed kept): "+o[-200:])
    ufw(nw["panel_port"])
    if nw["ssh_port"]!=c["ssh_port"]: later(apply_dropbear)
    later(apply_nginx);return jsonify(ok=1,msg=" | ".join(msg),cfg=nw)
@app.post("/api/uninstall")
@api
def uninstall_panel():
    j=request.get_json() or {}
    if session.get("r")!="admin": raise ValueError("Sirf admin")
    if j.get("confirm")!="UNINSTALL": raise ValueError("Confirm word galat hai (UNINSTALL likhein)")
    r=db().execute("select p from admins where u=?",(session.get("u"),)).fetchone()
    if not r or not check_password_hash(r[0],j.get("p","")): raise ValueError("Password galat hai")
    if not os.path.exists("/usr/local/bin/aliraza-uninstall.sh"): raise ValueError("Uninstall script nahi mili")
    args=["/usr/local/bin/aliraza-uninstall.sh"]+(["keep-users"] if j.get("keep") else [])
    ok,o=sh(["systemd-run","--no-block","--unit=aliraza-uninstall-"+str(int(time.time())),*args])
    if not ok: subprocess.Popen(args,start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return jsonify(ok=1)
@app.post("/api/admin")
@api
def admin():
    j=request.get_json();c=db();a=j.get("act");u=j.get("u","").strip()
    if not u or len(u)>64: raise ValueError("Username khali ya bohat lamba")
    if a=="create":
        rl="admin" if j.get("role")=="admin" else "user"
        try: dd=int(j.get("days") or 0)
        except Exception: dd=0
        if dd<0 or dd>3650: raise ValueError("Days must be 0-3650 (0 = no expiry)")
        ex=int(time.time())+dd*86400 if (dd and rl=="user") else None
        c.execute("insert into admins(u,p,role,exp) values(?,?,?,?)",(u,generate_password_hash(pw(j.get("p",""))),rl,ex))
    elif a=="password": c.execute("update admins set p=? where u=?",(generate_password_hash(pw(j.get("p",""))),u))
    elif a=="rename":
        n=j.get("new","").strip()
        if not n or len(n)>64: raise ValueError("Username khali ya bohat lamba")
        c.execute("update admins set u=? where u=?",(n,u));session["u"]=n if session["u"]==u else session["u"]
    elif a=="extend":
        try: dd=int(j.get("days") or 0)
        except Exception: dd=0
        if dd<1 or dd>3650: raise ValueError("Days must be 1-3650")
        r=c.execute("select role,exp from admins where u=?",(u,)).fetchone()
        if not r or (r[0] or "admin")=="admin": raise ValueError("Only view-only keys can have an expiry")
        c.execute("update admins set exp=? where u=?",(max(int(time.time()),r[1] or 0)+dd*86400,u))
    elif a=="noexpiry": c.execute("update admins set exp=NULL where u=?",(u,))
    elif a=="delete":
        tr=c.execute("select role from admins where u=?",(u,)).fetchone()
        if u==session["u"] or (tr and (tr[0] or "admin")=="admin" and c.execute("select count(*) from admins where role='admin' or role is null").fetchone()[0]<2): raise ValueError("Cannot delete this admin")
        c.execute("delete from admins where u=?",(u,))
    c.commit();return jsonify(ok=1,admins=[r[0] for r in c.execute("select u from admins")])
@app.get("/api/admins")
@api
def admins(): return jsonify([{"u":r[0],"role":r[1] or "admin","left":(r[2]-int(time.time())) if r[2] else None} for r in db().execute("select u,role,exp from admins")])

# ---------- Blocked IPs ----------
BANF=D+"/banned.txt"
def bans():
    out=[]
    try:
        for l in open(BANF,encoding="utf-8"):
            p=l.rstrip("\n").split("\t")
            if p and p[0]: out.append(dict(ip=p[0],ts=int(p[1]) if len(p)>1 and p[1].isdigit() else 0,note=p[2] if len(p)>2 else ""))
    except Exception: pass
    return out
def savebans(L):
    tmp=BANF+".tmp"
    with open(tmp,"w",encoding="utf-8") as f: f.write("".join(f"{b['ip']}\t{b['ts']}\t{b['note']}\n" for b in L))
    os.chmod(tmp,0o644);os.replace(tmp,BANF)
def apply_ban(): return sh(["/usr/local/bin/aliraza-ban.sh"])
def normip(s):
    import ipaddress
    a=ipaddress.ip_address(str(s).strip().strip("[]"))
    return a.ipv4_mapped if getattr(a,"ipv4_mapped",None) else a
def server_ips():
    s=set()
    for L in psutil.net_if_addrs().values():
        for a in L:
            if a.family in(socket.AF_INET,socket.AF_INET6): s.add(a.address.split("%")[0])
    return s
@app.get("/api/bans")
@api
def bans_list():
    ss=get_sessions()
    return jsonify([{**b,"online":sum(1 for x in ss if x["ip"]==b["ip"])} for b in bans()])
@app.post("/api/bans")
@api
def ban_add():
    j=request.get_json() or {};a=normip(j.get("ip",""));ip=a.compressed
    if a.is_loopback or a.is_unspecified or ip in server_ips(): raise ValueError("This IP cannot be blocked")
    note=re.sub(r"[\t\r\n]"," ",str(j.get("note",""))).strip()[:80]
    savebans([b for b in bans() if b["ip"]!=ip]+[dict(ip=ip,ts=int(time.time()),note=note)]);apply_ban();n=0
    for x in get_sessions(True):
        if x["ip"]==ip and kill_pid(x["pid"]): n+=1
    _SC[0]=0
    return jsonify(ok=1,killed=n)
@app.post("/api/unban")
@api
def ban_del():
    ip=normip((request.get_json() or {}).get("ip","")).compressed
    savebans([b for b in bans() if b["ip"]!=ip]);apply_ban();return jsonify(ok=1)

APP_EOF
cat > /opt/aliraza-panel/index.html <<'UI_EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#050c0f"><title>ALIRAZA SSH Panel</title>
<style>
:root{--bg:#050c0f;--card:#0b1a21;--card2:#112832;--line:#265064;--tx:#ecf9ff;--mu:#8eaebe;--g:#87d9f9;--g2:#2face7;--f1:#4dbaf1;--f2:#87d9f9;--f3:#d6f2fe;--ok:#4ade80;--bad:#ff4d6d;--r:16px}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;background:var(--bg);color:var(--tx);font:14.5px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif}
body::before{content:"";position:fixed;inset:0;z-index:0;pointer-events:none;background:radial-gradient(800px 460px at 8% -8%,#2face733,transparent 62%),radial-gradient(760px 460px at 100% 0,#28a7c230,transparent 60%);animation:glowpulse 5s ease-in-out infinite alternate}
#app{position:relative;z-index:1;min-height:100vh;padding-bottom:48px}
h1,h2,h3{margin:0}
h2{font-size:17px;font-weight:700;margin-bottom:14px;color:var(--tx);display:flex;align-items:center;gap:8px;flex-wrap:wrap}
h3{font-size:15px;margin-bottom:8px;color:var(--f3)}
/* flames + embers (decorative, behind the panel) */
.fire{position:fixed;left:0;right:0;bottom:0;height:230px;z-index:0;pointer-events:none;overflow:hidden}
.fire::before{content:"";position:absolute;left:-10%;right:-10%;bottom:-40px;height:150px;background:radial-gradient(ellipse at 50% 100%,#0ea5e966 0%,#0a4f8a44 45%,transparent 72%);animation:glowpulse 2.4s ease-in-out infinite alternate}
.fire i{position:absolute;bottom:-55px;left:var(--x);width:var(--w);height:calc(var(--w)*1.9);margin-left:calc(var(--w)/-2);background:radial-gradient(ellipse at 50% 78%,#effbff 0%,#a5e4ff 28%,#38a6e8 55%,#0a4f8aaa 68%,transparent 74%);border-radius:50% 50% 46% 46%/72% 72% 28% 28%;filter:blur(7px);opacity:.85;mix-blend-mode:screen;transform-origin:50% 100%;animation:flame var(--d) ease-in-out infinite alternate;animation-delay:var(--dl)}
.embers{position:fixed;inset:0;z-index:0;pointer-events:none;overflow:hidden}
.embers b{position:absolute;bottom:-12px;left:var(--x);width:var(--s);height:var(--s);border-radius:50%;background:#b6e8fc;box-shadow:0 0 8px 2px #46c2f2cc;opacity:0;animation:ember var(--d) linear infinite;animation-delay:var(--dl)}
@keyframes flame{0%{transform:scale(.82,.78) rotate(-4deg) translateX(-4px)}35%{transform:scale(1.02,1.18) rotate(2deg) translateX(3px)}70%{transform:scale(.9,1.0) rotate(-2deg) translateX(-2px)}100%{transform:scale(1.08,1.25) rotate(4deg) translateX(4px)}}
@keyframes ember{0%{transform:translate(0,0) scale(1);opacity:0}8%{opacity:1}60%{opacity:.7}100%{transform:translate(var(--dx),-88vh) scale(.15);opacity:0}}
@keyframes glowpulse{from{opacity:.55}to{opacity:1}}
@keyframes shine{0%{background-position:0% 50%}100%{background-position:200% 50%}}
@keyframes flicker{0%,100%{transform:scale(1) rotate(-3deg);filter:drop-shadow(0 0 6px #28b0e3)}25%{transform:scale(1.12) rotate(3deg);filter:drop-shadow(0 0 12px #b6e8fc)}50%{transform:scale(.95) rotate(-2deg);filter:drop-shadow(0 0 7px #2face7)}75%{transform:scale(1.08) rotate(2deg);filter:drop-shadow(0 0 14px #28a7c2)}}
@keyframes edgeglow{0%,100%{box-shadow:0 6px 24px #0000004a,0 0 0 #28b0e300}50%{box-shadow:0 6px 24px #0000004a,0 0 18px #28b0e340}}
@keyframes sweep{0%{transform:translateX(-120%)}100%{transform:translateX(320%)}}
/* header + nav */
header{display:flex;align-items:center;gap:12px;padding:12px 18px;position:sticky;top:0;z-index:5;background:#050c0ff2;border-bottom:1px solid var(--line)}
header::after{content:"";position:absolute;left:0;right:0;bottom:-1px;height:2px;background:linear-gradient(90deg,transparent,#2face7,#8ed3f7,#2face7,transparent);background-size:200% 100%;animation:shine 3s linear infinite}
header .sp{flex:1}
.brand{font-size:21px;font-weight:800;letter-spacing:.6px;line-height:1.15;background:linear-gradient(90deg,#adecfa,#46c2f2,#2face7,#adecfa);background-size:200% 100%;animation:shine 4s linear infinite;-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:transparent}
.brand small{display:block;font-size:11px;font-weight:500;letter-spacing:.3px;-webkit-text-fill-color:var(--mu);color:var(--mu)}
.logo{-webkit-text-fill-color:initial;display:inline-block;transform-origin:50% 90%;animation:flicker 1.3s ease-in-out infinite}
nav{display:flex;flex-direction:column;gap:6px;flex:0 0 220px;width:220px;padding:16px 12px 24px 16px;position:sticky;top:64px;max-height:calc(100vh - 64px);overflow-y:auto;scrollbar-width:none}
.layout{display:flex;align-items:flex-start;max-width:1800px;margin:0 auto}
#mb,.scrim{display:none}
nav::-webkit-scrollbar{display:none}
nav a{display:block;color:var(--mu);padding:11px 16px;border:1px solid var(--line);border-radius:12px;cursor:pointer;white-space:nowrap;font-weight:600;font-size:13.5px;background:#0b1a21cc;transition:color .2s,background .2s,border-color .2s,box-shadow .2s,transform .2s}
nav a:hover{color:var(--tx);border-color:#3c8fb7;box-shadow:0 0 12px #4dbaf133;transform:translateX(3px)}
nav a.on{color:#fff;border-color:transparent;background:linear-gradient(135deg,#2face7,#28a7c2,#2face7);background-size:200% 200%;animation:shine 3s linear infinite;box-shadow:0 0 16px #4dbaf166}
main{flex:1;min-width:0;max-width:1500px;padding:16px}
/* cards */
.card{background:linear-gradient(180deg,#132d39f2,#0b1a21f2);border:1px solid var(--line);border-radius:var(--r);padding:18px;margin-bottom:16px;box-shadow:0 6px 24px #0000004a;transition:transform .22s ease,border-color .22s ease;animation:edgeglow 4s ease-in-out infinite}
@media(hover:hover){.card:hover{transform:translateY(-3px);border-color:#46c2f2}}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px}
.grid>div{background:#071319;border:1px solid var(--line);border-radius:12px;padding:12px 14px}
.k{color:var(--mu);font-size:12px}
.v{font-size:21px;font-weight:700;color:var(--f3)}
/* the expand animation: plays once when a tab opens, never on background refresh */
@keyframes expand{from{opacity:0;transform:translateY(16px) scale(.95)}to{opacity:1;transform:none}}
@keyframes fade{from{opacity:0}to{opacity:1}}
@keyframes slidein{from{opacity:0;transform:translateX(24px)}to{opacity:1;transform:none}}
@keyframes blink{0%,100%{opacity:1}50%{opacity:.3}}
main.enter>.card{animation:expand .5s cubic-bezier(.2,.8,.2,1) both}
main.enter>.card:nth-child(2){animation-delay:.07s}main.enter>.card:nth-child(3){animation-delay:.14s}main.enter>.card:nth-child(4){animation-delay:.21s}main.enter>.card:nth-child(5){animation-delay:.28s}
main.enter .grid>div{animation:expand .45s cubic-bezier(.2,.8,.2,1) both}
main.enter .grid>div:nth-child(2){animation-delay:.05s}main.enter .grid>div:nth-child(3){animation-delay:.1s}main.enter .grid>div:nth-child(4){animation-delay:.15s}main.enter .grid>div:nth-child(5){animation-delay:.2s}main.enter .grid>div:nth-child(6){animation-delay:.25s}main.enter .grid>div:nth-child(7){animation-delay:.3s}main.enter .grid>div:nth-child(8){animation-delay:.35s}
/* buttons */
button{position:relative;overflow:hidden;background:#2997c9;color:#fff;border:0;border-radius:10px;padding:9px 16px;font:inherit;font-weight:600;font-size:13.5px;cursor:pointer;transition:filter .2s,transform .12s,box-shadow .2s}
button:hover{filter:brightness(1.12);box-shadow:0 0 14px #4dbaf166}button:active{transform:scale(.96)}
button.f{background:linear-gradient(135deg,#2face7,#28a7c2)}
button.f::after{content:"";position:absolute;top:0;bottom:0;left:0;width:35%;background:linear-gradient(90deg,transparent,#ffffff55,transparent);transform:translateX(-120%);animation:sweep 3.2s ease-in-out infinite}
button.s{background:transparent;color:var(--f3);border:1px solid #34799b}button.s:hover{background:#112832;filter:none}
button.d{background:#e11d48;color:#fff}
button:focus-visible,input:focus-visible,nav a:focus-visible,textarea:focus-visible,select:focus-visible{outline:2px solid var(--f2);outline-offset:2px}
/* forms */
input,textarea,select{background:#071319;border:1px solid var(--line);color:var(--tx);padding:10px 12px;border-radius:10px;font:inherit;width:100%;transition:border-color .2s,box-shadow .2s}
input:focus,select:focus,textarea:focus{border-color:var(--f2);box-shadow:0 0 0 3px #87d9f930}
input[type=checkbox]{width:auto;accent-color:var(--f1)}
::placeholder{color:#648290}
label{display:block;margin:10px 0 4px;color:var(--mu);font-size:13px}
.row{display:flex;gap:12px;flex-wrap:wrap;align-items:flex-end}.row>*{flex:1;min-width:140px}
/* tables */
.tw{overflow-x:auto;-webkit-overflow-scrolling:touch}
table{width:100%;border-collapse:collapse}
td,th{padding:10px 8px;border-bottom:1px solid var(--line);text-align:left;font-size:13px;vertical-align:middle}
th{color:var(--mu);font-weight:600;font-size:11.5px;text-transform:uppercase;letter-spacing:.6px}
tr:last-child td{border-bottom:0}
@media(hover:hover){table tr:hover td{background:#4dbaf114}}
/* badges */
.b{display:inline-flex;align-items:center;padding:3px 11px;border-radius:999px;font-size:12px;font-weight:700}
.on1{background:#0d3a22;color:var(--ok)}.off1{background:#4a1522;color:var(--bad)}.mu1{background:#18323e;color:var(--mu)}
.b.on1::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor;margin-right:7px;animation:blink 1.8s ease-in-out infinite}
/* bars + code */
.bar{height:7px;background:#071319;border-radius:6px;overflow:hidden;margin-top:8px}
.bar i{display:block;height:100%;border-radius:6px;background:linear-gradient(90deg,#2face7,#8ed3f7,#2face7);background-size:200% 100%;animation:shine 2.5s linear infinite;transition:width .6s ease}
pre.c{background:#051016;border:1px solid var(--line);padding:12px;border-radius:10px;overflow-x:auto;white-space:pre-wrap;word-break:break-all;margin:8px 0;color:var(--f3);font:12.5px/1.6 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
/* toast, footer, login */
#toast{position:fixed;top:74px;right:14px;z-index:60;background:var(--card2);border:1px solid var(--f2);padding:11px 16px;border-radius:12px;display:none;max-width:84vw;box-shadow:0 10px 30px #0008,0 0 16px #28b0e340;animation:slidein .3s ease both}
footer{text-align:center;color:var(--mu);font-size:12px;margin-top:22px}footer a{color:var(--f2);text-decoration:none}
.login{max-width:380px;margin:11vh auto;padding:0 16px;text-align:center}
.login .brand{font-size:34px}
.login .card{text-align:left;animation:expand .55s cubic-bezier(.2,.8,.2,1) both,edgeglow 4s ease-in-out .6s infinite}
.rt{display:flex;gap:8px;margin-bottom:14px}
.rt button{flex:1;background:transparent;color:var(--mu);border:1px solid var(--line)}
.rt button.on{background:linear-gradient(135deg,#2face7,#28a7c2);color:#fff;border-color:transparent}
body.ro .wr{display:none!important}
.vbar{text-align:center;padding:9px 14px;font-size:13px;font-weight:600;background:linear-gradient(90deg,#144157,#1c5b78,#144157);border-bottom:1px solid #3c8fb7;color:var(--f3);position:relative;z-index:5}
.vbar a{color:#fff;text-decoration:underline}
.tgb{display:inline-block;margin-top:8px;padding:11px 20px;border-radius:12px;background:linear-gradient(135deg,#2face7,#28a7c2);color:#fff!important;font-weight:800;text-decoration:none;box-shadow:0 0 16px #4dbaf166;transition:transform .2s}
.tgb:hover{transform:translateY(-2px)}
.vn{text-align:center;line-height:1.6}
.vpin{position:fixed;left:50%;bottom:12px;transform:translateX(-50%);z-index:9999;width:calc(100% - 24px);max-width:460px;text-align:center;padding:14px 16px;border-radius:16px;background:linear-gradient(180deg,#132d39f7,#0b1a21f7);border:1px solid #46c2f2;box-shadow:0 0 24px #4dbaf166,0 10px 30px #000a;animation:edgeglow 4s ease-in-out infinite}
.vpin .at{font-weight:900;font-size:16px;letter-spacing:2px;color:var(--f2)}
body.vo main{padding-bottom:190px}
/* account-created popup */
.ov{position:fixed;inset:0;z-index:50;background:#030a0dc4;display:flex;align-items:center;justify-content:center;padding:14px;animation:fade .2s ease both}
.ov .card{width:100%;max-width:640px;max-height:92vh;overflow-y:auto;margin:0;border-color:#3c8fb7;animation:expand .35s cubic-bezier(.2,.8,.2,1) both}
.ov .card:hover{transform:none}
.ov .ir{display:flex;justify-content:space-between;gap:10px;padding:8px 0;border-bottom:1px solid var(--line);word-break:break-all}.ov .ir b{color:var(--f3);font-weight:600;text-align:right}
.ov .ah{text-align:center;padding:2px 0 12px;border-bottom:1px dashed var(--line);margin-bottom:6px}
.ov .at{font-weight:900;font-size:clamp(17px,4.6vw,23px);letter-spacing:2px;line-height:1.25;background:linear-gradient(90deg,#adecfa,#46c2f2,#2face7,#adecfa);background-size:200% 100%;animation:shine 4s linear infinite;-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:transparent;filter:drop-shadow(0 0 10px #4dbaf155)}
.ov .as{margin-top:6px;font-size:12.5px;color:var(--ok)}
.ov .sec{margin:16px 0 2px;font-size:11.5px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;color:var(--f2)}
.ov .af{text-align:center;color:var(--mu);font-size:11.5px;margin-top:16px}
.ov .tick{width:68px;height:68px;display:block;margin:0 auto 8px;overflow:visible}
.ov .okc{fill:rgba(74,222,128,.1);stroke:var(--ok);stroke-width:2.5;stroke-dasharray:152;stroke-dashoffset:152;animation:draw .6s ease-out .1s forwards,okglow 1.6s ease-out .7s 1}
.ov .okp{fill:none;stroke:var(--ok);stroke-width:4;stroke-linecap:round;stroke-linejoin:round;stroke-dasharray:42;stroke-dashoffset:42;animation:draw .35s ease-out .6s forwards}
.ov .ah .at{animation:shine 4s linear infinite,rise .5s cubic-bezier(.2,.8,.2,1) .15s both}
.ov .as{animation:rise .5s ease-out .9s both}
.ov .cf{position:absolute;left:50%;top:24%;width:0;height:0;pointer-events:none;z-index:2}
.ov .cf i{position:absolute;width:8px;height:12px;border-radius:2px;opacity:0;animation:burst 1.6s cubic-bezier(.15,.7,.3,1) forwards}
@keyframes draw{to{stroke-dashoffset:0}}
@keyframes okglow{0%{filter:drop-shadow(0 0 0 rgba(74,222,128,0))}40%{filter:drop-shadow(0 0 16px rgba(74,222,128,.75))}100%{filter:drop-shadow(0 0 0 rgba(74,222,128,0))}}
@keyframes rise{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:none}}
@keyframes burst{0%{opacity:1;transform:translate(0,0) rotate(0)}100%{opacity:0;transform:translate(var(--dx),calc(var(--dy) + 150px)) rotate(var(--r))}}
@media(prefers-reduced-motion:reduce){.ov .cf{display:none}.ov *{animation-duration:.01s!important;animation-delay:0s!important}}
@media(max-width:600px){header{padding:10px 12px;gap:8px}header button{padding:7px 12px;font-size:12.5px;white-space:nowrap}.brand{font-size:18px}main{padding:4px 12px 12px}.card{padding:14px}.v{font-size:18px}.grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.grid>div{padding:10px 12px}.row>*{min-width:100%}.fire{height:170px}}
@media(max-width:820px){#mb{display:inline-flex}nav{position:fixed;left:0;top:0;bottom:0;max-height:none;width:250px;flex:none;z-index:40;background:#061218;border-right:1px solid var(--line);padding:76px 14px 20px;transform:translateX(-105%);transition:transform .28s ease}nav.open{transform:none;box-shadow:8px 0 40px #000b}.scrim{position:fixed;inset:0;z-index:39;background:#000a}.scrim.show{display:block}.layout{display:block}main{max-width:none;padding:8px 12px 12px}}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}

/* ===== animated login ===== */
.login2{max-width:1020px;margin:0 auto;padding:6vh 18px 24px}
.lgw{display:grid;grid-template-columns:1.1fr .9fr;gap:34px;align-items:center;min-height:66vh}
.hero{text-align:center}
.lgc .card{margin:0 auto;max-width:400px;text-align:left;animation:expand .55s cubic-bezier(.2,.8,.2,1) both,edgeglow 4s ease-in-out .6s infinite}
.orb{position:relative;width:230px;height:230px;margin:0 auto 14px}
.ring{position:absolute;border-radius:50%;border:1px dashed #8ed3f766;will-change:transform}
.r1{inset:0;animation:spin 14s linear infinite}
.r2{inset:13%;border-color:#87d9f977;animation:spin 10s linear infinite reverse}
.r3{inset:27%;border-color:#4dbaf188;animation:spin 7s linear infinite}
.dot{position:absolute;top:-14px;left:50%;margin-left:-14px;width:28px;height:28px;border-radius:50%;background:#0b1a21;border:1px solid #46c2f2;display:grid;place-items:center;box-shadow:0 0 14px #28b0e399}
.dot em{font-style:normal;font-size:14px;display:block}
.d1 em{animation:spin 14s linear infinite reverse}.d2 em{animation:spin 10s linear infinite}.d3 em{animation:spin 7s linear infinite reverse}
.core{position:absolute;inset:38%;border-radius:50%;display:grid;place-items:center;background:radial-gradient(circle,#46c2f255,#0b1a21 70%);border:1px solid #46c2f2;font-size:30px;animation:corepulse 2.4s ease-in-out infinite}
@keyframes spin{to{transform:rotate(360deg)}}
@keyframes corepulse{0%,100%{box-shadow:0 0 18px #4dbaf155,inset 0 0 12px #4dbaf133;transform:scale(1)}50%{box-shadow:0 0 34px #4dbaf1aa,inset 0 0 18px #4dbaf166;transform:scale(1.07)}}
.ttl{margin:0;font-size:clamp(38px,7vw,62px);font-weight:900;letter-spacing:4px;line-height:1.05;background:linear-gradient(90deg,#adecfa,#46c2f2,#2face7,#adecfa);background-size:200% 100%;animation:shine 4s linear infinite;-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:transparent;filter:drop-shadow(0 0 14px #4dbaf155)}
.sub{margin:8px 0 16px;font:700 clamp(15px,2.6vw,20px) ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:var(--f3);letter-spacing:.12em;min-height:1.7em}
.typ{display:inline-block;overflow:hidden;white-space:nowrap;vertical-align:bottom;border-right:3px solid var(--f2);width:0;animation:typing 7s steps(14,end) infinite,caret .8s step-end infinite}
@keyframes typing{0%{width:0}35%,70%{width:calc(14*(1ch + .12em))}100%{width:0}}
@keyframes caret{50%{border-color:transparent}}
.chips{display:flex;gap:8px;justify-content:center;flex-wrap:wrap;margin-bottom:16px}
.chips span{display:inline-flex;align-items:center;gap:7px;padding:5px 12px;border:1px solid var(--line);border-radius:999px;background:#0b1a21cc;font-size:12px;color:var(--f3);animation:fade .6s ease both}
.chips i{width:7px;height:7px;border-radius:50%;background:var(--ok);box-shadow:0 0 8px var(--ok);animation:blink 1.8s ease-in-out infinite}
.chips span:nth-child(2) i{animation-delay:.3s}.chips span:nth-child(3) i{animation-delay:.6s}
.term{max-width:360px;margin:0 auto;text-align:left;background:#051016e6;border:1px solid var(--line);border-radius:12px;padding:12px 14px;font:12.5px/1.8 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:var(--mu);position:relative;overflow:hidden}
.term::after{content:"";position:absolute;left:0;right:0;top:0;height:40%;background:linear-gradient(180deg,transparent,#46c2f218,transparent);animation:scan 3.5s linear infinite;pointer-events:none}
@keyframes scan{from{transform:translateY(-100%)}to{transform:translateY(300%)}}
.tl{opacity:0;animation:tline .5s ease forwards;animation-delay:calc(var(--i)*.9s + .6s)}
.tl.ok{color:var(--ok)}
@keyframes tline{from{opacity:0;transform:translateX(-8px)}to{opacity:1;transform:none}}
.cur{display:inline-block;width:8px;height:14px;background:var(--f2);vertical-align:-2px;animation:blink 1s step-end infinite}
@media(max-width:860px){.lgw{grid-template-columns:1fr;gap:18px;min-height:0}.login2{padding-top:3vh}.orb{width:170px;height:170px}.core{font-size:24px}.term{display:none}.lgc .card{max-width:440px}}
@media(prefers-reduced-motion:reduce){.typ{width:auto;border-right:0}.tl{opacity:1}}

/* ===== ice-blue extras ===== */
.aurora{position:fixed;inset:0;z-index:0;pointer-events:none;overflow:hidden}
.aurora span{position:absolute;width:46vmax;height:46vmax;border-radius:50%;filter:blur(90px);opacity:.34;mix-blend-mode:screen;will-change:transform;animation:drift 18s ease-in-out infinite alternate}
.aurora span:nth-child(1){background:#2face7;left:-12vmax;top:-14vmax}
.aurora span:nth-child(2){background:#28a7c2;right:-16vmax;top:10vh;animation-duration:24s;animation-delay:-6s}
.aurora span:nth-child(3){background:#2563eb;left:22vw;bottom:-26vmax;opacity:.24;animation-duration:30s;animation-delay:-12s}
@keyframes drift{from{transform:translate(0,0) scale(1)}to{transform:translate(8vw,6vh) scale(1.22)}}
.card{position:relative}
.card::after{content:"";position:absolute;left:16px;right:16px;top:0;height:2px;border-radius:2px;background:linear-gradient(90deg,transparent,#46c2f2,#7ce0f6,#46c2f2,transparent);background-size:200% 100%;animation:shine 3.5s linear infinite;pointer-events:none}
@media(hover:hover){.grid>div{transition:transform .2s,border-color .2s,box-shadow .2s}.grid>div:hover{transform:translateY(-2px);border-color:#46c2f2;box-shadow:0 0 16px #4dbaf133}}
button.f{background:linear-gradient(135deg,#2face7,#28a7c2)}
.v{text-shadow:0 0 14px #46c2f244}
</style></head><body><div class="aurora"><span></span><span></span><span></span></div><div class="fire"><i style="--x:4.0%;--w:80px;--d:1.36s;--dl:-0.55s"></i><i style="--x:12.2%;--w:63px;--d:0.75s;--dl:-0.75s"></i><i style="--x:20.4%;--w:83px;--d:1.11s;--dl:-1.27s"></i><i style="--x:28.6%;--w:73px;--d:0.73s;--dl:-0.61s"></i><i style="--x:36.8%;--w:64px;--d:0.87s;--dl:-0.77s"></i><i style="--x:45.0%;--w:63px;--d:1.28s;--dl:-0.17s"></i><i style="--x:53.2%;--w:74px;--d:1.14s;--dl:-0.82s"></i><i style="--x:61.4%;--w:63px;--d:1.1s;--dl:-0.56s"></i><i style="--x:69.6%;--w:74px;--d:0.73s;--dl:-1.2s"></i><i style="--x:77.8%;--w:78px;--d:0.99s;--dl:-0.76s"></i><i style="--x:86.0%;--w:96px;--d:0.92s;--dl:-1.14s"></i><i style="--x:94.2%;--w:71px;--d:0.77s;--dl:-0.8s"></i></div><div class="embers"><b style="--x:27%;--s:4px;--dx:-48px;--d:7.7s;--dl:-0.6s"></b><b style="--x:10%;--s:3px;--dx:3px;--d:8.4s;--dl:-3.8s"></b><b style="--x:43%;--s:5px;--dx:14px;--d:9.6s;--dl:-3.3s"></b><b style="--x:34%;--s:3px;--dx:29px;--d:8.9s;--dl:-0.7s"></b><b style="--x:41%;--s:5px;--dx:52px;--d:6.7s;--dl:-4.0s"></b><b style="--x:80%;--s:2px;--dx:-45px;--d:7.6s;--dl:-1.5s"></b><b style="--x:46%;--s:3px;--dx:59px;--d:7.4s;--dl:-0.4s"></b><b style="--x:88%;--s:2px;--dx:37px;--d:7.8s;--dl:-7.1s"></b><b style="--x:43%;--s:4px;--dx:28px;--d:6.8s;--dl:-4.5s"></b><b style="--x:61%;--s:2px;--dx:47px;--d:5.5s;--dl:-2.4s"></b><b style="--x:92%;--s:2px;--dx:-53px;--d:8.7s;--dl:-2.8s"></b><b style="--x:76%;--s:5px;--dx:-24px;--d:8.6s;--dl:-8.0s"></b><b style="--x:47%;--s:2px;--dx:60px;--d:7.3s;--dl:-1.5s"></b><b style="--x:17%;--s:5px;--dx:-53px;--d:6.1s;--dl:-2.6s"></b><b style="--x:97%;--s:3px;--dx:-10px;--d:7.0s;--dl:-7.8s"></b><b style="--x:13%;--s:3px;--dx:-3px;--d:7.0s;--dl:-2.5s"></b></div><div id="toast"></div><div id="app"></div>
<script>
const $=s=>document.querySelector(s),A=$("#app");let tab="core",me=null,role="user",lrole="admin",ws=null,timer=null;
const e=s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
function toast(m,bad){const t=$("#toast");t.textContent=m;t.style.borderColor=bad?"var(--bad)":"var(--g)";t.style.display="block";setTimeout(()=>t.style.display="none",3500)}
async function api(p,m="GET",b){const r=await fetch("/api/"+p,{method:m,headers:{"Content-Type":"application/json","X-Panel":"1"},body:b?JSON.stringify(b):undefined});const j=await r.json().catch(()=>({}));if(r.status==401&&p!="login"){me=null;return boot()}if(!r.ok)throw new Error(j.error||"Error");return j}
const go=f=>async(...a)=>{try{await f(...a)}catch(x){toast(x.message,1)}};
const gb=b=>(b/1073741824).toFixed(1)+" GB",fb=b=>((b||0)/1073741824).toFixed(2)+" GB",val=id=>$("#"+id).value;
const dur=s=>s>=86400?Math.floor(s/86400)+"d "+Math.floor(s%86400/3600)+"h":s>=3600?Math.floor(s/3600)+"h "+Math.floor(s%3600/60)+"m":Math.max(0,Math.floor(s/60))+"m "+(s%60)+"s";
const seen=t=>t?new Date(t*1000).toLocaleString():"never";
const foot=`<footer>Created by <b style="color:var(--g)">ALIRAZA</b> &nbsp;|&nbsp; Support: <a href="https://t.me/ar_tricks" target="_blank" rel="noopener">@ar_tricks</a></footer>`;
const put=(el,h)=>{if(!el)return false;if(el.__h!==h){el.__h=h;el.innerHTML=h;return true}return false};
const copyTxt=async t=>{try{await navigator.clipboard.writeText(t)}catch(_){const a=document.createElement("textarea");a.value=t;document.body.appendChild(a);a.select();document.execCommand("copy");a.remove()}toast("Copied")};
const TG="https://t.me/alirazax0";
const vbar=`<div class="vbar">🔒 View-only mode &middot; To use the full panel, get a key from <b>AliRaza</b> &rarr; <a href="${TG}" target="_blank" rel="noopener">t.me/alirazax0</a></div>`;
const vnote=()=>`<div class="card vn"><h2>🔒 View-only access</h2><div>You are signed in with a <b>view-only</b> account, so VPS details and server settings are hidden.</div><div style="margin-top:8px">Want to use the full panel? Get a key from <b style="color:var(--g)">AliRaza</b> on Telegram.</div><a class="tgb" href="${TG}" target="_blank" rel="noopener">✈ Message AliRaza on Telegram</a><div class="k" style="margin-top:8px">t.me/alirazax0</div></div>`;
let vpT=null;
function vpop(){if(role=="admin"||!me){document.querySelectorAll(".vpin").forEach(n=>n.remove());document.body.classList.remove("vo");return}if(document.querySelector(".vpin"))return;document.body.classList.add("vo");const d=document.createElement("div");d.className="vpin";d.innerHTML=`<div class="at">🔒 VIEW-ONLY MODE</div><div style="margin-top:6px;line-height:1.6">To use the <b>full panel</b>, get a key from <b style="color:var(--g)">AliRaza</b>.</div><a class="tgb" href="${TG}" target="_blank" rel="noopener">✈ t.me/alirazax0</a>`;document.body.appendChild(d)}
function showInfo(x){const h=x.host||x.domain||x.server_ip||location.hostname,gbl=x.gb||"Unlimited",ports=(x.ports&&x.ports.length?x.ports:[x.ssh_port||8443,109,447]).join(", "),
pl=x.payload||`GET /artricks HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]`,
all=`===== ALIRAZA ACCOUNT MANAGEMENT =====\n\nUsername: ${x.u}\nPassword: ${x.p}\nHost: ${h}\n${x.server_ip?"Server IP: "+x.server_ip+"\n":""}Expiry: ${x.exp||"-"}\nIP Limit: ${x.ip}\nData Limit: ${gbl}\n\nSSH Ports: ${ports}\nWS (HTTP): ${x.ws||80}\nWS+SSL: ${x.wss||443}\n\nPayload:\n${pl}\n\nCreated by ALIRAZA | https://t.me/ar_tricks`,
r=(i,k,v)=>`<div class="ir"><span class="k">${i} ${k}</span><b>${e(v)}</b></div>`;
document.querySelectorAll(".ov").forEach(n=>n.remove());
const d=document.createElement("div");d.className="ov";
d.innerHTML=`<div class="card"><div class="ah"><svg class="tick" viewBox="0 0 52 52"><circle class="okc" cx="26" cy="26" r="24"/><path class="okp" d="M14 27l8 8 16-17"/></svg><div class="at">ALIRAZA ACCOUNT MANAGEMENT</div><div class="as">&#9989; Account created successfully</div></div>
<div class="sec">&#128100; Login details</div>${r("&#128273;","Username",x.u)}${r("&#128274;","Password",x.p)}${r("&#9203;","Expires",x.exp||"-")}${r("&#128101;","IP limit",x.ip)}${r("&#128230;","Data limit",gbl)}
<div class="sec">&#127760; Server details</div>${r("&#127970;","Host / Domain",h)}${x.server_ip?r("&#128225;","Server IP",x.server_ip):""}${r("&#128268;","SSH ports",ports)}${r("&#9889;","WS (HTTP)",x.ws||80)}${r("&#128737;","WS + SSL",x.wss||443)}
<div class="sec">&#128220; Payload</div><pre class="c">${e(pl)}</pre>
<br><div class="row" style="justify-content:center"><button class="f" id="cb">Copy all</button><button class="s" id="pb">Copy payload</button><button class="s" id="xb">Close</button></div>
<div class="af">Created by <b style="color:var(--g)">ALIRAZA</b> &nbsp;|&nbsp; <a href="https://t.me/ar_tricks" target="_blank" rel="noopener" style="color:var(--f2);text-decoration:none">@ar_tricks</a></div></div>`;
document.body.appendChild(d);
d.querySelectorAll(".ir,.sec,pre,.row,.af").forEach((n,i)=>{n.style.animation="rise .45s cubic-bezier(.2,.8,.2,1) both";n.style.animationDelay=(.3+i*.055)+"s"});
{const cf=document.createElement("div");cf.className="cf";const cl=["#46c2f2","#adecfa","#2face7","#3ddc97","#ffd166","#ff6b81"];for(let i=0;i<40;i++){const p=document.createElement("i"),an=Math.random()*Math.PI*2,sp=90+Math.random()*200;p.style.cssText=`background:${cl[i%6]};--dx:${Math.cos(an)*sp}px;--dy:${Math.sin(an)*sp-70}px;--r:${Math.random()*720-360}deg;animation-delay:${.55+Math.random()*.15}s`;cf.appendChild(p)}d.appendChild(cf);setTimeout(()=>cf.remove(),2600)}
const close=()=>{d.remove();document.removeEventListener("keydown",esc)},esc=ev=>{if(ev.key=="Escape")close()};document.addEventListener("keydown",esc);
d.onclick=ev=>{if(ev.target===d)close()};d.querySelector("#xb").onclick=close;d.querySelector("#cb").onclick=()=>copyTxt(all);d.querySelector("#pb").onclick=()=>copyTxt(pl)}
async function boot(){const j=await fetch("/api/me").then(r=>r.json());me=j.u;role=j.role||"user";document.body.classList.toggle("ro",role!="admin");if(role!="admin"&&!["core","on","acc"].includes(tab))tab="core";me?shell():loginView()}
function loginView(){A.innerHTML=`<div class="login2"><div class="lgw"><section class="hero"><div class="orb"><div class="ring r1"><span class="dot d1"><em>⚡</em></span></div><div class="ring r2"><span class="dot d2"><em>🔒</em></span></div><div class="ring r3"><span class="dot d3"><em>🌐</em></span></div><div class="core"><span class="logo">🔮</span></div></div><h1 class="ttl">ALIRAZA</h1><div class="sub"><span class="typ">SSH MANAGEMENT</span></div><div class="chips"><span><i></i>Dropbear</span><span><i></i>WebSocket</span><span><i></i>SSL/TLS</span></div><div class="term"><div class="tl" style="--i:0">$ aliraza --status</div><div class="tl ok" style="--i:1">✔ secure tunnel ready</div><div class="tl ok" style="--i:2">✔ users synced · auto-kill on</div><div class="tl" style="--i:3">$ <b class="cur"></b></div></div></section><div class="lgc"><div class="card" style="text-align:left"><h2 style="margin-bottom:12px">🔐 Panel Login</h2><div class="rt"><button type="button" id="ra" class="${lrole=="admin"?"on":""}">Admin</button><button type="button" id="ru" class="${lrole=="user"?"on":""}">User (view only)</button></div><label>Username</label><input id="lu" autocomplete="username"><label>Password</label><input id="lp" type="password" autocomplete="current-password"><br><br><button class="f" style="width:100%" id="lb">Sign in</button></div></div></div>${foot}</div>`;
$("#ra").onclick=()=>{lrole="admin";loginView()};$("#ru").onclick=()=>{lrole="user";loginView()};$("#lb").onclick=go(async()=>{await api("login","POST",{u:val("lu"),p:val("lp"),role:lrole});boot()});$("#lp").onkeydown=ev=>{if(ev.key=="Enter")$("#lb").click()}}
const TABS={core:"Core",on:"Online",acc:"Accounts",ban:"Banner",tg:"Telegram Bot",set:"Settings"};
function shell(){A.innerHTML=`<header><button class="s" id="mb" aria-label="Menu">☰</button><div class="brand"><span class="logo">🔮</span> ALIRAZA<small>SSH Management Panel</small></div><div class="sp"></div><span class="b ${role=="admin"?"on1":"mu1"}">${role=="admin"?"ADMIN":"VIEW ONLY"}</span><button class="s" id="lo">Logout (${e(me)})</button></header>${role!="admin"?vbar:""}<div class="layout"><nav>${Object.entries(TABS).filter(([k])=>role=="admin"||["core","on","acc"].includes(k)).map(([k,v])=>`<a tabindex="0" data-t="${k}">${v}</a>`).join("")}</nav><main id="m"></main></div><div class="scrim" id="sc"></div>`;
const nv=document.querySelector("nav"),sc=$("#sc"),cl=()=>{nv.classList.remove("open");sc.classList.remove("show")};$("#mb").onclick=()=>{nv.classList.toggle("open");sc.classList.toggle("show",nv.classList.contains("open"))};sc.onclick=cl;
document.querySelectorAll("nav a").forEach(a=>{a.onclick=()=>{tab=a.dataset.t;cl();view()};a.onkeydown=ev=>{if(ev.key=="Enter")a.click()}});$("#lo").onclick=async()=>{await api("logout","POST");boot()};clearInterval(vpT);document.querySelectorAll(".vpin").forEach(n=>n.remove());document.body.classList.remove("vo");if(role!="admin"){vpop();vpT=setInterval(vpop,1000)}view()}
function view(){clearInterval(timer);if(ws){ws.close();ws=null}document.querySelectorAll("nav a").forEach(a=>a.classList.toggle("on",a.dataset.t==tab));const m=$("#m");m.innerHTML="";m.classList.add("enter");clearTimeout(view.t);view.t=setTimeout(()=>m.classList.remove("enter"),1100);go(V[tab])(m)}
const V={
async core(m){if(role!="admin"){m.innerHTML=`${vnote()}<div class="card" id="c1"><h2>Panel stats</h2><div class="k">Loading...</div></div>${foot}`;const dv=async()=>{const o=await api("overview");if(!$("#c1"))return;put($("#c1"),`<h2>Panel stats</h2><div class="grid"><div><div class="k">Accounts</div><div class="v">${o.users}</div></div><div><div class="k">Online now</div><div class="v">${o.online}</div></div></div>`)};await dv();timer=setInterval(()=>document.hidden||go(dv)(),10000);return}
m.innerHTML=`<div class="card" id="c1"><h2>VPS info</h2><div class="k">Loading...</div></div><div class="card" id="c2"><h2>SSH account info</h2></div><div class="card" id="c3"><h2>Services</h2></div>${foot}`;
const draw=async()=>{const o=await api("overview");if(!$("#c1"))return;const c=o.cfg,h=c.domain||o.ip,pct=a=>Math.round(a[0]/a[1]*100),pl=`GET /artricks HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]`;
put($("#c1"),`<h2>VPS info</h2><div class="grid"><div><div class="k">Host / OS</div>${e(o.host)}<br>${e(o.os)}</div><div><div class="k">Public IP</div><div class="v">${e(o.ip||"-")}</div></div><div><div class="k">Uptime</div><div class="v">${Math.floor(o.up/86400)}d ${Math.floor(o.up%86400/3600)}h</div></div><div><div class="k">Load</div><div class="v">${o.load.map(x=>x.toFixed(2)).join(" ")}</div></div>
<div><div class="k">CPU (${o.cores} cores)</div><div class="v">${o.cpu}%</div><div class="bar"><i style="width:${o.cpu}%"></i></div></div><div><div class="k">RAM ${gb(o.ram[0])} / ${gb(o.ram[1])}</div><div class="v">${pct(o.ram)}%</div><div class="bar"><i style="width:${pct(o.ram)}%"></i></div></div><div><div class="k">Disk ${gb(o.disk[0])} / ${gb(o.disk[1])}</div><div class="v">${pct(o.disk)}%</div><div class="bar"><i style="width:${pct(o.disk)}%"></i></div></div><div><div class="k">Panel users: upload / download</div><div class="v">${fb(o.rx)} / ${fb(o.tx)}</div><div class="k">Server NIC in / out: ${fb(o.nic_rx)} / ${fb(o.nic_tx)}</div></div></div>`);
if(put($("#c2"),`<h2>SSH account info</h2><div class="grid"><div><div class="k">Host</div>${e(h)}</div><div><div class="k">SSH port</div><div class="v">${c.ssh_port}</div></div><div><div class="k">WS / WS+SSL</div><div class="v">80 / 443</div></div><div><div class="k">Accounts / online</div><div class="v">${o.users} / ${o.online}</div></div></div><div class="k" style="margin-top:14px">Payload</div><pre class="c">${e(pl)}</pre><button class="s" id="cp">Copy payload</button>`))$("#cp").onclick=()=>copyTxt(pl);
if(put($("#c3"),`<h2>Services</h2><div class="tw"><table>${Object.entries(o.svc).map(([s,a])=>`<tr><td>${s}</td><td><span class="b ${a?"on1":"off1"}">${a?"running":"stopped"}</span></td><td class="wr"><button class="s" data-s="${s}">Restart</button></td></tr>`).join("")}</table></div><br><button class="f wr" id="fx">Fix SSH / WS connection</button> <button class="f wr" id="rf">&#128260; Refresh All</button><div class="k wr" style="margin-top:8px">Refresh All restarts every service and the panel. All users disconnect and reconnect. SSH accounts, limits and usage are not changed.</div>`)){
$("#c3").querySelectorAll("[data-s]").forEach(b=>b.onclick=go(async()=>{await api(`service/${b.dataset.s}/restart`,"POST");toast("Restarted "+b.dataset.s);draw()}));$("#fx").onclick=go(async()=>{await api("fix","POST");toast("Connection fixed");draw()});$("#rf").onclick=go(async()=>{if(!confirm("Refresh everything now?\n\nAll users will disconnect and reconnect, services restart and the panel reloads.\nSSH accounts, limits and usage are NOT changed."))return;await api("refresh","POST");clearInterval(timer);const o=document.createElement("div");o.className="ov";o.innerHTML='<div class="card vn"><h2 style="justify-content:center">&#128260; Refreshing...</h2><div class="k">Restarting services. The panel reloads by itself.</div></div>';document.body.appendChild(o);const t0=Date.now(),poll=async()=>{try{const r=await fetch("/api/me",{cache:"no-store"});if(r.ok&&Date.now()-t0>8000)return location.reload()}catch(_){}if(Date.now()-t0>60000)return location.reload();setTimeout(poll,1500)};setTimeout(poll,4000)})}};
await draw();timer=setInterval(()=>document.hidden||go(draw)(),10000)},
async acc(m){m.innerHTML=`<div class="card wr"><h2>Add account</h2><div class="row"><div><label>Username (kuch bhi likho)</label><input id="au" autocomplete="off" placeholder="any name / symbols"></div><div><label>Password (kuch bhi likho)</label><input id="ap" autocomplete="off" placeholder="any password"></div><div><label>Days</label><input id="ad" type="number" value="30"></div><div><label>IP limit</label><input id="ai" type="number" value="1"></div><div><label>Data limit GB (blank = unlimited)</label><input id="ag"></div></div><br><button class="f" id="aa">Create account</button></div>
<div class="card"><h2>Accounts <span class="k" id="cnt"></span></h2><div class="row"><div><input id="q" placeholder="Search username or IP"></div><div><select id="f"><option value="all">All</option><option value="on">Online</option><option value="off">Offline</option><option value="lock">Locked</option><option value="exp">Expired</option></select></div><div class="wr" style="flex:0 0 auto;min-width:0"><button class="s" id="cx">Delete expired</button></div></div><div class="tw"><table id="tb"></table></div></div>
<div class="card wr" id="ed" style="display:none"><h2>Edit <span id="en"></span></h2><div class="row"><div><label>New password</label><input id="ep"></div><div><label>Renew (days from today)</label><input id="ey" type="number"></div><div><label>IP limit</label><input id="ei" type="number"></div><div><label>Data limit GB</label><input id="eg"></div></div><br><div class="row" style="justify-content:flex-start"><button id="es">Save &amp; unlock</button><button class="s" id="el">Lock</button><button class="s" id="er">Reset usage</button></div></div>`;
let L=[];
const status=a=>!a.exists?"missing":a.locked?"locked":a.expired?"expired":a.online?"online":"offline";
const cls={online:"on1",offline:"mu1",locked:"off1",expired:"off1",missing:"off1"};
const paint=()=>{const q=val("q").toLowerCase(),f=val("f");
const rows=L.filter(a=>(!q||a.u.toLowerCase().includes(q)||a.ips.some(i=>i.includes(q)))&&(f=="all"||(f=="on"&&a.online)||(f=="off"&&!a.online)||(f=="lock"&&a.locked)||(f=="exp"&&a.expired)));
$("#cnt").textContent=`(${rows.length}/${L.length} shown, ${L.filter(a=>a.online).length} online)`;
put($("#tb"),`<tr><th>User</th><th>Status</th><th>Online IPs</th><th>Expires</th><th>Data</th><th>Last seen</th><th class="wr"></th></tr>`+(rows.map(a=>{const s=status(a);return `<tr data-u="${e(a.u)}"><td>${e(a.u)}</td><td><span class="b ${cls[s]}">${s}</span></td><td>${a.ips.map(e).join("<br>")||"-"}<div class="k">${a.online}/${e(a.ip)} sessions</div></td><td>${e(a.exp)}${a.days!=null?` (${a.days<0?"expired":a.days+"d left"})`:""}</td><td>${a.used}/${e(a.gb)} GB</td><td>${a.online?"now":seen(a.last)}</td><td class="wr" style="white-space:nowrap"><button class="s" data-a="e">Edit</button> ${a.online?`<button class="s" data-a="k">Kick</button> `:""}<button class="s" data-a="l" data-v="${a.locked?0:1}">${a.locked?"Unlock":"Lock"}</button> <button class="d" data-a="d">Delete</button></td></tr>`}).join("")||`<tr><td colspan="7">No accounts match.</td></tr>`))};
const load=async()=>{L=await api("accounts");paint()};
const edit=u=>{const a=L.find(x=>x.u==u)||{};$("#ed").style.display="block";$("#en").textContent=u;$("#ep").value="";$("#ey").value="";$("#ei").value=a.ip??"";$("#eg").value=a.gb=="Unlimited"?"":(a.gb??"");$("#ed").scrollIntoView();const body=x=>({p:val("ep"),days:val("ey"),ip:val("ei"),gb:val("eg"),...x});
$("#es").onclick=go(async()=>{await api("accounts/"+u,"PUT",body({lock:false}));toast("Saved");load()});$("#el").onclick=go(async()=>{await api("accounts/"+u,"PUT",body({lock:true}));toast("Locked");load()});$("#er").onclick=go(async()=>{await api("accounts/"+u,"PUT",body({reset:true,lock:false}));toast("Usage reset");load()})};
$("#aa").onclick=go(async()=>{const x={u:val("au"),p:val("ap"),days:val("ad"),ip:val("ai"),gb:val("ag")};const r=await api("accounts","POST",x);toast("Account created");["au","ap","ag"].forEach(i=>$("#"+i).value="");showInfo(r.info||{u:x.u,p:x.p,ip:x.ip||1,gb:x.gb,exp:new Date(Date.now()+(+x.days||30)*864e5).toISOString().slice(0,10)});go(load)()});
$("#q").oninput=paint;$("#f").onchange=paint;
$("#cx").onclick=go(async()=>{if(confirm("Delete ALL expired accounts?")){const r=await api("accounts/cleanup","POST");toast("Deleted "+r.deleted+" account(s)");load()}});
$("#tb").onclick=go(async ev=>{const b=ev.target.closest("button");if(!b)return;const u=b.closest("tr").dataset.u,k=b.dataset.a;
if(k=="e")return edit(u);
if(k=="k"){await api("kick","POST",{u});toast("Kicked "+u);return load()}
if(k=="l"){await api("accounts/"+u,"PUT",{lock:b.dataset.v=="1"});toast(b.dataset.v=="1"?"Locked "+u:"Unlocked "+u);return load()}
if(k=="d"&&confirm("Delete "+u+"?")){await api("accounts/"+u,"DELETE");toast("Deleted "+u);load()}});
await load();timer=setInterval(()=>document.hidden||go(load)(),6000)},
async on(m){m.innerHTML=`<div class="card"><h2>Online sessions <span class="k" id="oc"></span></h2><div class="row"><div><input id="oq" placeholder="Filter by username or IP"></div><div style="flex:0 0 auto;min-width:0"><button class="s" id="orf">Refresh now</button></div></div><div class="tw"><table id="ot"></table></div><div class="k" style="margin-top:8px">Updates every 5 seconds. Kick ends a session; lock the account in the Accounts tab to stop reconnects.</div></div>`;
let S=[];
const paint=()=>{const q=val("oq").toLowerCase(),r=S.filter(x=>!q||x.u.includes(q)||x.ip.includes(q));
put($("#ot"),`<tr><th>User</th><th>Client IP</th><th>Via</th><th>Connected</th><th>PID</th><th class="wr"></th></tr>`+(r.map(x=>`<tr data-p="${e(x.pid)}" data-u="${e(x.u)}" data-i="${e(x.ip)}"><td>${e(x.u)}</td><td>${e(x.ip)}</td><td>${x.via=="ws"?"WebSocket":"SSH direct"}</td><td>${dur(x.secs)}</td><td>${e(x.pid)}</td><td class="wr" style="white-space:nowrap"><button class="s" data-a="p">Kick session</button> <button class="s" data-a="u">Kick user</button> <button class="d" data-a="i">Kick IP</button></td></tr>`).join("")||`<tr><td colspan="6">Nobody is online right now.</td></tr>`))};
const load=async()=>{const r=await api("sessions");S=r.sessions;$("#oc").textContent=`(${r.sessions.length} sessions, ${r.users} users, ${r.ips} IPs)`;paint()};
$("#oq").oninput=paint;$("#orf").onclick=go(load);
$("#ot").onclick=go(async ev=>{const b=ev.target.closest("button");if(!b)return;const t=b.closest("tr"),k=b.dataset.a,body=k=="p"?{pid:t.dataset.p}:k=="u"?{u:t.dataset.u}:{ip:t.dataset.i};if(k!="p"&&!confirm("Kick all matching sessions?"))return;const r=await api("kick","POST",body);toast("Kicked "+r.killed+" session(s)");load()});
await load();timer=setInterval(()=>document.hidden||go(load)(),5000)},
async ban(m){const b=await api("banner");m.innerHTML=`<div class="card"><h2>SSH banner</h2><div class="k">HTML is allowed (for example &lt;font color="green"&gt;). Saved + applied to new connections right away (max 2000 bytes). Connected users stay online.</div><textarea id="bt" rows="10">${e(b.t)}</textarea><br><br><button class="f" id="bs">Save banner</button> <button class="s" id="bc">Clear</button></div>${foot}`;$("#bs").onclick=go(async()=>{await api("banner","PUT",{t:val("bt")});toast("Banner saved")});$("#bc").onclick=go(async()=>{$("#bt").value="";await api("banner","PUT",{t:""});toast("Banner cleared")})},
async tg(m){const draw=async(a)=>{const t=await api("tg"+(a?"?act="+a:""));m.innerHTML=`<div class="card"><h2>Telegram bot</h2><span class="b ${t.active?"on1":"off1"}">${t.active?"running":"stopped"}</span> ${t.token?`&nbsp; token ${e(t.token)} &nbsp; admin ${e(t.admin)}`:""}<div class="row" style="margin-top:12px;justify-content:flex-start"><button class="s" data-a="restart">Restart</button><button class="s" data-a="stop">Stop</button><button class="s" data-a="start">Start</button></div></div><div class="card"><h3>Connect bot</h3><label>Bot token (from @BotFather)</label><input id="tt"><label>Super admin Telegram ID</label><input id="ta" type="number"><br><br><button class="f" id="tc">Connect &amp; start</button></div>${foot}`;
m.querySelectorAll("[data-a]").forEach(b=>b.onclick=go(()=>draw(b.dataset.a)));$("#tc").onclick=go(async()=>{const r=await api("tg","POST",{token:val("tt"),admin:val("ta")});toast(r.ok?"Bot connected":"Failed: "+r.msg,!r.ok);draw()})};await draw()},
async set(m){const[o,ad]=await Promise.all([api("overview"),api("admins")]),c=o.cfg;m.innerHTML=`<div class="card"><h2>Ports &amp; domain</h2><div class="row"><div><label>Panel port</label><input id="sp" type="number" value="${c.panel_port}"></div><div><label>SSH port</label><input id="ss" type="number" value="${c.ssh_port}"></div><div><label>Domain</label><input id="sd" value="${e(c.domain)}"></div></div><label><input type="checkbox" id="sl" style="width:auto"> Issue Let's Encrypt SSL for a changed domain (DNS must point here)</label><br><button class="f" id="sv">Apply</button><div class="k" style="margin-top:8px">Changing the SSH port restarts Dropbear and disconnects live sessions. After a panel-port change, open the new port.</div></div>
<div class="card"><h2>Panel logins</h2><div class="tw"><table>${ad.map(a=>`<tr><td>${e(a.u)}</td><td><span class="b ${a.role=="admin"?"on1":"mu1"}">${a.role=="admin"?"admin":"user (view only)"}</span> ${a.role=="admin"?"":`<span class="b ${a.left!=null&&a.left<=0?"mu1":"on1"}">${a.left==null?"no expiry":a.left<=0?"expired":Math.ceil(a.left/86400)+" days left"}</span>`}</td><td>${a.role=="admin"?"":`<button class="s" data-e="${e(a.u)}">Add days</button> `}<button class="s" data-p="${e(a.u)}">Change password</button> <button class="d" data-x="${e(a.u)}">Delete</button></td></tr>`).join("")}</table></div><div class="row"><div><label>Username</label><input id="nu"></div><div><label>Password</label><input id="np" type="password"></div><div><label>Type</label><select id="nr"><option value="user">User (view only)</option><option value="admin">Admin (full access)</option></select></div><div><label>Key valid for (days, 0 = no expiry)</label><input id="nd" type="number" min="0" max="3650" value="30"></div></div><br><button id="nc">Create login</button> <button class="s" id="nn">Change my username</button></div>
<div class="card" style="border-color:#7a2236"><h2 style="color:var(--bad)">&#9888; Danger zone</h2><div class="k">Poora panel aur script is VPS se hata di jayegi: panel, WS proxy, Dropbear, Telegram bot, nginx config aur tuning. Ye wapas nahi hoga. Dobara chahiye to install script phir se chalani paegi.</div><div class="row" style="margin-top:10px"><div><label>Type UNINSTALL</label><input id="uc" autocomplete="off" placeholder="UNINSTALL"></div><div><label>Your admin password</label><input id="up" type="password" autocomplete="current-password"></div></div><label><input type="checkbox" id="uk" style="width:auto"> SSH accounts na hatao (sirf panel/script hatao)</label><br><button class="d" id="un">Uninstall panel &amp; script</button></div>${foot}`;
$("#sv").onclick=go(async()=>{const r=await api("settings","POST",{panel_port:val("sp"),ssh_port:val("ss"),domain:val("sd"),ssl:$("#sl").checked});toast("Applied. "+r.msg);if(r.cfg.panel_port!=location.port*1&&location.port)setTimeout(()=>location.port=r.cfg.panel_port,4000)});
$("#un").onclick=go(async()=>{if(val("uc")!=="UNINSTALL")throw new Error("Pehle box mein UNINSTALL likhein");if(!val("up"))throw new Error("Admin password likhein");if(!confirm("Poora panel + script uninstall ho jayega. Pakka?"))return;await api("uninstall","POST",{confirm:"UNINSTALL",p:val("up"),keep:$("#uk").checked});clearInterval(timer);document.body.innerHTML='<div style="min-height:100vh;display:flex;align-items:center;justify-content:center;background:#050c0f;color:#ecf9ff;font-family:sans-serif;text-align:center;padding:20px"><div><div style="font-size:42px">&#129529;</div><h2>Uninstall ho raha hai...</h2><p style="color:#8eaebe">Panel kuch seconds mein band ho jayega. Is page ko band kar dein.</p></div></div>'});
const ad_=go(async(b)=>{const r=await api("admin","POST",b);toast("Done");view()});$("#nc").onclick=()=>ad_({act:"create",u:val("nu"),p:val("np"),role:val("nr"),days:val("nd")});
$("#nn").onclick=()=>ad_({act:"rename",u:me,new:val("nu")});m.querySelectorAll("[data-p]").forEach(b=>b.onclick=()=>{const p=prompt("New password for "+b.dataset.p);p&&ad_({act:"password",u:b.dataset.p,p})});m.querySelectorAll("[data-e]").forEach(b=>b.onclick=()=>{const d=prompt("Add how many days to "+b.dataset.e+"?","30");d&&ad_({act:"extend",u:b.dataset.e,days:d})});m.querySelectorAll("[data-x]").forEach(b=>b.onclick=()=>confirm("Delete login?")&&ad_({act:"delete",u:b.dataset.x}))}};
boot();
</script></body></html>
UI_EOF

# ---- THEMES: adds a "Themes" tab (flame themes + new no-flame styles) and a logo to the panel UI ----
# Installs /usr/local/bin/uitheme and applies it to the freshly written index.html. Remove with: uitheme off
cat > /usr/local/bin/uitheme <<'PYEOF'
#!/usr/bin/env python3
import os,sys,re
D=os.environ.get("PANEL_DIR","/opt/aliraza-panel");F=D+"/index.html";O=D+"/index.orig.html";MK="ALR_THEMES"
JS=r'''
/* ALR_THEMES */
(function(){
const st=document.querySelector("style");if(!st)return;const ORIG=st.textContent;
const KEEP=["#4ade80","#ff4d6d","#e11d48","#4a1522","#0d3a22"];
const TH=[
{id:"ice",k:1,n:"Ice Blue",d:"Original icy look",mh:198,ms:1,ah:198,as:1},
{id:"gold",k:1,n:"Royal Gold",d:"Warm golden luxury",mh:42,ms:.75,ah:42,as:.85},
{id:"crimson",k:1,n:"Crimson Velvet",d:"Deep red, royal fire",mh:352,ms:.9,ah:352,as:.9},
{id:"emerald",k:1,n:"Emerald Luxe",d:"Rich jewel green",mh:152,ms:.8,ah:152,as:.75},
{id:"amethyst",k:1,n:"Royal Amethyst",d:"Noble violet glow",mh:268,ms:.75,ah:268,as:.8},
{id:"rose",k:1,n:"Rose Gold",d:"Soft blush metallic",mh:8,ms:.55,ah:8,as:.6},
{id:"platinum",k:1,n:"Platinum Silver",d:"Cold steel and white",mh:215,ms:.12,ah:215,as:.15},
{id:"blackgold",k:2,n:"Black & Gold",d:"Onyx base, gold flames",mh:40,ms:.1,ah:43,as:.85},
{id:"burgundy",k:2,n:"Burgundy & Gold",d:"Wine base, gold accents",mh:345,ms:.85,ah:43,as:.85},
{id:"navyrose",k:2,n:"Midnight & Rose Gold",d:"Navy base, rose flames",mh:224,ms:.8,ah:10,as:.6},
{id:"emgold",k:2,n:"Emerald & Gold",d:"Green base, gold flames",mh:155,ms:.8,ah:43,as:.85},
{id:"purgold",k:2,n:"Royal Purple & Gold",d:"Violet base, gold flames",mh:270,ms:.8,ah:43,as:.85},
{id:"onyxred",k:2,n:"Onyx & Crimson",d:"Black base, red flames",mh:0,ms:.05,ah:355,as:.9},
{id:"sapphire",k:2,n:"Sapphire & Platinum",d:"Deep blue, silver flames",mh:218,ms:1,ah:220,as:.12},
{id:"synth",k:3,fx:"synth",n:"Neon Synthwave",d:"Retro sun, moving grid",mh:285,ms:.9,ah:315,as:.95,ac:"#ff3df0",pv:"linear-gradient(#150a2e,#3a0a5a 70%,#ff3df044)",cd:"#1e0f3a",ln:"#5a2a8a"},
{id:"matrix",k:3,fx:"matrix",n:"Matrix Code",d:"Falling green code",mh:140,ms:.85,ah:135,as:.9,ac:"#2dff88",pv:"repeating-linear-gradient(90deg,#2dff8833 0 2px,#03140a 2px 11px)",cd:"#06210f",ln:"#1a6a3a"},
{id:"galaxy",k:3,fx:"galaxy",n:"Deep Galaxy",d:"Twinkling and shooting stars",mh:245,ms:.75,ah:262,as:.8,ac:"#9d8bff",pv:"radial-gradient(circle at 20% 30%,#fff 0 1px,transparent 2px),radial-gradient(circle at 70% 60%,#fff 0 1px,transparent 2px),radial-gradient(circle at 50% 20%,#9d8bff55,#07061c 70%)",cd:"#0f0d2e",ln:"#3b358a"},
{id:"snow",k:3,fx:"snow",n:"Winter Snow",d:"Soft falling snow",mh:208,ms:.5,ah:200,as:.55,ac:"#bfe6ff",pv:"radial-gradient(circle at 25% 35%,#fff 0 2px,transparent 3px),radial-gradient(circle at 65% 25%,#fff 0 2px,transparent 3px),linear-gradient(#0b1c2c,#1c3a52)",cd:"#12293b",ln:"#3a6483"},
{id:"ocean",k:3,fx:"ocean",n:"Ocean Depth",d:"Waves and rising bubbles",mh:190,ms:.9,ah:178,as:.85,ac:"#3fe0ff",pv:"linear-gradient(#042436,#0a5a78)",cd:"#08354b",ln:"#1b7396"},
{id:"sakura",k:3,fx:"sakura",n:"Sakura Dream",d:"Drifting petals",mh:330,ms:.5,ah:340,as:.6,ac:"#ff8fb8",pv:"linear-gradient(135deg,#2a0f20,#4a1b36)",cd:"#341327",ln:"#7a2f55"},
{id:"circuit",k:3,fx:"techgrid",n:"Tech Circuit",d:"Pulsing grid, radar sweep",mh:178,ms:.6,ah:176,as:.9,ac:"#22e0d0",pv:"linear-gradient(#22e0d022 1px,transparent 1px) 0 0/10px 10px,linear-gradient(90deg,#22e0d022 1px,transparent 1px) 0 0/10px 10px,#06161a",cd:"#0a2328",ln:"#1b6a70"},
{id:"pearl",k:3,fx:"pearl",n:"Pearl Light",d:"Clean light luxury",mh:198,ms:1,ah:198,as:1,ac:"#1b78b8",pv:"linear-gradient(#f7fbff,#dcebf8)",cd:"#ffffff",ln:"#c4d6e6"}
];
function hsl(h){const r=parseInt(h.slice(0,2),16)/255,g=parseInt(h.slice(2,4),16)/255,b=parseInt(h.slice(4,6),16)/255,mx=Math.max(r,g,b),mn=Math.min(r,g,b),l=(mx+mn)/2;let hh=0,s=0;if(mx!==mn){const q=mx-mn;s=l>.5?q/(2-mx-mn):q/(mx+mn);hh=mx===r?(g-b)/q+(g<b?6:0):mx===g?(b-r)/q+2:(r-g)/q+4;hh/=6}return[hh,s,l]}
function rgb(h,s,l){const f=(p,q,t)=>{if(t<0)t+=1;if(t>1)t-=1;return t<1/6?p+(q-p)*6*t:t<.5?q:t<2/3?p+(q-p)*(2/3-t)*6:p},q=l<.5?l*(1+s):l+s-l*s,p=2*l-q;return[f(p,q,h+1/3),f(p,q,h),f(p,q,h-1/3)].map(x=>("0"+Math.round(x*255).toString(16)).slice(-2)).join("")}
function sh(hex,t){if(KEEP.indexOf("#"+hex.slice(0,6).toLowerCase())>-1&&hex.length==6)return hex;const v=hsl(hex),a=v[2]>=.45&&v[1]>.3,T=a?t.ah:t.mh,S=a?t.as:t.ms;let h=(v[0]+(T-198)/360)%1;if(h<0)h+=1;return rgb(h,Math.min(1,v[1]*S),v[2])+hex.slice(6)}
function xf(css,t){return css.replace(/#([0-9a-fA-F]{8}|[0-9a-fA-F]{6})\b/g,(m,h)=>KEEP.indexOf(m.toLowerCase())>-1?m:"#"+sh(h,t))}
const g=k=>{try{return localStorage.getItem(k)}catch(_){return null}},p=(k,v)=>{try{localStorage.setItem(k,v)}catch(_){}};
let cur=g("alr_theme")||"ice",fl=g("alr_fire")!=="0",em=g("alr_emb")!=="0";
const R=(a,b)=>a+Math.random()*(b-a),N=(n,f)=>Array.from({length:n},(_,i)=>f(i)).join("");
const P=(a,b,d)=>R(a,b).toFixed(d==null?1:d);
const GEM='<svg class="alrlogo" viewBox="0 0 24 24" width="24" height="28" aria-hidden="true"><defs><linearGradient id="alrgm" x1="0" y1="1" x2="0" y2="0"><stop offset="0" class="fs1"/><stop offset=".55" class="fs2"/><stop offset="1" class="fs3"/></linearGradient></defs><path fill="url(#alrgm)" d="M12 1.5l8.5 7.2L12 22.5 3.5 8.7z"/><path fill="#fff" fill-opacity=".55" d="M12 1.5l3.2 7.2H8.8z"/></svg>';
const SPC=`.logo{animation:alr_gem 3.2s ease-in-out infinite!important}@keyframes alr_gem{0%,100%{filter:drop-shadow(0 0 4px var(--f2));transform:scale(1)}50%{filter:drop-shadow(0 0 12px var(--f2));transform:scale(1.08)}}.alrlogo{filter:none!important}`;
const FX={
synth(){return{h:'<div class="sg"></div><div class="sn"></div><div class="sl"></div>',c:`
#alrfx .sg{position:absolute;left:-60%;right:-60%;bottom:0;height:58%;background:repeating-linear-gradient(90deg,#ff3df055 0 2px,transparent 2px 64px),repeating-linear-gradient(0deg,#22d3ee55 0 2px,transparent 2px 56px);transform:perspective(420px) rotateX(64deg);transform-origin:50% 100%;animation:alr_grid 2.4s linear infinite;-webkit-mask-image:linear-gradient(transparent,#000 45%);mask-image:linear-gradient(transparent,#000 45%)}
@keyframes alr_grid{to{background-position:0 0,0 56px}}
#alrfx .sn{position:absolute;left:50%;bottom:30%;width:min(46vw,300px);aspect-ratio:1;margin-left:calc(min(46vw,300px)/-2);border-radius:50%;background:linear-gradient(#ffd166 0%,#ff3df0 70%);opacity:.38;-webkit-mask-image:repeating-linear-gradient(transparent 0 10px,#000 10px 22px);mask-image:repeating-linear-gradient(transparent 0 10px,#000 10px 22px);animation:alr_breath 5s ease-in-out infinite}
@keyframes alr_breath{50%{opacity:.55;transform:scale(1.05)}}
#alrfx .sl{position:absolute;left:0;right:0;height:120px;background:linear-gradient(transparent,#22d3ee14,transparent);animation:alr_scan 6s linear infinite}
@keyframes alr_scan{from{top:-120px}to{top:100%}}`}},
matrix(){return{h:N(26,i=>`<b style="left:${(i*3.9+R(0,2)).toFixed(1)}%;animation-duration:${P(6,14)}s;animation-delay:-${P(0,12)}s;font-size:${Math.round(R(12,17))}px">${N(22,()=>"01/{}$#=+*ABZ"[Math.floor(R(0,13))]+"<br>")}</b>`),c:`
#alrfx b{position:absolute;top:0;font:700 14px/1.25 ui-monospace,Menlo,Consolas,monospace;color:#2dff88;text-shadow:0 0 8px #2dff88;opacity:.38;transform:translateY(-110%);animation:alr_rain linear infinite;-webkit-mask-image:linear-gradient(transparent,#000 70%);mask-image:linear-gradient(transparent,#000 70%)}
@keyframes alr_rain{from{transform:translateY(-110%)}to{transform:translateY(100vh)}}`}},
galaxy(){return{h:N(90,()=>`<i style="left:${P(0,100)}%;top:${P(0,100)}%;--s:${P(1,3)}px;--d:${P(2,6)}s;--dl:-${P(0,6)}s"></i>`)+N(3,i=>`<u style="top:${P(0,40,0)}%;left:${P(30,90,0)}%;animation-delay:${(i*4+R(0,3)).toFixed(1)}s"></u>`)+'<div class="nb"></div>',c:`
#alrfx i{position:absolute;width:var(--s);height:var(--s);border-radius:50%;background:#fff;box-shadow:0 0 6px #cfd8ff;animation:alr_tw var(--d) ease-in-out infinite;animation-delay:var(--dl)}
@keyframes alr_tw{0%,100%{opacity:.15;transform:scale(.7)}50%{opacity:1;transform:scale(1.25)}}
#alrfx u{position:absolute;width:140px;height:2px;background:linear-gradient(90deg,#fff,transparent);opacity:0;animation:alr_shoot 12s linear infinite}
@keyframes alr_shoot{0%{opacity:0;transform:translate(0,0) rotate(-35deg)}3%{opacity:1}10%{opacity:0;transform:translate(-420px,300px) rotate(-35deg)}100%{opacity:0}}
#alrfx .nb{position:absolute;left:-10%;top:-20%;width:70%;height:90%;background:radial-gradient(ellipse,#6d5bff30,transparent 65%);filter:blur(30px);animation:alr_nb 26s ease-in-out infinite alternate}
@keyframes alr_nb{to{transform:translate(18%,12%) scale(1.2)}}`}},
snow(){return{h:N(70,()=>`<i style="left:${P(0,100)}%;--s:${P(3,8)}px;--d:${P(8,18)}s;--dl:-${P(0,18)}s;--dx:${P(-60,60,0)}px;opacity:${P(.4,.9,2)}"></i>`)+'<div class="sf"></div>',c:`
#alrfx i{position:absolute;top:-12px;width:var(--s);height:var(--s);border-radius:50%;background:#fff;box-shadow:0 0 8px #cfeaff;animation:alr_snow var(--d) linear infinite;animation-delay:var(--dl)}
@keyframes alr_snow{from{transform:translate(0,0)}50%{transform:translate(var(--dx),55vh)}to{transform:translate(calc(var(--dx)*-.6),108vh)}}
#alrfx .sf{position:absolute;left:0;right:0;bottom:0;height:90px;background:linear-gradient(transparent,#dff2ff22)}`}},
ocean(){const w='<path d="M0 60 Q150 0 300 60 T600 60 T900 60 T1200 60 T1500 60 T1800 60 T2100 60 T2400 60 V120 H0Z"/>';return{h:`<svg class="wv w1" viewBox="0 0 2400 120" preserveAspectRatio="none">${w}</svg><svg class="wv w2" viewBox="0 0 2400 120" preserveAspectRatio="none">${w}</svg>`+N(20,()=>`<i style="left:${P(0,100)}%;--s:${P(6,22,0)}px;--d:${P(7,15)}s;--dl:-${P(0,15)}s;--dx:${P(-40,40,0)}px"></i>`),c:`
#alrfx .wv{position:absolute;left:0;bottom:0;width:200%;height:110px}
#alrfx .w1 path{fill:#1fb5d8;fill-opacity:.22}#alrfx .w2 path{fill:#0ea5c9;fill-opacity:.18}
#alrfx .w1{animation:alr_wave 14s linear infinite}#alrfx .w2{height:86px;animation:alr_wave 21s linear infinite reverse}
@keyframes alr_wave{to{transform:translateX(-50%)}}
#alrfx i{position:absolute;bottom:-24px;width:var(--s);height:var(--s);border-radius:50%;border:1px solid #9fefff99;background:radial-gradient(circle at 30% 30%,#ffffff55,#5ee0ff14);animation:alr_bub var(--d) ease-in infinite;animation-delay:var(--dl)}
@keyframes alr_bub{from{transform:translate(0,0);opacity:0}10%{opacity:.9}to{transform:translate(var(--dx),-100vh);opacity:0}}`}},
sakura(){return{h:N(26,()=>`<i style="left:${P(0,100)}%;--s:${P(9,17,0)}px;--d:${P(9,18)}s;--dl:-${P(0,18)}s;--dx:${P(-90,90,0)}px"></i>`),c:`
#alrfx i{position:absolute;top:-24px;width:var(--s);height:calc(var(--s)*.75);background:linear-gradient(135deg,#ffd1e3,#ff8fb8);border-radius:150% 0 150% 0;opacity:.8;animation:alr_pet var(--d) linear infinite;animation-delay:var(--dl)}
@keyframes alr_pet{0%{transform:translate(0,0) rotate(0)}50%{transform:translate(var(--dx),55vh) rotate(180deg)}100%{transform:translate(calc(var(--dx)*-.5),108vh) rotate(380deg)}}`}},
techgrid(){return{h:'<div class="tg"></div><div class="tr"></div>'+N(16,()=>`<i style="left:${P(2,98)}%;top:${P(4,96)}%;--dl:-${P(0,5)}s"></i>`),c:`
#alrfx .tg{position:absolute;inset:-60px;background:linear-gradient(#22e0d012 1px,transparent 1px),linear-gradient(90deg,#22e0d012 1px,transparent 1px);background-size:46px 46px;animation:alr_pan 16s linear infinite}
@keyframes alr_pan{to{transform:translate(46px,46px)}}
#alrfx .tr{position:absolute;left:0;right:0;height:3px;background:linear-gradient(90deg,transparent,#22e0d0aa,transparent);box-shadow:0 0 18px #22e0d0;animation:alr_scan 7s linear infinite}
@keyframes alr_scan{from{top:-4px}to{top:100%}}
#alrfx i{position:absolute;width:7px;height:7px;border-radius:50%;background:#22e0d0;box-shadow:0 0 10px #22e0d0;animation:alr_pulse 3s ease-in-out infinite;animation-delay:var(--dl)}
@keyframes alr_pulse{0%,100%{opacity:.15;transform:scale(.7)}50%{opacity:.9;transform:scale(1.3)}}`}},
pearl(){return{h:'<div class="pb a"></div><div class="pb b"></div>',c:`
#alrfx .pb{position:absolute;width:42vmax;height:42vmax;border-radius:50%;filter:blur(80px);opacity:.5;animation:alr_drift 22s ease-in-out infinite alternate}
#alrfx .pb.a{background:#9fd3f6;left:-10vmax;top:-12vmax}#alrfx .pb.b{background:#f6c6dd;right:-12vmax;bottom:-14vmax;animation-delay:-8s}
@keyframes alr_drift{to{transform:translate(8vw,6vh) scale(1.18)}}
:root{--bg:#f4f7fb;--card:#fff;--card2:#eef3f9;--line:#d5dfeb;--tx:#10202e;--mu:#5d7184;--g:#1b78b8;--g2:#1b78b8;--f1:#2a8fd6;--f2:#1b78b8;--f3:#16507a}
html,body{background:#f4f7fb!important;color:#10202e!important}
body::before{background:radial-gradient(800px 460px at 8% -8%,#7cc4f244,transparent 62%),radial-gradient(760px 460px at 100% 0,#9fd8f238,transparent 60%)!important}
header{background:#ffffffee!important}
nav a{background:#ffffffcc!important;color:#41586c!important}nav a.on{color:#fff!important;background:linear-gradient(135deg,#2a8fd6,#1b78b8)!important}
.card{background:linear-gradient(180deg,#fff,#f7fafd)!important;box-shadow:0 6px 24px #1b4a6e1a!important;animation:none!important}
.grid>div,input,textarea,select,.term{background:#f1f6fb!important;color:#10202e!important}
pre.c{background:#eef4fa!important;color:#16507a!important}.bar{background:#dfe9f3!important}
td,th{border-color:#dde6ef!important}
.b.on1{background:#d9f6e6!important;color:#13803f!important}.mu1{background:#e3ebf3!important}.off1{background:#fde0e6!important}
button.s{color:#16507a!important;border-color:#b6c9db!important}button.s:hover{background:#e3edf7!important}
.v{text-shadow:none!important;color:#16507a!important}h2,h3{color:#10202e!important}
.vbar{background:#e1effa!important;color:#16507a!important}.vbar a{color:#16507a!important}
.vpin{background:#fff!important;color:#10202e!important}.ov{background:#10202ea0!important}
::placeholder{color:#8aa0b3!important}.k,label{color:#5d7184!important}
.ttl,.brand .bt,.ov .at{background:linear-gradient(90deg,#16507a,#1b78b8,#2a8fd6,#16507a)!important;background-size:200% 100%!important;-webkit-background-clip:text!important;background-clip:text!important}
.chips span{background:#ffffffcc!important;color:#16507a!important}.dot{background:#fff!important}.core{background:radial-gradient(circle,#2a8fd633,#fff 70%)!important}
@media(max-width:820px){nav{background:#fff!important}}`}}
};
function ensure(id,tag){let e=document.getElementById(id);if(!e){e=document.createElement(tag);e.id=id;(tag=="style"?document.head:document.body).appendChild(e)}return e}
function fixLogo(){const sp=!!(TH.find(x=>x.id==cur)||{}).fx;document.querySelectorAll(".logo").forEach(el=>{const m=sp?"g":"f";if(el.dataset.m===m)return;if(!el.dataset.o)el.dataset.o=el.innerHTML;el.dataset.m=m;el.innerHTML=sp?(el.dataset.o.indexOf("<svg")>-1?GEM:"\u{1F48E}"):el.dataset.o})}
function apply(){const t=TH.find(x=>x.id==cur)||TH[0],sp=!!t.fx;st.textContent=t.id=="ice"?ORIG:xf(ORIG,t);const mt=document.querySelector('meta[name="theme-color"]');if(mt)mt.content=t.id=="pearl"?"#f4f7fb":"#"+sh("050c0f",t);
document.querySelectorAll(".fire").forEach(e=>e.style.display=(!sp&&fl)?"":"none");document.querySelectorAll(".embers").forEach(e=>e.style.display=(!sp&&em)?"":"none");document.querySelectorAll(".aurora").forEach(e=>e.style.display=sp?"none":"");
let fx=document.getElementById("alrfx"),xs=document.getElementById("alrxs");
if(sp){const d=FX[t.fx]();fx=fx||ensure("alrfx","div");xs=xs||ensure("alrxs","style");fx.innerHTML=d.h;xs.textContent="#alrfx{position:fixed;inset:0;z-index:0;pointer-events:none;overflow:hidden}"+SPC+d.c}else{if(fx)fx.remove();if(xs)xs.remove()}
fixLogo()}
apply();
try{new MutationObserver(fixLogo).observe(document.getElementById("app"),{childList:true,subtree:true})}catch(_){}
function cardS(t){const on=t.id==cur;return `<div class="tc" data-id="${t.id}" tabindex="0" role="button" style="cursor:pointer;border:${on?"2px solid "+t.ac:"1px solid var(--line)"};border-radius:14px;overflow:hidden;background:var(--card2)"><div style="position:relative;height:78px;background:${t.pv};overflow:hidden"><div style="position:absolute;left:10px;top:9px;font-weight:800;font-size:13px;letter-spacing:1px;color:${t.ac}">ALIRAZA</div><div style="position:absolute;right:8px;top:8px;width:34px;height:14px;border-radius:7px;background:${t.ac}"></div><div style="position:absolute;left:10px;right:10px;top:30px;height:16px;border-radius:6px;background:${t.cd};border:1px solid ${t.ln}"></div></div><div style="padding:9px 11px 11px"><div style="font-weight:700;font-size:13.5px;color:var(--f3)">${t.n}</div><div class="k" style="margin-top:2px">${t.d}</div><div style="margin-top:7px;display:flex;gap:5px;align-items:center"><i style="width:14px;height:14px;border-radius:50%;background:${t.cd};border:1px solid ${t.ln};display:inline-block"></i><i style="width:14px;height:14px;border-radius:50%;background:${t.ac};display:inline-block"></i>${on?'<span class="b on1" style="margin-left:auto">Active</span>':""}</div></div></div>`}
function card(t){if(t.k==3)return cardS(t);const c=x=>"#"+sh(x,t),bg=c("050c0f"),cd=c("0b1a21"),ln=c("265064"),a1=c("2face7"),a2=c("87d9f9"),f1=c("effbff"),f2=c("38a6e8"),on=t.id==cur;
return `<div class="tc" data-id="${t.id}" tabindex="0" role="button" style="cursor:pointer;border:${on?"2px solid "+a2:"1px solid var(--line)"};border-radius:14px;overflow:hidden;background:var(--card2)"><div style="position:relative;height:78px;background:${bg};overflow:hidden"><div style="position:absolute;left:-10%;right:-10%;bottom:-26px;height:70px;background:radial-gradient(ellipse at 50% 100%,${f1} 0%,${a2} 22%,${f2} 48%,transparent 72%);filter:blur(7px);opacity:.9"></div><div style="position:absolute;left:10px;top:9px;font-weight:800;font-size:13px;letter-spacing:1px;color:${a2}">ALIRAZA</div><div style="position:absolute;right:8px;top:8px;width:34px;height:14px;border-radius:7px;background:${a1}"></div><div style="position:absolute;left:10px;right:10px;top:30px;height:16px;border-radius:6px;background:${cd};border:1px solid ${ln}"></div></div><div style="padding:9px 11px 11px"><div style="font-weight:700;font-size:13.5px;color:var(--f3)">${t.n}</div><div class="k" style="margin-top:2px">${t.d}</div><div style="margin-top:7px;display:flex;gap:5px;align-items:center"><i style="width:14px;height:14px;border-radius:50%;background:${cd};border:1px solid ${ln};display:inline-block"></i><i style="width:14px;height:14px;border-radius:50%;background:${a1};display:inline-block"></i><i style="width:14px;height:14px;border-radius:50%;background:${a2};display:inline-block"></i>${on?'<span class="b on1" style="margin-left:auto">Active</span>':""}</div></div></div>`}
const grid=a=>`<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px">${a.map(card).join("")}</div>`;
if(typeof TABS!=="undefined"){delete TABS.set;TABS.theme="Themes";TABS.set="Settings"}
V.theme=async function(m){const draw=()=>{m.innerHTML=`<div class="card"><h2>Themes</h2><div class="k">Pick a look for this panel. It is saved on this device and applies to the login screen too.</div><div style="margin-top:12px;display:flex;gap:8px;flex-wrap:wrap"><button class="${fl?"f":"s"}" id="tf">Flames: ${fl?"ON":"OFF"}</button><button class="${em?"f":"s"}" id="te">Embers: ${em?"ON":"OFF"}</button></div><div class="k" style="margin-top:8px">Flames and embers belong to the flame themes. The new styles below use their own effects.</div></div><div class="card"><h2>Single color + flames</h2>${grid(TH.filter(x=>x.k==1))}</div><div class="card"><h2>Double color + flames</h2>${grid(TH.filter(x=>x.k==2))}</div><div class="card"><h2>New styles &middot; no flames</h2><div class="k" style="margin-bottom:12px">Each one has its own animated background and a gem logo instead of the flame.</div>${grid(TH.filter(x=>x.k==3))}</div>${foot}`;
m.querySelectorAll(".tc").forEach(e=>{const pick=()=>{cur=e.dataset.id;p("alr_theme",cur);apply();draw();toast("Theme: "+TH.find(x=>x.id==cur).n)};e.onclick=pick;e.onkeydown=ev=>{if(ev.key=="Enter")pick()}});
$("#tf").onclick=()=>{fl=!fl;p("alr_fire",fl?"1":"0");apply();draw()};$("#te").onclick=()=>{em=!em;p("alr_emb",em?"1":"0");apply();draw()}};draw()};
})();
'''
if len(sys.argv)>1 and sys.argv[1]=="off":
    if os.path.exists(O): open(F,"w").write(open(O).read());print("Themes section removed (original UI restored).")
    else: print("Nothing to restore.")
    sys.exit()
if not os.path.exists(F): sys.exit("Not found: "+F+" (panel not installed here?)")
cur=open(F).read()
if "--bg:#050c0f" in cur and MK not in cur: open(O,"w").write(cur)   # fresh install -> new pristine copy
if not os.path.exists(O): sys.exit("No clean copy found. Re-run the installer (menu.sh), then run this again.")
s=open(O).read()
if "--bg:#050c0f" not in s: sys.exit("Clean copy is not the original ice UI. Re-run the installer (menu.sh), then run this again.")
a='["core","on","acc"].includes(k)'
if a not in s: sys.exit("Panel version not recognised (nav filter not found).")
s=s.replace(a,'["core","on","acc","theme"].includes(k)',1)
SV="""<span class="logo"><svg class="alrlogo" viewBox="0 0 24 28" width="24" height="28" aria-hidden="true"><defs><linearGradient id="alrfg" x1="0" y1="1" x2="0" y2="0"><stop offset="0" class="fs1"/><stop offset=".55" class="fs2"/><stop offset="1" class="fs3"/></linearGradient></defs><path fill="url(#alrfg)" d="M12 1c.8 4.2 6.4 7.2 6.4 13.6A6.4 6.4 0 0 1 5.6 14.6c0-2.6 1.3-4.4 2.6-5.6.2 1.8 1 3 2.2 3C9.9 8.2 10.6 4.3 12 1z"/><path fill="#fff" fill-opacity=".85" d="M12 14c.5 1.8 2.6 3 2.6 5a2.6 2.6 0 0 1-5.2 0c0-1.4.8-2.1 1.4-2.8.3.9.8 1.2 1.2 1.2z"/></svg></span>"""
C1=".brand{background:none!important;-webkit-background-clip:border-box!important;background-clip:border-box!important;-webkit-text-fill-color:initial!important;color:var(--tx)}.brand .bt{background:linear-gradient(90deg,#adecfa,#46c2f2,#2face7,#adecfa);background-size:200% 100%;animation:shine 4s linear infinite;-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:transparent}"
C2=".alrlogo{vertical-align:-6px;margin-right:6px;filter:drop-shadow(0 0 5px #4dbaf1aa)}.fs1{stop-color:#38a6e8}.fs2{stop-color:#a5e4ff}.fs3{stop-color:#effbff}"
s=re.sub(r"""<div class="brand">.*?<small>""",lambda m:'<div class="brand">'+SV+'<span class="bt"> ALIRAZA</span><small>',s,count=1,flags=re.S)
s=s.replace('<span class="logo">\U0001F52E</span>','<span class="logo">\U0001F525</span>')
s=s.replace("</style>",C1+C2+"</style>",1)
i=s.rfind("boot();\n</script>")
if i<0: sys.exit("Panel version not recognised (boot call not found).")
s=s[:i]+JS+s[i:]
open(F,"w").write(s)
print("OK: Themes section added. Open the panel, hard refresh, and tap 'Themes' in the menu.")
PYEOF
chmod +x /usr/local/bin/uitheme
uitheme || echo -e "${Y}Themes tab could not be added (panel still works). Run: uitheme${N}"

python3 -m venv /opt/aliraza-panel/venv && /opt/aliraza-panel/venv/bin/pip install -q --disable-pip-version-check --retries 5 --timeout 30 flask flask-sock gunicorn psutil || { echo -e "${R}Panel libraries failed to install (pip). Check internet and re-run.${N}"; exit 1; }
step 4 "Preparing the Telegram bot engine"
( python3 -m venv /opt/rr-tgbot-venv && /opt/rr-tgbot-venv/bin/pip install -q --disable-pip-version-check --retries 5 --timeout 30 "python-telegram-bot==20.7" ) &>/var/log/aliraza-tgvenv.log &
TG_PID=$!
step 5 "Setting up domain, SSL & SSH"
echo "{\"domain\":\"$DOMAIN\",\"panel_port\":$PP,\"ssh_port\":$SP}" > /etc/artricks/panel.json; echo "$DOMAIN" > /etc/artricks/domain.conf
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=$DOMAIN" -keyout /etc/artricks/ssl/self.key -out /etc/artricks/ssl/self.crt 2>/dev/null
systemctl stop nginx 2>/dev/null
certbot certonly --standalone --preferred-challenges http --agree-tos --register-unsafely-without-email -n -d "$DOMAIN" || uiwarn "SSL could not be issued - using a self-signed certificate (retry later from panel Settings)"
mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
printf '#!/bin/sh\nsystemctl stop nginx\n' > /etc/letsencrypt/renewal-hooks/pre/aliraza-nginx.sh
printf '#!/bin/sh\nsystemctl start nginx\n' > /etc/letsencrypt/renewal-hooks/post/aliraza-nginx.sh
chmod +x /etc/letsencrypt/renewal-hooks/pre/aliraza-nginx.sh /etc/letsencrypt/renewal-hooks/post/aliraza-nginx.sh
# ---- join the background Dropbear build (must be finished before the panel configures Dropbear) ----
kill -0 "$DB_PID" 2>/dev/null && echo -e "${Y}Waiting for the Dropbear build to finish...${N}"
if wait "$DB_PID"; then
  echo -e "${G}Dropbear built: SSH-2.0-AliRaza-server${N}"
else
  cat "$DB_OUT" 2>/dev/null
  uiwarn "Custom SSH build failed - using stock Dropbear (log: /var/log/aliraza-dropbear-build.log)"
  rm -f /usr/local/sbin/dropbear /etc/artricks/dbmaxwin
fi
rm -f "$DB_OUT"
cd /opt/aliraza-panel
ADMIN_U="$AU" ADMIN_P="$AP" ./venv/bin/python - <<'PYI'
import os,app
from werkzeug.security import generate_password_hash as g
c=app.db();c.execute("delete from admins");c.execute("insert into admins(u,p,role) values(?,?,'admin')",(os.environ["ADMIN_U"],g(os.environ["ADMIN_P"])));c.commit()
print(app.apply_dropbear());print(app.apply_nginx())
PYI
step 6 "Starting services & health check"
# ---- Cloudflare real client IP + panel-only traffic counter ----
cat > /usr/local/bin/aliraza-cfip.sh <<'CF'
#!/bin/bash
OUT=/etc/nginx/conf.d/00-aliraza-realip.conf
CF4=$(curl -fsS -m 15 https://www.cloudflare.com/ips-v4 2>/dev/null)
CF6=$(curl -fsS -m 15 https://www.cloudflare.com/ips-v6 2>/dev/null)
[[ -z "$CF4" ]] && CF4="173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22"
[[ -z "$CF6" ]] && CF6="2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32"
[[ -f $OUT ]] && cp -f $OUT $OUT.bak
{
  echo "# Cloudflare trusted proxies: real client IP is taken from CF-Connecting-IP only when the peer is Cloudflare"
  printf '%s\n%s\n' "$CF4" "$CF6" | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' | sed 's/.*/set_real_ip_from &;/'
  echo "real_ip_header CF-Connecting-IP;"
  echo "real_ip_recursive on;"
} > $OUT
if nginx -t >/dev/null 2>&1; then
  systemctl reload nginx 2>/dev/null
else
  if [[ -f $OUT.bak ]]; then cp -f $OUT.bak $OUT; else rm -f $OUT; fi
  echo "nginx test failed - real-ip config reverted"; exit 1
fi
CF
chmod +x /usr/local/bin/aliraza-cfip.sh; /usr/local/bin/aliraza-cfip.sh || true
printf '#!/bin/sh\n/usr/local/bin/aliraza-cfip.sh >/dev/null 2>&1\n' > /etc/cron.weekly/aliraza-cfip; chmod +x /etc/cron.weekly/aliraza-cfip
cat > /usr/local/bin/aliraza-traffic.py <<'TR'
import subprocess, json, os, time, re
STATE = "/etc/artricks/traffic.json"
CFG = "/etc/artricks/panel.json"
RA = re.compile(r"bytes_acked:(\d+)")
RR = re.compile(r"bytes_received:(\d+)")
def ports():
    p = {"109", "447"}
    try: p.add(str(int(json.load(open(CFG)).get("ssh_port", 8443))))
    except Exception: p.add("8443")
    return p
def load():
    try:
        d = json.load(open(STATE))
        return int(d.get("rx", 0)), int(d.get("tx", 0)), int(d.get("since", time.time()))
    except Exception:
        return 0, 0, int(time.time())
def save(rx, tx, since):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f: json.dump({"rx": rx, "tx": tx, "since": since}, f)
    os.replace(tmp, STATE)
def sample(pp):
    # per-connection kernel counters on the Dropbear listening ports (client-facing side only)
    try:
        out = subprocess.check_output(["ss", "-tinH", "state", "established"], stderr=subprocess.DEVNULL, timeout=10).decode("utf-8", "ignore")
    except Exception:
        return None
    cur = {}
    key = None
    for line in out.splitlines():
        if not line.strip(): continue
        if not line[0].isspace():
            t = line.split()
            key = None
            if len(t) >= 4 and t[2].rsplit(":", 1)[-1] in pp:
                key = (t[2], t[3])
        elif key:
            a = RA.search(line); r = RR.search(line)
            if a or r:
                cur[key] = (int(a.group(1)) if a else 0, int(r.group(1)) if r else 0)
            key = None
    return cur
def main():
    rx, tx, since = load()
    prev = None
    last_save = 0
    while True:
        cur = sample(ports())
        if cur is not None:
            if prev is not None:
                for k, (sent, recv) in cur.items():
                    ps, pr = prev.get(k, (0, 0))
                    if sent >= ps: tx += sent - ps      # bytes sent to users  = their download
                    if recv >= pr: rx += recv - pr      # bytes from users     = their upload
            prev = cur
        if time.time() - last_save > 10:
            save(rx, tx, since); last_save = time.time()
        time.sleep(3)
if __name__ == "__main__":
    main()
TR
cat > /etc/systemd/system/aliraza-traffic.service <<'TS'
[Unit]
Description=ALIRAZA panel traffic counter
After=network.target
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/aliraza-traffic.py
Restart=always
RestartSec=3
Nice=10
[Install]
WantedBy=multi-user.target
TS
if command -v ufw >/dev/null && ufw status | grep -q active; then for p in 80 443 $PP $SP 109 447 2299; do ufw allow $p/tcp; done; fi
# ---- full uninstall script (used by the panel's Uninstall button) ----
cat > /usr/local/bin/aliraza-uninstall.sh <<'UNI'
#!/bin/bash
# ALIRAZA full uninstall.  Usage: aliraza-uninstall.sh [keep-users]
[[ $EUID -ne 0 ]] && { echo "run as root"; exit 1; }
exec >>/var/log/aliraza-uninstall.log 2>&1
echo "=== uninstall started $(date) ==="
sleep 2
KEEP=0; [[ "$1" == "keep-users" ]] && KEEP=1

# 1) SSH accounts created by the panel (never touches system users: uid < 1000 is skipped)
if [[ $KEEP -eq 0 && -d /etc/artricks/users ]]; then
  for f in /etc/artricks/users/*.conf; do
    [[ -e "$f" ]] || continue
    u=$(basename "$f" .conf)
    uid_=$(id -u "$u" 2>/dev/null) || continue
    [[ "$uid_" -ge 1000 ]] || continue
    pkill -KILL -u "$u" 2>/dev/null; userdel -f "$u" 2>/dev/null
  done
fi

# 2) services (the panel itself is stopped last)
for s in tgbot ws-proxy autokill aliraza-watchdog aliraza-ban-ssh aliraza-ban aliraza-tune aliraza-traffic dropbear; do
  systemctl disable --now "$s" 2>/dev/null
done
systemctl disable aliraza-panel 2>/dev/null

# 3) blocked-IP firewall chain
for T in iptables ip6tables; do
  while $T -t nat -D PREROUTING -j ALIRAZA_BAN 2>/dev/null; do :; done
  $T -t nat -F ALIRAZA_BAN 2>/dev/null; $T -t nat -X ALIRAZA_BAN 2>/dev/null
done

# 4) nginx: remove our configs, restore the original nginx.conf and the default site
rm -f /etc/nginx/conf.d/vpn.conf /etc/nginx/conf.d/panel.conf /etc/nginx/conf.d/00-aliraza-tune.conf /etc/nginx/conf.d/00-aliraza-realip.conf /etc/nginx/conf.d/00-aliraza-realip.conf.bak
[[ -f /etc/nginx/nginx.conf.aliraza.bak ]] && cp -f /etc/nginx/nginx.conf.aliraza.bak /etc/nginx/nginx.conf && rm -f /etc/nginx/nginx.conf.aliraza.bak
[[ -e /etc/nginx/sites-available/default && ! -e /etc/nginx/sites-enabled/default ]] && ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
rm -f /etc/systemd/system/nginx.service.d/aliraza.conf
rm -f /etc/systemd/system/*.service.d/aliraza.conf
rm -rf /etc/systemd/system/dropbear.service.d
rmdir /etc/systemd/system/nginx.service.d 2>/dev/null

# 5) OpenSSH tuning
rm -f /etc/ssh/sshd_config.d/0[0-9]-aliraza*.conf
if grep -qE 'ALIRAZA (tuning|speed layer)' /etc/ssh/sshd_config 2>/dev/null; then
  if [[ -f /etc/ssh/sshd_config.aliraza.bak ]]; then cp -f /etc/ssh/sshd_config.aliraza.bak /etc/ssh/sshd_config; fi
fi
rm -f /etc/ssh/sshd_config.aliraza.bak /etc/ssh/sshd_config.pre
if sshd -t 2>/dev/null; then systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; fi

# 6) system tuning files
rm -f /etc/sysctl.d/99-artricks-ssh.conf /etc/security/limits.d/99-aliraza.conf /etc/logrotate.d/aliraza /etc/systemd/journald.conf.d/aliraza.conf /etc/systemd/system.conf.d/aliraza.conf
rm -f /etc/letsencrypt/renewal-hooks/pre/aliraza-nginx.sh /etc/letsencrypt/renewal-hooks/post/aliraza-nginx.sh /etc/cron.weekly/aliraza-cfip

# 7) service units, scripts, data
rm -f /etc/systemd/system/{ws-proxy,autokill,tgbot,aliraza-panel,aliraza-tune,aliraza-watchdog,aliraza-ban-ssh,aliraza-ban,aliraza-traffic}.service
rm -f /usr/local/bin/{ws-proxy.py,autokill.py,tgbot.py,aliraza-traffic.py,uitheme,menu} /usr/bin/menu /usr/local/bin/aliraza-*.sh /usr/local/sbin/dropbear
rm -f /var/log/ws-proxy.log /var/log/aliraza-tgvenv.log /var/log/aliraza-dropbear-build.log /var/log/aliraza-install.log
rm -rf /etc/artricks /opt/rr-tgbot-venv
systemctl daemon-reload; systemctl reset-failed 2>/dev/null
sysctl --system >/dev/null 2>&1
if nginx -t >/dev/null 2>&1; then systemctl restart nginx 2>/dev/null; fi

# 8) the panel last (this script may have been started by it)
rm -rf /opt/aliraza-panel
echo "=== uninstall finished $(date) ==="
systemctl stop aliraza-panel 2>/dev/null
rm -f /usr/local/bin/aliraza-uninstall.sh
UNI
chmod +x /usr/local/bin/aliraza-uninstall.sh
# real-time scheduling (rr) + realtime I/O: written as drop-ins ONLY if this kernel/container really allows it
# (inside OpenVZ/LXC systemd would refuse to start a unit that asks for rr, so it is tested first)
mkdir -p /etc/systemd/system/ws-proxy.service.d /etc/systemd/system/dropbear.service.d
rm -f /etc/systemd/system/ws-proxy.service.d/20-aliraza-rt.conf /etc/systemd/system/dropbear.service.d/20-aliraza-rt.conf
if chrt -r 10 true 2>/dev/null; then
  { echo '[Service]'; echo 'CPUSchedulingPolicy=rr'; echo 'CPUSchedulingPriority=50'
    ionice -c1 -n4 true 2>/dev/null && echo 'IOSchedulingClass=realtime'; } > /etc/systemd/system/ws-proxy.service.d/20-aliraza-rt.conf
  printf '[Service]\nCPUSchedulingPolicy=rr\n' > /etc/systemd/system/dropbear.service.d/20-aliraza-rt.conf
fi
systemctl daemon-reload; systemctl enable --now ws-proxy autokill aliraza-panel aliraza-tune aliraza-watchdog aliraza-ban-ssh aliraza-ban aliraza-traffic; systemctl restart nginx
wait "$TG_PID" 2>/dev/null
if ! /opt/rr-tgbot-venv/bin/python -c 'import telegram' 2>/dev/null; then
  echo -e "${Y}Telegram bot libraries missing - retrying once...${N}"
  python3 -m venv /opt/rr-tgbot-venv >>/var/log/aliraza-tgvenv.log 2>&1
  /opt/rr-tgbot-venv/bin/pip install -q --disable-pip-version-check --retries 5 --timeout 30 "python-telegram-bot==20.7" >>/var/log/aliraza-tgvenv.log 2>&1 \
    || uiwarn "Telegram bot libraries failed to install - panel works, bot will not start (log: /var/log/aliraza-tgvenv.log)"
fi
# ---- silent health check, then the summary card
sleep 2
FAILS=()
for svc in nginx dropbear ws-proxy autokill aliraza-panel aliraza-watchdog aliraza-ban-ssh; do
  systemctl is-active --quiet "$svc" || FAILS+=("service $svc")
done
for prt in $PP $SP 109 447 80 443 12026 2082 2299; do
  ss -tln 2>/dev/null | grep -q ":$prt " || FAILS+=("port $prt")
done
CODE=$(curl -sk -o /dev/null -m 6 -w '%{http_code}' "https://127.0.0.1:$PP/" 2>/dev/null)
[[ "$CODE" == "200" ]] || FAILS+=("panel answered HTTP ${CODE:-none}")
# speed-tuning checks: warnings only, never failures (cake/fq_codel and cpufreq do not exist on OpenVZ/LXC)
_ifc=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
tc qdisc show dev "$_ifc" 2>/dev/null | grep -qE 'cake|fq_codel' || uiwarn "qdisc is not cake/fq_codel (kernel/virtualization may not support it) - speed tuning still active"
[[ "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)" == performance ]] || uiwarn "CPU governor is not 'performance' (normal on most VPS) - continuing"
IDENT=$(timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/109; head -n1 <&3' 2>/dev/null | tr -d '\r')
step_done
{
  row() { printf '   %b%-12s%b %b%s%b\n' "$D" "$1" "$N" "${3:-$W}" "$2" "$N"; }
  [[ $IS_TTY == 1 ]] && printf '\033[?25h'
  echo
  COLS=$(tput cols 2>/dev/null || echo 80)
  if [[ ${#FAILS[@]} -eq 0 ]]; then BC=$G; T1="INSTALLATION  COMPLETE"; T2="ALIRAZA SSH MANAGEMENT PANEL"
  else BC=$Y; T1="INSTALLED - SOME CHECKS NEED A LOOK"; T2="ALIRAZA SSH MANAGEMENT PANEL"; fi
  if [[ ${COLS:-80} -ge 56 ]]; then
    printf '  %b╔════════════════════════════════════════════════╗%b\n' "$BC" "$N"
    printf '  %b║%b%*s%s%*s%b║%b\n' "$BC" "$W" $(( (48-${#T1})/2 )) '' "$T1" $(( 48-${#T1}-(48-${#T1})/2 )) '' "$BC" "$N"
    printf '  %b║%b%*s%s%*s%b║%b\n' "$BC" "$D" $(( (48-${#T2})/2 )) '' "$T2" $(( 48-${#T2}-(48-${#T2})/2 )) '' "$BC" "$N"
    printf '  %b╚════════════════════════════════════════════════╝%b\n\n' "$BC" "$N"
  else
    printf '  %b✔ %s%b\n  %b%s%b\n\n' "$BC" "$T1" "$N" "$D" "$T2" "$N"
  fi
  row "Panel URL" "https://$DOMAIN:$PP" "$C"
  row "Username" "$AU"
  row "Password" "$AP" "$G"
  row "Login tab" "Admin"
  row "SSH ports" "$SP, 109, 447"
  row "WebSocket" "80 (HTTP)  ·  443 (SSL)"
  if [[ "$IDENT" == "SSH-2.0-AliRaza-server" ]]; then row "SSH engine" "$IDENT" "$G"; else row "SSH engine" "stock Dropbear (custom build unavailable)" "$Y"; fi
  echo
  printf '   %b🔥 Open in your VPS cloud firewall (TCP):%b %s\n' "$Y" "$N" "80, 443, $PP, $SP, 109, 447"
  printf '   %bView-only users: panel > Settings > Panel logins (type: User)%b\n' "$D" "$N"
  if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo
    printf '   %b⚠ Needs attention:%b %s\n' "$Y" "$N" "$(IFS=,; echo "${FAILS[*]}" | sed 's/,/, /g')"
    printf '   %bDetails: %s%b\n' "$D" "$LOG" "$N"
  fi
  echo
  printf '   %bCreated by ALIRAZA  ·  Support: https://t.me/ar_tricks%b\n\n' "$D" "$N"
} >&3
