#!/usr/bin/env bash
# git-branch.sh - Branch management operations
# Usage: git-branch.sh [name] [options]

set -euo pipefail

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../_lib/common.sh"

# Require git repo
require_git_repo

# Defaults
BRANCH_NAME=""
ACTION=""
INCLUDE_REMOTE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --create) ACTION="create"; shift ;;
        --delete) ACTION="delete"; shift ;;
        --list) ACTION="list"; shift ;;
        --switch) ACTION="switch"; shift ;;
        --remote) INCLUDE_REMOTE=true; shift ;;
        -h|--help)
            echo "Usage: git-branch.sh [name] [--create|--delete|--list|--switch] [--remote]"
            exit 0
            ;;
        -*)
            die_json "Unknown option: $1"
            ;;
        *)
            BRANCH_NAME="$1"
            shift
            ;;
    esac
done

# List branches
list_branches() {
    local current branches_json
    current=$(git_current_branch)
    
    if [[ "$INCLUDE_REMOTE" == true ]]; then
        branches_json=$(git branch -a --format='%(refname:short)' | json_array)
    else
        branches_json=$(git branch --format='%(refname:short)' | json_array)
    fi
    
    echo "{\"status\":\"success\",\"action\":\"list\",\"current\":$(json_str "$current"),\"branches\":$branches_json}"
}

# Create branch
create_branch() {
    local name="$1"
    [[ -z "$name" ]] && die_json "Branch name required"
    
    if git_branch_exists "$name"; then
        die_json "Branch '$name' already exists"
    fi
    
    if git branch "$name" 2>/dev/null; then
        echo "{\"status\":\"success\",\"action\":\"create\",\"branch\":$(json_str "$name")}"
    else
        die_json "Failed to create branch '$name'"
    fi
}

# Delete branch
delete_branch() {
    local name="$1"
    [[ -z "$name" ]] && die_json "Branch name required"
    
    local current
    current=$(git_current_branch)
    [[ "$current" == "$name" ]] && die_json "Cannot delete current branch"
    
    if git branch -d "$name" 2>/dev/null; then
        echo "{\"status\":\"success\",\"action\":\"delete\",\"branch\":$(json_str "$name")}"
    else
        die_json "Branch '$name' not found or not fully merged. Use -D to force delete."
    fi
}

# Switch branch
switch_branch() {
    local name="$1"
    [[ -z "$name" ]] && die_json "Branch name required"
    
    if git checkout "$name" 2>/dev/null; then
        echo "{\"status\":\"success\",\"action\":\"switch\",\"branch\":$(json_str "$name")}"
    else
        die_json "Failed to switch to branch '$name'"
    fi
}

# Execute action
case "$ACTION" in
    list)       list_branches ;;
    create)     create_branch "$BRANCH_NAME" ;;
    delete)     delete_branch "$BRANCH_NAME" ;;
    switch)     switch_branch "$BRANCH_NAME" ;;
    "")
        current=$(git_current_branch)
        echo "{\"status\":\"success\",\"action\":\"current\",\"branch\":$(json_str "$current")}"
        ;;
esac
