#!/bin/bash

exec 3>&1
exec > /dev/null 2>&1

# Function to show usage
usage() {
  echo "Usage: decho wireguard {create user {interface:user} [--address=IP/CIDR] [--dns=DNS] [--listen-port=PORT] [--force]} | {rm user {interface:user}}" >&3
  exit 1
}

# Function to handle 'create user' command
create_user() {
  local COMMAND2=$1
  local COMMAND3=$2
  local PARAM=$3
  shift 3

  # Extract interface and user
  IFS=':' read -r INTERFACE USER <<< "$PARAM"
  if [ -z "$INTERFACE" ] || [ -z "$USER" ]; then
    usage
  fi

  # Default values
  ADDRESS=""
  DNS="1.1.1.1"
  LISTEN_PORT=""
  FORCE=false

  # Parse flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --address=*)
        ADDRESS="${1#*=}"
        ;;
      --dns=*)
        DNS="${1#*=}"
        ;;
      --listen-port=*)
        LISTEN_PORT="${1#*=}"
        ;;
      --force)
        FORCE=true
        ;;
      *)
        usage
        ;;
    esac
    shift
  done

  # Check if required flags are provided
  if [ -z "$ADDRESS" ]; then
    echo "--address flag is required" >&3
    usage
  fi

  # Check if user already exists
  if [ -f "/etc/wireguard/conf/$INTERFACE/$USER.conf" ]; then
    if [ "$FORCE" = true ]; then
      echo "User $USER already exists. --force flag detected, proceeding with deletion." >&3
      rm -rf "/etc/wireguard/key/$INTERFACE/$USER"
      rm -f "/etc/wireguard/conf/$INTERFACE/$USER.conf"

      # Remove the configuration block from /etc/wireguard/$INTERFACE.conf
      sed -i "/# \/etc\/wireguard\/conf\/$INTERFACE\/$USER.conf/,/^$/d" "/etc/wireguard/$INTERFACE.conf"
    else
      echo "User $USER already exists. Use --force to overwrite." >&3
      exit 1
    fi
  fi

  # Create directories and generate keys
  mkdir -p "/etc/wireguard/key/$INTERFACE/$USER"
  wg genpsk | tee "/etc/wireguard/key/$INTERFACE/$USER/client.key" && wg genkey | tee "/etc/wireguard/key/$INTERFACE/$USER/private.pem" | wg pubkey | tee "/etc/wireguard/key/$INTERFACE/$USER/public.pem"
  CLIENT_KEY=$(cat "/etc/wireguard/key/$INTERFACE/$USER/client.key")
  PRIVATE_KEY=$(cat "/etc/wireguard/key/$INTERFACE/$USER/private.pem")
  PUBLIC_KEY=$(cat "/etc/wireguard/key/$INTERFACE/$USER/public.pem")
  WG_PUBLIC_KEY=$(cat "/etc/wireguard/key/$INTERFACE/$INTERFACE/public.pem")

  # Generate user configuration file
  mkdir -p "/etc/wireguard/conf/$INTERFACE"
  cat > "/etc/wireguard/conf/$INTERFACE/$USER.conf" <<EOL
[Interface]
Address = $ADDRESS
DNS = $DNS
MTU = 1420
PrivateKey = $PRIVATE_KEY
EOL

  if [ -n "$LISTEN_PORT" ]; then
    echo "ListenPort = $LISTEN_PORT" >> "/etc/wireguard/conf/$INTERFACE/$USER.conf"
  fi

  cat >> "/etc/wireguard/conf/$INTERFACE/$USER.conf" <<EOL

[Peer]
PublicKey = $WG_PUBLIC_KEY
PresharedKey = $CLIENT_KEY
Endpoint = $(hostname -I | awk '{print $1}'):${LISTEN_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOL

  # Append peer configuration to the main interface configuration file
  cat >> "/etc/wireguard/$INTERFACE.conf" <<EOL

# /etc/wireguard/conf/$INTERFACE/$USER.conf
[Peer]
PublicKey = $PUBLIC_KEY
PresharedKey = $CLIENT_KEY
AllowedIPs = ${ADDRESS%/*}/32
EOL

  sudo wg-quick down "$INTERFACE"
  sudo wg-quick up "$INTERFACE"

  cat "/etc/wireguard/conf/$INTERFACE/$USER.conf" | qrencode -t ANSIUTF8 -m 2 >&3
}

# Function to handle 'rm user' command
remove_user() {
  local PARAM=$3

  # Extract interface and user
  IFS=':' read -r INTERFACE USER <<< "$PARAM"
  if [ -z "$INTERFACE" ] || [ -z "$USER" ]; then
    usage
  fi

  # Check if user exists
  if [ -f "/etc/wireguard/conf/$INTERFACE/$USER.conf" ]; then
    echo "Removing user $USER..." >&3

    # Remove keys and configuration files
    rm -rf "/etc/wireguard/key/$INTERFACE/$USER"
    rm -f "/etc/wireguard/conf/$INTERFACE/$USER.conf"

    # Remove peer configuration from the main interface configuration file
    sed -i "/# \/etc\/wireguard\/conf\/$INTERFACE\/$USER.conf/,/^$/d" "/etc/wireguard/$INTERFACE.conf"

    sudo wg-quick down "$INTERFACE"
    sudo wg-quick up "$INTERFACE"
  else
    echo "User $USER does not exist. Skipping removal." >&3
  fi
}

# Main script logic
if [ "$#" -lt 3 ]; then
  usage
fi

COMMAND=$1
shift

case "$1" in
  create)
    if [ "$#" -lt 4 ]; then
      usage
    fi
    create_user "$@"
    ;;
  rm)
    if [ "$#" -ne 3 ]; then
      usage
    fi
    remove_user "$@"
    ;;
  *)
    usage
    ;;
esac