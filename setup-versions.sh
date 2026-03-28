#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2086,SC2155,SC2005,SC2207,SC2016

# Professional Terminal Setup - Version Manager Setup Script
# Configures nvm and pyenv for professional development environment

set -euo pipefail

# Source library utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/env.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

# Source language version management libraries if available
if [[ -f "${SCRIPT_DIR}/lib/nvm.sh" ]]; then
    source "${SCRIPT_DIR}/lib/nvm.sh"
fi

if [[ -f "${SCRIPT_DIR}/lib/gvm.sh" ]]; then
    source "${SCRIPT_DIR}/lib/gvm.sh"
fi

if [[ -f "${SCRIPT_DIR}/lib/rustup.sh" ]]; then
    source "${SCRIPT_DIR}/lib/rustup.sh"
fi

if [[ -f "${SCRIPT_DIR}/lib/jenv.sh" ]]; then
    source "${SCRIPT_DIR}/lib/jenv.sh"
fi

# Default command
DEFAULT_COMMAND="pro-status"

# Usage information
usage() {
    log_info "Usage: $0 [command]"
    log_info "  command: Action to perform (default: $DEFAULT_COMMAND)"
    log_info ""
    log_info "Available commands:"
    log_info "  pro-status    - Show professional status of version managers"
    log_info "  install-node  - Install Node.js version from .nvmrc"
    log_info "  install-python - Install Python version from .python-version"
    log_info "  install-go    - Install Go version from .go-version"
    log_info "  install-rust  - Install Rust version from rust-toolchain"
    log_info "  install-java  - Install Java version from .java-version"
    log_info "  configure-nvm - Configure NVM for silent operation"
    exit 1
}

# Show professional status of version managers
show_pro_status() {
    log_info " Version Managers Professional Status"
    log_info "======================================="
    echo
    
    # Check NVM status
    log_info "🟢 Node Version Manager (NVM):"
    if check_nvm_installed; then
        log_success "   NVM is installed"
        
        # Check current Node version
        if command -v node >/dev/null 2>&1; then
            local current_node
            current_node=$(node --version 2>/dev/null || echo "unknown")
            log_info "   Current Node.js: $current_node"
        else
            log_warn "   Node.js not available"
        fi
        
        # Check .nvmrc version
        if [[ -f ".nvmrc" ]]; then
            local nvmrc_version
            nvmrc_version=$(cat .nvmrc 2>/dev/null || echo "unknown")
            log_info "  📋 Project Node.js: v$nvmrc_version"
            
            # Check if versions match
            if command -v node >/dev/null 2>&1; then
                local current_clean
                current_clean=$(node --version 2>/dev/null | sed 's/^v//' || echo "unknown")
                if [[ "$current_clean" == "$nvmrc_version" ]]; then
                    log_success "   Versions match"
                else
                    log_warn "    Version mismatch - run 'nvm use' or install correct version"
                fi
            fi
        else
            log_warn "   .nvmrc not found"
        fi
        
        # Check NVM_SILENT configuration
        if check_nvm_silent_configured; then
            log_success "   NVM silent mode configured"
        else
            log_warn "    NVM verbose mode (consider running configure-nvm)"
        fi
    else
        log_error "   NVM not installed"
        log_info "   Install with: git clone https://github.com/nvm-sh/nvm.git ~/.nvm && cd ~/.nvm && git checkout v0.39.7"
    fi
    
    echo
    
    # Check pyenv status
    log_info "🐍 Python Version Manager (pyenv):"
    if check_pyenv_installed; then
        log_success "   pyenv is installed"
        
        # Check current Python version
        if command -v python3 >/dev/null 2>&1; then
            local current_python
            current_python=$(python3 --version 2>/dev/null || echo "unknown")
            log_info "   Current Python: $current_python"
        else
            log_warn "   Python3 not available"
        fi
        
        # Check .python-version
        if [[ -f ".python-version" ]]; then
            local python_version
            python_version=$(cat .python-version 2>/dev/null || echo "unknown")
            log_info "  📋 Project Python: $python_version"
            
            # Check if pyenv version is active
            if command -v pyenv >/dev/null 2>&1; then
                local pyenv_version
                pyenv_version=$(pyenv version 2>/dev/null | cut -d' ' -f1 || echo "unknown")
                if [[ "$pyenv_version" == "$python_version" ]]; then
                    log_success "   Versions match"
                else
                    log_warn "    Version mismatch - run 'pyenv install $python_version'"
                fi
            fi
        else
            log_warn "   .python-version not found"
        fi
    else
        log_error "   pyenv not installed"
        log_info "   Install with: git clone https://github.com/pyenv/pyenv.git ~/.pyenv"
    fi
    
    echo
    
    # Check Go status
    log_info " Go Version Manager (gvm/goenv):"
    if command -v goenv >/dev/null 2>&1; then
        log_success "   goenv is installed"
        
        # Check current Go version
        if command -v go >/dev/null 2>&1; then
            local current_go
            current_go=$(go version 2>/dev/null | cut -d' ' -f3 || echo "unknown")
            log_info "   Current Go: $current_go"
        else
            log_warn "   Go not available"
        fi
        
        # Check .go-version
        if [[ -f ".go-version" ]]; then
            local go_version
            go_version=$(cat .go-version 2>/dev/null || echo "unknown")
            log_info "  📋 Project Go: $go_version"
            
            # Check if goenv version is active
            if command -v goenv >/dev/null 2>&1; then
                local goenv_version
                goenv_version=$(goenv version 2>/dev/null | cut -d' ' -f1 || echo "unknown")
                if [[ "$goenv_version" == "$go_version" ]]; then
                    log_success "   Versions match"
                else
                    log_warn "    Version mismatch - run 'goenv install $go_version'"
                fi
            fi
        else
            log_warn "   .go-version not found"
        fi
    elif [[ -f "${SCRIPT_DIR}/lib/gvm.sh" ]]; then
        log_warn "    goenv not installed (run setup to install)"
    else
        log_warn "    Go support not available"
    fi
    
    echo
    
    # Check Rust status
    log_info "🦀 Rust Version Manager (rustup):"
    if command -v rustup >/dev/null 2>&1; then
        log_success "   rustup is installed"
        
        # Check current Rust version
        if command -v rustc >/dev/null 2>&1; then
            local current_rust
            current_rust=$(rustc --version 2>/dev/null | cut -d' ' -f2 || echo "unknown")
            log_info "   Current Rust: $current_rust"
        else
            log_warn "   Rust compiler not available"
        fi
        
        # Check rust-toolchain
        if [[ -f "rust-toolchain" ]]; then
            local rust_version
            rust_version=$(cat rust-toolchain 2>/dev/null || echo "unknown")
            log_info "  📋 Project Rust: $rust_version"
            
            # Check if rustup version is active
            if command -v rustup >/dev/null 2>&1; then
                local rustup_version
                rustup_version=$(rustup show active-toolchain 2>/dev/null | head -n1 | cut -d' ' -f1 || echo "unknown")
                if [[ "$rustup_version" == "$rust_version" ]]; then
                    log_success "   Versions match"
                else
                    log_warn "    Version mismatch"
                fi
            fi
        else
            log_warn "   rust-toolchain not found"
        fi
    elif [[ -f "${SCRIPT_DIR}/lib/rustup.sh" ]]; then
        log_warn "    rustup not installed (run setup to install)"
    else
        log_warn "    Rust support not available"
    fi
    
    echo
    
    # Check Java status
    log_info "☕ Java Version Manager (jenv):"
    if command -v jenv >/dev/null 2>&1; then
        log_success "   jenv is installed"
        
        # Check current Java version
        if command -v java >/dev/null 2>&1; then
            local current_java
            current_java=$(java -version 2>&1 | head -n1 | cut -d'"' -f2 || echo "unknown")
            log_info "   Current Java: $current_java"
        else
            log_warn "   Java not available"
        fi
        
        # Check .java-version
        if [[ -f ".java-version" ]]; then
            local java_version
            java_version=$(cat .java-version 2>/dev/null || echo "unknown")
            log_info "  📋 Project Java: $java_version"
            
            # Check if jenv version is active
            if command -v jenv >/dev/null 2>&1; then
                local jenv_version
                jenv_version=$(jenv version 2>/dev/null | cut -d' ' -f1 || echo "unknown")
                if [[ "$jenv_version" == "$java_version" ]]; then
                    log_success "   Versions match"
                else
                    log_warn "    Version mismatch"
                fi
            fi
        else
            log_warn "   .java-version not found"
        fi
    elif [[ -f "${SCRIPT_DIR}/lib/jenv.sh" ]]; then
        log_warn "    jenv not installed (run setup to install)"
    else
        log_warn "    Java support not available"
    fi
    
    echo
}

# Install Node.js version from .nvmrc
install_node_version() {
    log_info " Installing Node.js version from .nvmrc..."
    
    if [[ ! -f ".nvmrc" ]]; then
        log_error ".nvmrc file not found"
        return 1
    fi
    
    if ! check_nvm_installed; then
        log_error "NVM is not installed"
        return 1
    fi
    
    local node_version
    node_version=$(cat .nvmrc)
    log_info "Target Node.js version: v$node_version"
    
    # Source nvm and install
    if source_nvm_if_available; then
        log_info "Installing Node.js v$node_version..."
        if nvm install "$node_version"; then
            log_success "Node.js v$node_version installed successfully"
            if nvm use "$node_version"; then
                log_success "Now using Node.js v$node_version"
            fi
        else
            log_error "Failed to install Node.js v$node_version"
            return 1
        fi
    else
        log_error "Failed to source NVM"
        return 1
    fi
}

# Install Python version from .python-version
install_python_version() {
    log_info "🐍 Installing Python version from .python-version..."
    
    if [[ ! -f ".python-version" ]]; then
        log_error ".python-version file not found"
        return 1
    fi
    
    if ! check_pyenv_installed; then
        log_error "pyenv is not installed"
        return 1
    fi
    
    local python_version
    python_version=$(cat .python-version)
    log_info "Target Python version: $python_version"
    
    # Install Python version
    log_info "Installing Python $python_version..."
    if pyenv install "$python_version"; then
        log_success "Python $python_version installed successfully"
        if pyenv local "$python_version"; then
            log_success "Set local Python version to $python_version"
        fi
    else
        log_error "Failed to install Python $python_version"
        return 1
    fi
}

# Configure NVM for silent operation
configure_nvm_silent() {
    log_info " Configuring NVM for silent operation..."
    
    if ! check_nvm_installed; then
        log_error "NVM is not installed"
        return 1
    fi
    
    local zshrc="$HOME/.zshrc"
    if [[ ! -f "$zshrc" ]]; then
        log_error "$HOME/.zshrc not found"
        return 1
    fi
    
    # Backup .zshrc
    if ! create_backup "$zshrc"; then
        log_error "Failed to backup ~/.zshrc"
        return 1
    fi
    
    # Check if NVM_SILENT is already configured
    if grep -q "export NVM_SILENT" "$zshrc"; then
        log_success "NVM_SILENT already configured"
        return 0
    fi
    
    # Add NVM_SILENT configuration
    log_info "Adding NVM_SILENT configuration to ~/.zshrc..."
    {
        echo ""
        echo "# Professional terminal setup - silence nvm output"
        echo "export NVM_SILENT=true"
    } >> "$zshrc"
    
    log_success "NVM silent mode configured"
    log_info " Restart your terminal or run 'source ~/.zshrc' to apply changes"
}

# Main function
main() {
    local command="${1:-$DEFAULT_COMMAND}"
    
    # Validate command parameter
    case "$command" in
        pro-status)
            ;;
        install-node)
            ;;
        install-python)
            ;;
        install-go)
            ;;
        install-rust)
            ;;
        install-java)
            ;;
        configure-nvm)
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            ;;
    esac
    
    log_info " Version Manager Setup: $command"
    echo
    
    # Execute command
    case "$command" in
        pro-status)
            show_pro_status
            ;;
        install-node)
            install_node_version
            ;;
        install-python)
            install_python_version
            ;;
        configure-nvm)
            configure_nvm_silent
            ;;
        install-go)
            install_go_version
            ;;
        install-rust)
            install_rust_version
            ;;
        install-java)
            install_java_version
            ;;
    esac
    
    exit 0
}

# Install Go version from .go-version
install_go_version() {
    log_info " Installing Go version from .go-version..."
    
    if [[ ! -f ".go-version" ]]; then
        log_error ".go-version file not found"
        return 1
    fi
    
    if ! command -v goenv >/dev/null 2>&1; then
        log_error "goenv is not installed"
        return 1
    fi
    
    local go_version
    go_version=$(cat .go-version)
    log_info "Target Go version: $go_version"
    
    # Install Go version
    log_info "Installing Go $go_version..."
    if goenv install "$go_version"; then
        log_success "Go $go_version installed successfully"
        if goenv local "$go_version"; then
            log_success "Set local Go version to $go_version"
        fi
    else
        log_error "Failed to install Go $go_version"
        return 1
    fi
}

# Install Rust version from rust-toolchain
install_rust_version() {
    log_info "🦀 Installing Rust version from rust-toolchain..."
    
    if [[ ! -f "rust-toolchain" ]]; then
        log_error "rust-toolchain file not found"
        return 1
    fi
    
    if ! command -v rustup >/dev/null 2>&1; then
        log_error "rustup is not installed"
        return 1
    fi
    
    local rust_version
    rust_version=$(cat rust-toolchain)
    log_info "Target Rust version: $rust_version"
    
    # Install Rust version
    log_info "Installing Rust $rust_version..."
    if rustup toolchain install "$rust_version"; then
        log_success "Rust $rust_version installed successfully"
    else
        log_error "Failed to install Rust $rust_version"
        return 1
    fi
}

# Install Java version from .java-version
install_java_version() {
    log_info "☕ Installing Java version from .java-version..."
    
    if [[ ! -f ".java-version" ]]; then
        log_error ".java-version file not found"
        return 1
    fi
    
    if ! command -v jenv >/dev/null 2>&1; then
        log_error "jenv is not installed"
        return 1
    fi
    
    local java_version
    java_version=$(cat .java-version)
    log_info "Target Java version: $java_version"
    
    # Set local Java version
    log_info "Setting Java $java_version..."
    if jenv local "$java_version"; then
        log_success "Set local Java version to $java_version"
    else
        log_error "Failed to set Java $java_version"
        return 1
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
