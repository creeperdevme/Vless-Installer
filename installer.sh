#!/bin/bash
set -e

# Color and style definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Header banner
show_header() {
echo -e "${BLUE}${BOLD}==================================================${NC}"
echo -e "${BLUE}${BOLD}                 Vless Installer                  ${NC}"
echo -e "${BLUE}${BOLD}==================================================${NC}"
echo ""
}

check_requirements() {
# Privilege check
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] Please run this script with root privileges! (Try: sudo su)${NC}"
    exit 1
fi

# Require a running systemd system manager.
if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    echo -e "${RED}[ERROR] This installer requires Linux running systemd.${NC}"
    exit 1
fi
}

# Dynamic progress spinner function
show_spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
    wait "$pid"
}

install_services() {
# ----------------- 1. Interactive Inputs -----------------

# Prompt for GH-Proxy
read -p "Do you want to use GH-Proxy to accelerate GitHub downloads? (y/n): " use_proxy
if [[ "$use_proxy" =~ ^[Yy]$ ]]; then
    PROXY_PREFIX="https://gh-proxy.com/"
    echo -e "${GREEN} -> GH-Proxy acceleration enabled.${NC}\n"
else
    PROXY_PREFIX=""
    echo -e "${YELLOW} -> Connecting to GitHub directly.${NC}\n"
fi

# Prompt for Cloudflare Token
while [ -z "$cf_token" ]; do
    read -r -s -p "Please paste your Cloudflare Tunnel Token: " cf_token
    echo
    if [ -z "$cf_token" ]; then
        echo -e "${RED} [ERROR] Token cannot be empty. Please try again!${NC}"
    fi
done
echo -e "${GREEN} -> Token saved.${NC}\n"

# Prompt for Domain
while [ -z "$domain_name" ]; do
    read -p "Please enter your complete public domain name (e.g., node.yourdomain.com): " domain_name
    if [ -z "$domain_name" ]; then
        echo -e "${RED} [ERROR] Domain cannot be empty. Please try again!${NC}"
    fi
done
echo -e "${GREEN} -> Domain saved: ${domain_name}${NC}\n"

# ----------------- 2. Fetch Server Info (ASN & Location) -----------------

echo -e "${BLUE}${BOLD}Fetching server network details...${NC}"
ip_info=$(curl -fsS --max-time 10 'http://ip-api.com/line/?fields=status,countryCode,as,org') || ip_info=""

if echo "$ip_info" | grep -q "success"; then
    country=$(echo "$ip_info" | sed -n '2p')
    asn_full=$(echo "$ip_info" | sed -n '3p' | awk '{print $1}')
    isp_org=$(echo "$ip_info" | sed -n '4p' | tr ' ' '_')
    node_name="${asn_full}_${isp_org}_${country}"
    node_name=$(echo "$node_name" | sed 's/[^a-zA-Z0-9_-]//g')
else
    node_name="Vless_Cloud_Node"
fi
echo -e "${GREEN} -> Node Name Generated: ${node_name}${NC}\n"

# ----------------- 3. System Environment Setup -----------------

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH_SB="amd64" ;;
    aarch64) ARCH_SB="arm64" ;;
    *) echo -e "${RED}[ERROR] Unsupported architecture: $ARCH${NC}"; exit 1 ;;
esac

mkdir -p /etc/sing-box /usr/local/bin

custom_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "66666666-6666-6666-6666-666666666666")
vless_user=$(echo "$custom_uuid" | cut -d'-' -f1)

# ----------------- 4. Download and Installation -----------------

SINGBOX_URL="${PROXY_PREFIX}https://github.com/SagerNet/sing-box/releases/download/v1.10.7/sing-box-1.10.7-linux-${ARCH_SB}.tar.gz"
CLOUDFLARED_URL="${PROXY_PREFIX}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_SB}"

echo -e "${BLUE}${BOLD}[1/4] Downloading and installing sing-box...${NC}"
(
    curl -fsSLo sing-box.tar.gz "$SINGBOX_URL"
    tar -zxf sing-box.tar.gz
    mv sing-box-1.10.7-linux-${ARCH_SB}/sing-box /usr/local/bin/
    rm -rf sing-box.tar.gz sing-box-1.10.7-linux-${ARCH_SB}
) & show_spinner $!
echo -e "${GREEN} -> sing-box installed successfully!${NC}\n"


echo -e "${BLUE}${BOLD}[2/4] Generating sing-box configuration...${NC}"
cat <<JSON > /etc/sing-box/config.json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "127.0.0.1",
      "listen_port": 8080,
      "users": [
        {
          "name": "${vless_user}",
          "uuid": "${custom_uuid}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vless-ws-path"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
JSON
echo -e "${GREEN} -> Configuration written to /etc/sing-box/config.json${NC}\n"


echo -e "${BLUE}${BOLD}[3/4] Downloading and installing Cloudflare Tunnel...${NC}"
(
    cloudflared_tmp=$(mktemp /usr/local/bin/cloudflared.XXXXXX)
    trap 'rm -f -- "$cloudflared_tmp"' EXIT
    curl -fsSLo "$cloudflared_tmp" "$CLOUDFLARED_URL"
    chmod +x "$cloudflared_tmp"
    mv -f -- "$cloudflared_tmp" /usr/local/bin/cloudflared
) & show_spinner $!
echo -e "${GREEN} -> cloudflared installed successfully!${NC}\n"


echo -e "${BLUE}${BOLD}[4/4] Configuring and starting systemd services...${NC}"

# Store the token outside the unit file in a root-only environment file.
install -d -m 700 /etc/cloudflared
escaped_token=${cf_token//\\/\\\\}
escaped_token=${escaped_token//\"/\\\"}
(
    umask 077
    printf 'TUNNEL_TOKEN="%s"\n' "$escaped_token" > /etc/cloudflared/tunnel.env
)
chmod 600 /etc/cloudflared/tunnel.env
unset cf_token escaped_token

cat <<'UNIT' > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box VLESS WebSocket proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

cat <<'UNIT' > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel
Wants=network-online.target sing-box.service
After=network-online.target sing-box.service

[Service]
Type=simple
EnvironmentFile=/etc/cloudflared/tunnel.env
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

chmod 644 /etc/systemd/system/sing-box.service /etc/systemd/system/cloudflared.service
/usr/local/bin/sing-box check -c /etc/sing-box/config.json

systemctl daemon-reload
systemctl stop cloudflared.service sing-box.service

# Migrate background processes launched by the previous installer.
# Match only the command lines used by that installer.
pkill -f '^/usr/local/bin/sing-box run -c /etc/sing-box/config[.]json$' || true
pkill -f '^/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ' || true
sleep 2

systemctl enable sing-box.service cloudflared.service
if ! systemctl restart sing-box.service cloudflared.service; then
    echo -e "${RED}[ERROR] Service startup failed. Inspect logs with:${NC}"
    echo "    journalctl -u sing-box -u cloudflared -n 100 --no-pager"
    exit 1
fi

sleep 2

echo " Service Status Check:"
services_ok=true
for service in sing-box cloudflared; do
    if systemctl is-active --quiet "${service}.service"; then
        echo -e "    - ${service}: ${GREEN}Running (Active)${NC}"
    else
        echo -e "    - ${service}: ${RED}Failed (Check: journalctl -u ${service} -n 100 --no-pager)${NC}"
        services_ok=false
    fi
done
echo ""
if [ "$services_ok" != true ]; then
    exit 1
fi

# ----------------- 5. Output Node Link -----------------

vless_link="vless://${custom_uuid}@${domain_name}:443?encryption=none&security=tls&type=ws&path=%2Fvless-ws-path&sni=${domain_name}&host=${domain_name}#${node_name}"

echo -e "${GREEN}${BOLD}==================================================${NC}"
echo -e "${GREEN}${BOLD} Deployment Completed Successfully!${NC}"
echo -e "${BOLD} Your VLESS Link:${NC}"
echo -e "${PURPLE}${BOLD}${vless_link}${NC}"
echo -e "${GREEN}${BOLD}==================================================${NC}"

}

unit_exists() {
    local load_state
    load_state=$(systemctl show "$1.service" --property=LoadState --value) || return 1
    [[ -n "$load_state" && "$load_state" != "not-found" ]]
}

show_status() {
    local service active enabled
    for service in sing-box cloudflared; do
        if unit_exists "$service"; then
            active=$(systemctl is-active "$service.service") || :
            enabled=$(systemctl is-enabled "$service.service") || :
            printf '  %-12s Status: %-12s Boot: %s\n' "$service" "${active:-unknown}" "${enabled:-unknown}"
        else
            printf '  %-12s Not installed\n' "$service"
        fi
    done
}

start_services() {
    local service
    for service in sing-box cloudflared; do
        if ! unit_exists "$service"; then
            echo -e "${RED}[ERROR] ${service} is not installed. Choose Install first.${NC}"
            return 1
        fi
    done
    systemctl start sing-box.service cloudflared.service
    sleep 2
    for service in sing-box cloudflared; do
        if ! systemctl is-active --quiet "$service.service"; then
            echo -e "${RED}[ERROR] ${service} failed to start. Check: journalctl -u ${service} -n 100 --no-pager${NC}"
            return 1
        fi
    done
    show_status
}

stop_services() {
    local service
    for service in cloudflared sing-box; do
        if unit_exists "$service"; then
            systemctl stop "$service.service"
        fi
    done
    show_status
}

uninstall_services() {
    local service
    for service in cloudflared sing-box; do
        if unit_exists "$service"; then
            systemctl stop "$service.service"
            systemctl disable "$service.service"
        fi
    done

    # Remove only files created by this installer, preserving other directory contents.
    rm -f -- /etc/systemd/system/sing-box.service /etc/systemd/system/cloudflared.service \
        /usr/local/bin/sing-box /usr/local/bin/cloudflared \
        /etc/sing-box/config.json /etc/cloudflared/tunnel.env
    rmdir -- /etc/sing-box /etc/cloudflared 2>/dev/null || true
    systemctl daemon-reload
    echo -e "${GREEN} -> Uninstalled both services, binaries, configuration, and saved token.${NC}"
    echo "The remote Cloudflare tunnel and DNS records remain in your Cloudflare account."
}

main() {
    check_requirements
    local choice action result
    while true; do
        show_header
        printf '%s\n' '1. Install' '2. Uninstall' '3. Status' '4. Start Service' '5. Stop Service' '0. Exit'
        if ! read -r -p "Choose an option [0-5]: " choice; then
            echo
            break
        fi
        case "$choice" in
            1) action=install_services ;;
            2) action=uninstall_services ;;
            3) action=show_status ;;
            4) action=start_services ;;
            5) action=stop_services ;;
            0) break ;;
            *) echo -e "${YELLOW}Invalid option. Choose 0-5.${NC}"; continue ;;
        esac

        # A separate shell keeps failures and install variables out of the menu.
        # Do not wrap this in an if: that would suppress errexit inside the action.
        set +e
        ( set -e; "$action" )
        result=$?
        set -e
        if [ "$result" -ne 0 ]; then
            echo -e "${RED}[ERROR] Action failed (exit ${result}). Review the output above.${NC}"
        fi
        echo
        read -r -p "Press Enter to return to the menu..." || break
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
