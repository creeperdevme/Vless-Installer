cat << 'EOF' > installer.sh
#!/bin/bash

# Color and style definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Header banner
clear
echo -e "${BLUE}${BOLD}==================================================${NC}"
echo -e "${BLUE}${BOLD}                 Vless Installer                  ${NC}"
echo -e "${BLUE}${BOLD}==================================================${NC}"
echo ""

# Privilege check
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] Please run this script with root privileges! (Try: sudo su)${NC}"
    exit 1
fi

# Dynamic progress spinner function
show_spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

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
    read -p "Please paste your Cloudflare Tunnel Token: " cf_token
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
ip_info=$(curl -s http://ip-api.com/line/?fields=status,countryCode,as,org)

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
    curl -sLo sing-box.tar.gz "$SINGBOX_URL"
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
    curl -sLo /usr/local/bin/cloudflared "$CLOUDFLARED_URL"
    chmod +x /usr/local/bin/cloudflared
) & show_spinner $!
echo -e "${GREEN} -> cloudflared installed successfully!${NC}\n"


echo -e "${BLUE}${BOLD}[4/4] Starting background processes (No-Systemd mode)...${NC}"

# Kill any existing background instances
pkill -f sing-box
pkill -f cloudflared

# Start sing-box in background
nohup /usr/local/bin/sing-box run -c /etc/sing-box/config.json > /var/log/sing-box.log 2>&1 &

# Start cloudflared in background
nohup /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "${cf_token}" > /var/log/cloudflared.log 2>&1 &

sleep 2

# Verify Background Processes Status
SB_RUNNING=$(pgrep -f "sing-box")
CF_RUNNING=$(pgrep -f "cloudflared")

echo -e " Service Status Check:"
if [ -n "$SB_RUNNING" ]; then
    echo -e "    - sing-box:   ${GREEN}Running (Active)${NC}"
else
    echo -e "    - sing-box:   ${RED}Failed (Check log with: cat /var/log/sing-box.log)${NC}"
fi

if [ -n "$CF_RUNNING" ]; then
    echo -e "    - cloudflared:${GREEN}Running (Active)${NC}"
else
    echo -e "    - cloudflared:${RED}Failed (Check log with: cat /var/log/cloudflared.log)${NC}"
fi
echo ""

# ----------------- 5. Output Node Link -----------------

vless_link="vless://${custom_uuid}@${domain_name}:443?encryption=none&security=tls&type=ws&path=%2Fvless-ws-path&sni=${domain_name}&host=${domain_name}#${node_name}"

echo -e "${GREEN}${BOLD}==================================================${NC}"
echo -e "${GREEN}${BOLD} Deployment Completed Successfully!${NC}"
echo -e "${BOLD} Your VLESS Link:${NC}"
echo -e "${PURPLE}${BOLD}${vless_link}${NC}"
echo -e "${GREEN}${BOLD}==================================================${NC}"

EOF

chmod +x installer.sh
