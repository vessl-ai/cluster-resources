#/bin/bash

########
## Author : kyle@vessl.ai
## Date : 2023-11-07
## Description : Install ngrok as a service with 22 tcp(ssh) and 6443 tls tunneling(k8s)
## Usage : ./install-ngrok.sh <ngrok authtoken> <ngrok tcp endpoint addr> <ngrok tls domain> <region: default jp (optional)>
## Example : ./install-ngrok.sh 1q2w3e4r5t6y7u8i9o0p 1.tcp.ap.ngrok.io:12345 subdomain.ngrok.io jp
########

if [ -z "$1" ]; then
    echo "Please provide a ngrok authtoken"
    echo "Usage: ./install-ngrok.sh <ngrok authtoken> <ngrok addr> <ngrok tls domain> <region: default jp (optional)>"
    echo "You can get your authtoken from https://dashboard.ngrok.com/get-started/your-authtoken"
    exit 1
fi
authtoken=$1

if [ -z "$2" ]; then
    echo "Please provide a ngrok TCP endpoint address for ssh tunneling"
    echo "Usage: ./install-ngrok.sh <ngrok authtoken> <ngrok tcp endpoint addr> <ngrok tls domain> <region: default jp (optional)>"
    echo "- Example (tcp) : 1.tcp.ap.ngrok.io:<port>"
    exit 1
fi
ngrok_tcp_addr=$2

if [ -z "$3" ]; then
    echo "Please provide a ngrok TLS domain address for k8s apiserver endpoint"
    echo "Usage: ./install-ngrok.sh <ngrok authtoken> <ngrok tcp endpoint addr> <ngrok tls domain> <region: default jp (optional)>"
    echo "- Example (http) : subdomain.ngrok.io"
    exit 1
fi
ngrok_tls_addr=$3

if [ -z "$4" ]; then
    region="jp"
else  
    region=$4
fi

if [ -f /usr/local/bin/ngrok ]; then
  echo "ngrok found"
else 
  echo "ngrok not found"
  echo "Install ngrok on https://ngrok.com/download"
  exit 1
fi

cat <<EOF > ngrok.yml
version: "2"
authtoken: $authtoken
tunnels:
  vessl-ssh:
    proto: tcp
    addr: 22
    remote_addr: $ngrok_tcp_addr
  vessl-k8s:
    proto: tls
    addr: 6443
    domain: $ngrok_tls_addr
EOF

sudo mkdir -p /opt/ngrok
sudo cp ngrok.yml /opt/ngrok/ngrok.yml

cat <<EOF > ngrok.service
[Unit]
Description=ngrok
After=network.target


[Service]
ExecStart=/usr/local/bin/ngrok start --all --config /opt/ngrok/ngrok.yml --region $region
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
IgnoreSIGPIPE=true
Restart=always
RestartSec=3
Type=simple

[Install]
WantedBy=multi-user.target
EOF

sudo cp -f ngrok.service /etc/systemd/system/ngrok.service

sudo systemctl stop ngrok.service
sudo systemctl daemon-reload
sudo systemctl enable ngrok.service
sudo systemctl start ngrok.service
sudo systemctl status ngrok.service
