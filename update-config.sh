echo "Restoring personal config from Git..."

# 1. Clone your personal config repo to a temporary folder
git clone https://github.com/HelpMehh/my-caelestia-config.git /tmp/my-config

# 2. Copy your custom files directly into the active Caelestia directory
cp -a /tmp/my-config/. "$HOME/.config/caelestia/"

# 3. Clean up
rm -rf /tmp/my-config

echo "Personal config restored successfully!"
