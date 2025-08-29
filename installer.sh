#!/bin/bash
set -e

echo "=============================================="
echo "   Creating Debian-like VM in Codesandbox     "
echo "=============================================="

# Create the VM root folder
mkdir -p ~/Vm/{bin,etc,usr,var,home,root}
cd ~/Vm

# Install required packages
apt-get update -y
apt-get install -y curl wget sudo unzip git neofetch build-essential \
                   ca-certificates lsb-release gnupg whiptail

# Install Node.js + PM2
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs
npm install -g pm2

# Install Docker
curl -fsSL https://get.docker.com | bash

# Fake systemctl so Pterodactyl installer won’t fail
if [ ! -f /bin/systemctl ]; then
  echo -e '#!/bin/bash\necho "[Fake systemctl] $@"' > /bin/systemctl
  chmod +x /bin/systemctl
fi

# Create fake login script inside Vm
cat > ~/Vm/login.sh <<'EOF'
#!/bin/bash
echo "---------------------------------------"
echo "   Welcome to your Debian VM (Fake)    "
echo "---------------------------------------"

# Ask for username
read -p "Username: " USERNAME
read -s -p "Password: " PASSWORD
echo ""

if [ "$USERNAME" = "root" ] && [ "$PASSWORD" = "root" ]; then
  echo "Login successful! Dropping into VM shell..."
  bash
else
  echo "Login failed!"
  exit 1
fi
EOF

chmod +x ~/Vm/login.sh

echo "=============================================="
echo " Debian-like VM created in ~/Vm/"
echo " Run it with: ~/Vm/login.sh"
echo " (username: root, password: root)"
echo "=============================================="

cat <<'EOF'

----------------------------------------
