#!/bin/bash
set -e

echo "🚀 Updating system..."
apt-get update -y && apt-get upgrade -y

echo "📦 Installing prerequisites..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    systemd systemd-sysv

echo "🐳 Installing Docker CE..."
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "🔧 Enabling Docker service..."
systemctl enable docker
systemctl start docker

echo "✅ Installation complete!"
echo "Docker version: $(docker --version)"
echo "systemd version: $(systemctl --version | head -n 1)"

# Backup any existing systemctl (there shouldn’t be one)
mv /bin/systemctl /bin/systemctl.bak 2>/dev/null || true

# Create a fake systemctl that does nothing (prevents errors)
echo -e '#!/bin/bash\necho "Fake systemctl: $@"' > /bin/systemctl
chmod +x /bin/systemctl
