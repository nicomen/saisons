#!/usr/bin/env sh
set -e

SCRIPT_URL="https://raw.githubusercontent.com/nicomen/saisons/main/saisons"
INSTALL_DIR=""

# Find a writable directory in PATH
for dir in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
    if [ -d "$dir" ] && [ -w "$dir" ]; then
        INSTALL_DIR="$dir"
        break
    fi
done

# Create ~/.local/bin if nothing else found
if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
    echo "Created $INSTALL_DIR — make sure it is in your PATH."
    echo "  Add this to your ~/.bashrc or ~/.zshrc:"
    echo '  export PATH="$HOME/.local/bin:$PATH"'
fi

# Check for Perl
if ! command -v perl >/dev/null 2>&1; then
    echo "Error: Perl is not installed."
    echo ""
    echo "Install it with your package manager:"
    echo "  Debian/Ubuntu:  sudo apt install perl"
    echo "  Fedora/RHEL:    sudo dnf install perl"
    echo "  macOS:          brew install perl   (or use the system Perl)"
    echo "  Arch:           sudo pacman -S perl"
    exit 1
fi

# Download the fatpacked script
DEST="$INSTALL_DIR/saisons"
echo "Installing saisons to $DEST ..."
curl -fsSL "$SCRIPT_URL" -o "$DEST"
chmod +x "$DEST"

echo "Done. Run: saisons"
