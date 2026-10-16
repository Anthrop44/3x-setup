#!/bin/bash
# The only first-party Bash code: install Nu before running any deployment logic
set -euo pipefail
test "$(id -u)" -eq 0
cd "$(dirname "$0")"
mkdir -p log
exec >>log/bootstrap.log 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y sudo curl ca-certificates gnupg
curl -fsSL https://apt.fury.io/nushell/gpg.key | sudo gpg --batch --yes --dearmor -o /etc/apt/trusted.gpg.d/fury-nushell.gpg
echo "deb https://apt.fury.io/nushell/ /" | sudo tee /etc/apt/sources.list.d/fury.list
sudo apt update
sudo apt install -y nushell
exec nu --no-config-file ./main.nu deploy "$@"
