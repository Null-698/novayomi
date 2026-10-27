#!/usr/bin/env bash
# Build the iOS Go XCFramework from the go/ directory.
set -e

# Colors for messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Colored message functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check Go
    if ! command -v go &> /dev/null; then
        log_error "Go is not installed. Please install Go 1.22 or newer."
        exit 1
    fi
    
    GO_VERSION=$(go version | grep -o 'go[0-9]\+\.[0-9]\+' | sed 's/go//')
    log_info "Detected Go version: $GO_VERSION"
    
    # Check if we're in the go directory
    if [ ! -f "go.mod" ]; then
        log_error "go.mod not found. Run this script from the 'go' directory of the Novayomi project."
        exit 1
    fi
}

# Build for iOS
build_ios() {
    log_info "Building for iOS..."
    
    if [[ "$OSTYPE" != "darwin"* ]]; then
        log_error "iOS build is only possible on macOS."
        return 1
    fi
    
    # Check Xcode
    if ! command -v xcodebuild &> /dev/null; then
        log_error "Xcode is not installed."
        return 1
    fi
    
    # Check gomobile
    if ! command -v gomobile &> /dev/null; then
        log_info "Installing gomobile..."
        go install golang.org/x/mobile/cmd/gomobile@latest
        go install golang.org/x/mobile/cmd/gobind@latest
        
        # Add GOPATH/bin to PATH if necessary
        export PATH=$PATH:$(go env GOPATH)/bin
        
        # Initialize gomobile
        log_info "Initializing gomobile..."
        gomobile init -v
    fi
    
    go get -u golang.org/x/mobile
    
    log_info "Building iOS XCFramework..."
    
    mkdir -p ../ios/Frameworks
    
    # Uses same optimizations as Android for anet v0.0.5 compatibility
    gomobile bind -v -tags mobile -target=ios,iossimulator -ldflags="-s -w -checklinkname=0" -trimpath -o ../ios/Frameworks/libmtorrentserver.xcframework ./binding/mobile
    
    log_success "iOS build completed: ../ios/Frameworks/libmtorrentserver.xcframework"
}


# Only iOS is supported.
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "ios" ) ]]; then
    echo "Usage: $0 [ios]" >&2
    exit 1
fi

check_prerequisites
build_ios
