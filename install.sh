#!/bin/bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

TRANSCRIPTOR_DIR="$HOME/.transcriptor"
BIN_DIR="$TRANSCRIPTOR_DIR/bin"
MODELS_DIR="$BIN_DIR/models"
WHISPER_DIR="$BIN_DIR/whisper-cpp"

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Transcriptor Installer v1.0        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo -e "${RED}Error: This script only works on macOS${NC}"
    exit 1
fi

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    echo -e "${YELLOW}Homebrew not found. Installing...${NC}"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Check for Bun
if ! command -v bun &> /dev/null; then
    echo -e "${YELLOW}Bun not found. Installing...${NC}"
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
fi

# Check for ffmpeg
if ! command -v ffmpeg &> /dev/null; then
    echo -e "${YELLOW}ffmpeg not found. Installing...${NC}"
    brew install ffmpeg
fi

# Create directories
echo -e "${BLUE}Creating directories...${NC}"
mkdir -p "$BIN_DIR"
mkdir -p "$MODELS_DIR"
mkdir -p "$HOME/transcripts"

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Build audio capture binary
echo -e "${BLUE}Building audio capture binary...${NC}"
cd "$SCRIPT_DIR/audio-capture"
swift build -c release
cp .build/release/transcriptor-audio "$BIN_DIR/"
echo -e "${GREEN}✓ Audio capture binary built${NC}"

# Build menu bar indicator
echo -e "${BLUE}Building menu bar indicator...${NC}"
cd "$SCRIPT_DIR/indicator"
swift build -c release
cp .build/release/transcriptor-indicator "$BIN_DIR/"
echo -e "${GREEN}✓ Menu bar indicator built${NC}"

# Clone and build whisper.cpp
if [ ! -d "$WHISPER_DIR" ]; then
    echo -e "${BLUE}Cloning whisper.cpp...${NC}"
    git clone https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR"
fi

echo -e "${BLUE}Building whisper.cpp...${NC}"
cd "$WHISPER_DIR"
git pull
make clean
make -j

echo -e "${GREEN}✓ whisper.cpp built${NC}"

# Download Whisper model
MODEL_NAME="large-v3-turbo"
MODEL_FILE="$MODELS_DIR/ggml-${MODEL_NAME}.bin"

if [ ! -f "$MODEL_FILE" ]; then
    echo -e "${BLUE}Downloading Whisper ${MODEL_NAME} model (~1.5GB)...${NC}"
    cd "$WHISPER_DIR"
    bash ./models/download-ggml-model.sh "$MODEL_NAME"
    mv "models/ggml-${MODEL_NAME}.bin" "$MODEL_FILE"
    echo -e "${GREEN}✓ Model downloaded${NC}"
else
    echo -e "${GREEN}✓ Model already exists${NC}"
fi

# Install CLI
echo -e "${BLUE}Installing Transcriptor CLI...${NC}"
cd "$SCRIPT_DIR/cli"
bun install
bun link

# Check if bun link worked, otherwise add to PATH manually
if ! command -v transcriptor &> /dev/null; then
    echo -e "${YELLOW}Adding transcriptor to PATH...${NC}"
    
    # Create a wrapper script
    cat > "$BIN_DIR/transcriptor" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CLI_DIR="$(dirname "$SCRIPT_DIR")"
cd "$CLI_DIR/../transcriptor/cli" 2>/dev/null || cd "$(dirname "$(readlink -f "$0")")/../cli"
exec bun run src/index.ts "$@"
EOF
    chmod +x "$BIN_DIR/transcriptor"
    
    # Add to PATH in shell config
    SHELL_CONFIG=""
    if [ -f "$HOME/.zshrc" ]; then
        SHELL_CONFIG="$HOME/.zshrc"
    elif [ -f "$HOME/.bashrc" ]; then
        SHELL_CONFIG="$HOME/.bashrc"
    fi
    
    if [ -n "$SHELL_CONFIG" ]; then
        if ! grep -q "\.transcriptor/bin" "$SHELL_CONFIG"; then
            echo "" >> "$SHELL_CONFIG"
            echo "# Transcriptor" >> "$SHELL_CONFIG"
            echo 'export PATH="$HOME/.transcriptor/bin:$PATH"' >> "$SHELL_CONFIG"
            echo -e "${YELLOW}Added ~/.transcriptor/bin to PATH in $SHELL_CONFIG${NC}"
            echo -e "${YELLOW}Run: source $SHELL_CONFIG${NC}"
        fi
    fi
fi

echo -e "${GREEN}✓ CLI installed${NC}"

# Grant Screen Recording permission reminder
echo ""
echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  IMPORTANT: Grant Screen Recording Permission              ║${NC}"
echo -e "${YELLOW}╠════════════════════════════════════════════════════════════╣${NC}"
echo -e "${YELLOW}║  1. Open System Settings → Privacy & Security              ║${NC}"
echo -e "${YELLOW}║  2. Click Screen Recording                                 ║${NC}"
echo -e "${YELLOW}║  3. Enable Terminal (or your terminal app)                 ║${NC}"
echo -e "${YELLOW}║  4. Restart Terminal                                       ║${NC}"
echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Raycast extension info
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Raycast Extension                                         ║${NC}"
echo -e "${BLUE}╠════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║  To install the Raycast extension:                         ║${NC}"
echo -e "${BLUE}║                                                            ║${NC}"
echo -e "${BLUE}║  cd $SCRIPT_DIR/raycast-extension${NC}"
echo -e "${BLUE}║  npm install                                               ║${NC}"
echo -e "${BLUE}║  npm run dev                                               ║${NC}"
echo -e "${BLUE}║                                                            ║${NC}"
echo -e "${BLUE}║  Or import it in Raycast via Extensions → Import           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Run doctor
echo -e "${BLUE}Running diagnostics...${NC}"
echo ""
"$BIN_DIR/transcriptor" doctor 2>/dev/null || bun run "$SCRIPT_DIR/cli/src/index.ts" doctor

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Installation Complete! 🎉                                 ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Usage:                                                    ║${NC}"
echo -e "${GREEN}║    transcriptor start \"Meeting Name\"                       ║${NC}"
echo -e "${GREEN}║    transcriptor stop                                       ║${NC}"
echo -e "${GREEN}║    transcriptor list                                       ║${NC}"
echo -e "${GREEN}║    transcriptor --help                                     ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
