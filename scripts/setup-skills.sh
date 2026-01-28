#!/usr/bin/env bash
#
# setup-skills.sh - Setup Agent Skills symlinks for multiple AI tools
#
# This script creates symlinks from various AI agent tools to a shared
# skills repository, enabling skill sharing across Claude Code, Clawdbot,
# Codex, and Antigravity.
#
# Usage:
#   ./setup-skills.sh [--skills-repo PATH]
#
# Options:
#   --skills-repo PATH  Path to skills repository (default: ~/ghq/github.com/it-all-playpark/skills)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default skills repository path
DEFAULT_SKILLS_REPO="${HOME}/ghq/github.com/it-all-playpark/skills"
SKILLS_REPO="${DEFAULT_SKILLS_REPO}"

# Agent configurations: "config_dir:skills_subpath"
# config_dir: The agent's config directory (e.g., ~/.claude)
# skills_subpath: Subdirectory for skills within the config (e.g., "skills" or "antigravity/skills")
AGENT_CONFIGS=(
    "${HOME}/.claude:skills"
    "${HOME}/.clawdbot:skills"
    "${HOME}/.codex:skills"
    "${HOME}/.gemini:antigravity/skills"
)

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_usage() {
    echo "Usage: $0 [--skills-repo PATH]"
    echo ""
    echo "Options:"
    echo "  --skills-repo PATH  Path to skills repository"
    echo "                      Default: ${DEFAULT_SKILLS_REPO}"
    echo ""
    echo "Supported AI Agents:"
    echo "  - Claude Code  (~/.claude/skills)"
    echo "  - Clawdbot     (~/.clawdbot/skills)"
    echo "  - Codex        (~/.codex/skills)"
    echo "  - Antigravity  (~/.gemini/antigravity/skills)"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skills-repo)
                SKILLS_REPO="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

clone_skills_repo_if_needed() {
    if [[ ! -d "${SKILLS_REPO}" ]]; then
        log_info "Skills repository not found. Cloning..."
        local repo_parent
        repo_parent=$(dirname "${SKILLS_REPO}")
        mkdir -p "${repo_parent}"

        if command -v ghq &> /dev/null; then
            log_info "Using ghq to clone repository..."
            ghq get -p it-all-playpark/skills
        else
            log_info "Cloning with git..."
            git clone git@github.com:it-all-playpark/skills.git "${SKILLS_REPO}"
        fi

        if [[ -d "${SKILLS_REPO}" ]]; then
            log_success "Skills repository cloned to ${SKILLS_REPO}"
        else
            log_error "Failed to clone skills repository"
            exit 1
        fi
    else
        log_info "Skills repository already exists at ${SKILLS_REPO}"
    fi
}

setup_symlink() {
    local config_dir="$1"
    local skills_subpath="$2"
    local target_path="${config_dir}/${skills_subpath}"
    local agent_name

    # Extract agent name from config_dir for logging
    agent_name=$(basename "${config_dir}" | sed 's/^\.//')

    log_info "Setting up ${agent_name} skills..."

    # Create parent directories if needed
    local target_parent
    target_parent=$(dirname "${target_path}")
    if [[ ! -d "${target_parent}" ]]; then
        log_info "  Creating directory: ${target_parent}"
        mkdir -p "${target_parent}"
    fi

    # Handle existing symlink or directory
    if [[ -L "${target_path}" ]]; then
        local current_target
        current_target=$(readlink "${target_path}")

        if [[ "${current_target}" == "${SKILLS_REPO}" ]]; then
            log_success "  Symlink already correct: ${target_path} -> ${SKILLS_REPO}"
            return 0
        else
            log_warn "  Removing existing symlink: ${target_path} -> ${current_target}"
            rm "${target_path}"
        fi
    elif [[ -d "${target_path}" ]]; then
        log_warn "  Directory exists at ${target_path}"
        log_warn "  Please manually backup/remove if you want to use shared skills"
        return 1
    elif [[ -e "${target_path}" ]]; then
        log_error "  Unexpected file type at ${target_path}"
        return 1
    fi

    # Create symlink
    ln -s "${SKILLS_REPO}" "${target_path}"
    log_success "  Created symlink: ${target_path} -> ${SKILLS_REPO}"
}

main() {
    parse_args "$@"

    echo ""
    echo "=========================================="
    echo "  Agent Skills Setup"
    echo "=========================================="
    echo ""

    log_info "Skills repository: ${SKILLS_REPO}"
    echo ""

    # Clone repository if needed
    clone_skills_repo_if_needed
    echo ""

    # Verify skills repository has content
    if [[ ! -d "${SKILLS_REPO}/.git" ]]; then
        log_error "Skills repository does not appear to be a git repository"
        exit 1
    fi

    # Setup symlinks for each agent
    local success_count=0
    local total_count=${#AGENT_CONFIGS[@]}

    for config in "${AGENT_CONFIGS[@]}"; do
        local config_dir="${config%%:*}"
        local skills_subpath="${config##*:}"

        if setup_symlink "${config_dir}" "${skills_subpath}"; then
            ((success_count++)) || true
        fi
        echo ""
    done

    # Summary
    echo "=========================================="
    echo "  Setup Complete"
    echo "=========================================="
    echo ""
    log_info "Successfully configured: ${success_count}/${total_count} agents"

    if [[ ${success_count} -lt ${total_count} ]]; then
        log_warn "Some agents require manual intervention"
        exit 1
    fi

    log_success "All agent skills symlinks configured!"
}

main "$@"
