#!/bin/bash

clear

exec 3>&1

exec >> setup.log 2>&1

echo "Loading..." >&3

rm -f setup.log

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

e_color() {
    local color="$1"
    shift
    echo -e "${color}$@${NC}" >&3
}

e_print() {
    local text="$1"
    echo -e "> ${text}" >&3
}

e_read() {
    local prompt="$1"
    local default="$2"
    local response

    read -p "> ${prompt}" response >&3
    response=${response:-$default}
    
    echo "$response"
}

# for arg in "$@"; do
#     case $arg in
#         --gitlab-runner-token=*)
#             GITLAB_RUNNER_TOKEN="${arg#*=}"
#         ;;
#     esac
# done

apt-get update
apt-get install figlet -y
clear >&3
echo -e "\n"
figlet DEcho >&3

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="$NAME $VERSION_ID"
elif [ -f /etc/redhat-release ]; then
    OS_NAME=$(cat /etc/redhat-release)
else
    OS_NAME="Unknown"
fi

e_color "$YELLOW" "\n[Server]"
e_print "OS: $OS_NAME"
e_print "CPU: $(lscpu | awk -F: '/Model name:/ {print $2}' | xargs) ($(lscpu | awk -F: '/^Core\(s\) per socket:/ {print $2}' | xargs) Core, $(( $(lscpu | awk -F: '/^Core\(s\) per socket:/ {print $2}' | xargs) * $(lscpu | awk -F: '/^Socket\(s\):/ {print $2}' | xargs) * $(lscpu | awk -F: '/^Thread\(s\) per core:/ {print $2}' | xargs) )) Thread)"
e_print "Memory: $(free -h | awk '/^Mem:/ {print $2}')"
e_print "Disk: $(df -h --total | awk '/^total/ {print $2}')"

e_color "$YELLOW" "\n[Setup]"
GITLAB_RUNNER_RESPONSE=$(e_read "do you want to install gitlab runner? [Y/n]:" "y")
CASAOS_RESPONSE=$(e_read "do you want to install casaos? [Y/n]:" "y")

if [[ "$var_a" == "y" || "$var_b" == "y" ]]; then
    DOCKER_RESPONSE=$(e_read "do you want to install docker? [Y/n]:" "y")
else
    DOCKER_RESPONSE="y"
fi

WIREGUARD_RESPONSE=$(e_read "do you want to install wireguard? [Y/n]:" "y")
CLOUD_PANEL_RESPONSE=$(e_read "do you want to install the cloud panel? [Y/n]:" "y")
MAIL_COW_RESPONSE=$(e_read "do you want to install mail cow? [Y/n]:" "y")

e_color "$YELLOW" "\n[Package]"
e_print "check for package updates"
apt-get update
e_print "updating the package"
apt-get upgrade -y
e_print "installation of required packages"
apt-get install sudo expect net-tools iptables htop ncdu jq ca-certificates curl -y
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
apt-get install speedtest -y

e_color "$YELLOW" "\n[Network]"
e_print "running network speed tests"
expect << EOF
spawn speedtest
expect { -re "Do you accept the license.*" { send "yes\r"; exp_continue } }
EOF
result=$(speedtest --format=json)
echo "$result" | jq -r '
"> network tester server location: \(.server.name) \(.server.location) \(.server.country) (\(.server.ip))
> network service provider: \(.isp) (\(.interface.externalIp))
> download network speed: \(
  (.download.bandwidth / 1024 / 1024) | 
  if . < 0.01 then 0.00 else (. | tonumber | (. * 100 | floor / 100)) end
) MB/s (\(
  .download.latency.iqm | 
  if . < 0.01 then 0.00 else (. | tonumber | (. * 100 | floor / 100)) end
) ms)
> upload network speed: \(
  (.upload.bandwidth / 1024 / 1024) | 
  if . < 0.01 then 0.00 else (. | tonumber | (. * 100 | floor / 100)) end
) MB/s (\(
  .upload.latency.iqm | 
  if . < 0.01 then 0.00 else (. | tonumber | (. * 100 | floor / 100)) end
) ms)"
' >&3

e_color "$YELLOW" "\n[Docker]"
e_print "check the previous docker installation"
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do sudo apt-get remove $pkg; done
e_print "preparing for docker installation"
apt-get update
e_print "running a docker installation"
apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
e_print "cleaning up the docker configuration"
expect << EOF
spawn docker image prune
expect {
    -re ".*\[y/N\]" { send "Y\r"; exp_continue }
}
spawn docker network prune
expect {
    -re ".*\[y/N\]" { send "Y\r"; exp_continue }
}
EOF

if [ ! -z "$GITLAB_RUNNER_TOKEN" ]; then
    e_color "$YELLOW" "\n[GitLab Runner]"
    e_print "Download the binary for your system"
    if [ ! -f "/usr/local/bin/gitlab-runner" ]; then
        sudo curl -L --output /usr/local/bin/gitlab-runner https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-linux-amd64
    fi
    e_print "give it permission to execute"
    sudo chmod +x /usr/local/bin/gitlab-runner
    e_print "create a gitlab runner user"
    if ! id "gitlab-runner"; then
        sudo useradd --comment 'GitLab Runner' --create-home gitlab-runner --shell /bin/bash
    fi
    e_print "install and run as a service"
    if ! which gitlab-runner; then
        sudo gitlab-runner install --user=gitlab-runner --working-directory=/home/gitlab-runner
    fi
    sudo gitlab-runner start
    e_print "register the runner"
    if [ ! -f "/etc/gitlab-runner/config.toml" ]; then 
        expect << EOF
        spawn gitlab-runner register --url https://gitlab.com --token $GITLAB_RUNNER_TOKEN
        expect {
            -re ".*Enter the GitLab instance URL.*" { send "\r"; exp_continue }
        }
        expect {
            -re ".*Enter a name for the runner.*" { send "\r"; exp_continue }
        }
        expect {
            -re ".*Enter an executor.*" { send "docker\r"; exp_continue }
        }
        expect {
            -re ".*Enter the default Docker image.*" { send "alpine\r"; exp_continue }
        }
EOF
    sed -i 's/^concurrent = .*/concurrent = 5/' /etc/gitlab-runner/config.toml
    sed -i '/executor = "docker"/a \  environment = [\n    "DOCKER_HOST=tcp://docker:2375",\n    "DOCKER_TLS_CERTDIR=",\n    "DOCKER_DRIVER=overlay2"\n  ]' /etc/gitlab-runner/config.toml
    sed -i 's/privileged = false/privileged = true/' /etc/gitlab-runner/config.toml
    fi
fi

e_color "$YELLOW" "\n[CasaOS]"
e_print "processing casaos installation"
if ! which casaos; then
    curl -fsSL https://get.casaos.io | sudo bash
fi
e_print "casaos access url: $(hostname -I | awk '{print $1}'):$(grep '^port=' /etc/casaos/gateway.ini | awk -F'=' '{print $2}')"
e_print "casaos installation has been completed"

e_color "$YELLOW" "\n[WireGuard]"
e_color "$YELLOW" "\n[CloudPanel]"
e_color "$YELLOW" "\n[mailcow]"

echo -e "\n" >&3