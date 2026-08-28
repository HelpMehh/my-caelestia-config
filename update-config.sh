echo "Restoring personal config from Git..."

# Clone your personal config repo using the SSH link
git clone git@github.com:HelpMehh/my-caelestia-config.git /tmp/my-config

# Copy your custom files directly into the active Caelestia directory
cp -a /tmp/my-config/. "$HOME/.config/caelestia/"

# Clean up
rm -rf /tmp/my-config

echo "Personal config restored successfully!"
