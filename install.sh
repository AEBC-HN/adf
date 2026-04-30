#!/usr/bin/env bash
# ADF (Agentic Development Framework) — Global Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sotatek-dev/adf/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/sotatek-dev/adf/main/install.sh | bash -s -- --branch dev
#
# What it does:
#   1. Clones ADF to ~/.adf/
#   2. Creates symlinks in ~/.claude/ for skills, agents, rules, hooks, scripts
#   3. Generates ~/.claude/settings.json with ADF hooks
#   4. Generates ~/.claude/CLAUDE.md with base instructions
#   5. Installs skills dependencies (python venv)
#   6. Adds `adf` command to PATH
#
# Safe to re-run (idempotent). Re-running = update.

set -euo pipefail

# ────────────────────────────────────────────────────���─────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────
ADF_REPO="https://github.com/sotatek-dev/adf.git"
ADF_HOME="${ADF_HOME:-$HOME/.adf}"
ADF_BRANCH="main"
CLAUDE_DIR="$HOME/.claude"
BACKUP_DIR="$CLAUDE_DIR/backups/adf-$(date +%Y%m%d-%H%M%S)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Parse args
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --branch)
      [[ -z "${2:-}" ]] && { err "--branch requires a value"; exit 1; }
      ADF_BRANCH="$2"; shift ;;
    --dir)
      [[ -z "${2:-}" ]] && { err "--dir requires a value"; exit 1; }
      ADF_HOME="$2"; shift ;;
    --uninstall) UNINSTALL=true ;;
    *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
  esac
  shift
done

# Resolve to absolute path and validate (prevent path injection)
ADF_HOME="$(cd "$(dirname "$ADF_HOME")" 2>/dev/null && pwd)/$(basename "$ADF_HOME")" || {
  err "Invalid ADF_HOME path: $ADF_HOME"; exit 1;
}

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
info()  { echo -e "${BLUE}▸${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}!${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }
step()  { echo -e "\n${BOLD}[$1/$TOTAL_STEPS] $2${NC}"; }

check_command() {
  command -v "$1" &>/dev/null
}

# Portable readlink (macOS readlink lacks -f)
resolve_link() {
  local target="$1"
  if check_command realpath; then
    realpath "$target" 2>/dev/null || readlink "$target"
  elif check_command greadlink; then
    greadlink -f "$target" 2>/dev/null || readlink "$target"
  else
    readlink "$target"
  fi
}

create_symlink() {
  local src="$1"
  local dst="$2"
  local name
  name=$(basename "$dst")

  # Skip if already correct symlink
  if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
    ok "$name (already linked)"
    return
  fi

  # Backup if exists and is not a symlink to ADF
  if [[ -e "$dst" ]] || [[ -L "$dst" ]]; then
    mkdir -p "$BACKUP_DIR"
    if [[ -L "$dst" ]]; then
      # Save symlink target info then remove
      echo "$(readlink "$dst")" > "$BACKUP_DIR/${name}.symlink-target"
      rm "$dst"
    else
      mv "$dst" "$BACKUP_DIR/$name"
      warn "$name backed up to $BACKUP_DIR/"
    fi
  fi

  ln -s "$src" "$dst"
  ok "$name → $src"
}

# ──────────────────────────────────────────────────────────────────────────────
# Uninstall
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${UNINSTALL:-false}" == "true" ]]; then
  echo -e "${BOLD}Uninstalling ADF...${NC}\n"

  # Remove symlinks (only if pointing to ADF)
  for item in skills agents rules hooks scripts statusline.cjs statusline.sh statusline.ps1; do
    target="$CLAUDE_DIR/$item"
    if [[ -L "$target" ]] && [[ "$(readlink "$target")" == *".adf/"* ]]; then
      rm "$target"
      ok "Removed $item symlink"
    fi
  done

  # Remove ADF hooks from settings.json
  if [[ -f "$CLAUDE_DIR/settings.json" ]] && check_command node; then
    ADF_SETTINGS_PATH="$CLAUDE_DIR/settings.json" node -e '
      const fs = require("fs");
      const p = process.env.ADF_SETTINGS_PATH;
      const s = JSON.parse(fs.readFileSync(p, "utf8"));
      if (s.hooks) {
        for (const [event, matchers] of Object.entries(s.hooks)) {
          s.hooks[event] = matchers.map(m => ({
            ...m,
            hooks: (m.hooks || []).filter(h => !h._adf)
          })).filter(m => m.hooks && m.hooks.length > 0);
          if (s.hooks[event].length === 0) delete s.hooks[event];
        }
      }
      if (s._adf_version) delete s._adf_version;
      if (s.statusLine && s.statusLine._adf) delete s.statusLine;
      fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
    '
    ok "Removed ADF hooks from settings.json"
  fi

  # Remove CLAUDE.md if ADF-generated
  if [[ -f "$CLAUDE_DIR/CLAUDE.md" ]] && head -1 "$CLAUDE_DIR/CLAUDE.md" | grep -q "ADF"; then
    rm "$CLAUDE_DIR/CLAUDE.md"
    ok "Removed global CLAUDE.md"
  fi

  # Remove PATH entry (only the exact ADF block)
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$rc" ]] && grep -q '# ADF (Agentic Development Framework)' "$rc"; then
      sed -i.bak '/# ADF (Agentic Development Framework)/,+1d' "$rc"
      rm -f "${rc}.bak"
      ok "Removed PATH from $(basename "$rc")"
    fi
  done

  echo -e "\n${GREEN}ADF uninstalled.${NC}"
  echo "ADF repo still at $ADF_HOME (delete manually if wanted)."
  exit 0
fi

# ─────────────────────────────────���────────────────────────────────────────────
# Install
# ──────────────────────────────────────────────────────────────────────────────
TOTAL_STEPS=7

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     Sotatek — Agentic Development Framework      ║${NC}"
echo -e "${BOLD}║                Global Installer                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ── Step 1: Prerequisites ───────────────────────────��────────────────────────
step 1 "Checking prerequisites"

if ! check_command git; then
  err "git is required. Install it first."
  exit 1
fi
ok "git"

if ! check_command node; then
  err "Node.js is required (for hooks). Install it first."
  exit 1
fi
ok "node $(node -v)"

if check_command python3; then
  ok "python3 $(python3 --version 2>&1 | awk '{print $2}')"
else
  warn "python3 not found — some skills will be limited"
fi

# ── Step 2: Clone / Update ADF ───────────────────────────────────────────────
step 2 "Installing ADF to $ADF_HOME"

if [[ -d "$ADF_HOME/.git" ]]; then
  info "ADF already installed, updating..."
  cd "$ADF_HOME"
  git fetch origin "$ADF_BRANCH" --quiet
  git checkout "$ADF_BRANCH" --quiet 2>/dev/null || warn "Could not checkout $ADF_BRANCH, staying on current branch"
  git pull origin "$ADF_BRANCH" --quiet
  ok "Updated to latest"
else
  if [[ -d "$ADF_HOME" ]]; then
    warn "$ADF_HOME exists but is not a git repo, backing up..."
    mv "$ADF_HOME" "${ADF_HOME}.bak.$(date +%s)"
  fi
  git clone --branch "$ADF_BRANCH" --depth 1 "$ADF_REPO" "$ADF_HOME" --quiet
  ok "Cloned to $ADF_HOME"
fi

# ── Step 3: Create symlinks ──────────────────────────────────────────────────
step 3 "Linking ADF to ~/.claude/"

mkdir -p "$CLAUDE_DIR"

# Directory symlinks
create_symlink "$ADF_HOME/.claude/skills"   "$CLAUDE_DIR/skills"
create_symlink "$ADF_HOME/.claude/agents"   "$CLAUDE_DIR/agents"
create_symlink "$ADF_HOME/.claude/rules"    "$CLAUDE_DIR/rules"
create_symlink "$ADF_HOME/.claude/hooks"    "$CLAUDE_DIR/hooks"
create_symlink "$ADF_HOME/.claude/scripts"  "$CLAUDE_DIR/scripts"

# File symlinks
create_symlink "$ADF_HOME/.claude/statusline.cjs" "$CLAUDE_DIR/statusline.cjs"
create_symlink "$ADF_HOME/.claude/statusline.sh"  "$CLAUDE_DIR/statusline.sh"

# ── Step 4: Generate global settings.json ─────────────────────────────────────
step 4 "Configuring global hooks"

# Read ADF version safely
ADF_VERSION="$(ADF_META="$ADF_HOME/.claude/metadata.json" node -pe 'JSON.parse(require("fs").readFileSync(process.env.ADF_META,"utf8")).version' 2>/dev/null || echo "0.0.1")"

# Generate settings using Node — paths passed via env vars (no shell injection)
ADF_SETTINGS_PATH="$CLAUDE_DIR/settings.json" \
ADF_VERSION="$ADF_VERSION" \
node -e '
const fs = require("fs");
const settingsPath = process.env.ADF_SETTINGS_PATH;
const adfVersion = process.env.ADF_VERSION;

// Load existing settings
let settings = {};
try { settings = JSON.parse(fs.readFileSync(settingsPath, "utf8")); } catch {}

// Remove old ADF hooks first (clean slate for ADF entries)
if (settings.hooks) {
  for (const [event, matchers] of Object.entries(settings.hooks)) {
    settings.hooks[event] = matchers.map(m => ({
      ...m,
      hooks: (m.hooks || []).filter(h => !h._adf)
    })).filter(m => m.hooks && m.hooks.length > 0);
    if (settings.hooks[event].length === 0) delete settings.hooks[event];
  }
}

// ADF hooks definition — $HOME is expanded by the shell at runtime, not by Node
const H = "$HOME/.claude/hooks";
const adfHooks = {
  SessionStart: [{
    matcher: "startup|resume|clear|compact",
    hooks: [{ type: "command", command: "node " + H + "/session-init.cjs", _adf: true }]
  }],
  SubagentStart: [{
    matcher: "*",
    hooks: [
      { type: "command", command: "node " + H + "/subagent-init.cjs", _adf: true },
      { type: "command", command: "node " + H + "/team-context-inject.cjs", _adf: true }
    ]
  }],
  SubagentStop: [{
    matcher: "Plan",
    hooks: [{ type: "command", command: "node " + H + "/cook-after-plan-reminder.cjs", _adf: true }]
  }],
  UserPromptSubmit: [{
    hooks: [
      { type: "command", command: "node " + H + "/dev-rules-reminder.cjs", _adf: true },
      { type: "command", command: "node " + H + "/usage-context-awareness.cjs", timeout: 30, _adf: true }
    ]
  }],
  PreToolUse: [
    {
      matcher: "Write",
      hooks: [{ type: "command", command: "node " + H + "/descriptive-name.cjs", _adf: true }]
    },
    {
      matcher: "Bash|Glob|Grep|Read|Edit|Write",
      hooks: [
        { type: "command", command: "node " + H + "/scout-block.cjs", _adf: true },
        { type: "command", command: "node " + H + "/privacy-block.cjs", _adf: true }
      ]
    }
  ],
  PostToolUse: [
    {
      matcher: "Edit|Write|MultiEdit",
      hooks: [{ type: "command", command: "node " + H + "/post-edit-simplify-reminder.cjs", _adf: true }]
    },
    {
      matcher: "Bash|Edit|Write|MultiEdit|NotebookEdit",
      hooks: [
        { type: "command", command: "node " + H + "/usage-context-awareness.cjs", timeout: 10, _adf: true }
      ]
    }
  ]
};

// Merge: append ADF hooks to existing
if (!settings.hooks) settings.hooks = {};
for (const [event, matchers] of Object.entries(adfHooks)) {
  if (!settings.hooks[event]) settings.hooks[event] = [];
  settings.hooks[event].push(...matchers);
}

// ADF-managed settings
settings.includeCoAuthoredBy = settings.includeCoAuthoredBy ?? false;
settings.statusLine = {
  type: "command",
  command: "node $HOME/.claude/statusline.cjs",
  padding: 0,
  _adf: true
};
settings._adf_version = adfVersion;

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
'
ok "Global settings.json updated"

# ── Step 5: Generate global CLAUDE.md ─────────────────────────────────────────
step 5 "Generating global CLAUDE.md"

cat > "$CLAUDE_DIR/CLAUDE.md" << 'CLAUDE_EOF'
# ADF — Agentic Development Framework

This file provides global guidance to Claude Code. Project-level CLAUDE.md overrides this.

## Role & Responsibilities

Analyze user requirements, delegate tasks to appropriate sub-agents, and ensure cohesive delivery of features that meet specifications and architectural standards.

## Workflows

Rules in `~/.claude/rules/` are auto-loaded. Key workflows:
- Primary workflow: development-rules.md, primary-workflow.md
- Orchestration: orchestration-protocol.md
- Documentation: documentation-management.md

**IMPORTANT:** Analyze the skills catalog and activate the skills needed for the task.
**IMPORTANT:** Follow strictly the development rules.

## Hook Response Protocol

### Privacy Block Hook (`@@PRIVACY_PROMPT@@`)

When a tool call is blocked by the privacy-block hook, the output contains a JSON marker between `@@PRIVACY_PROMPT_START@@` and `@@PRIVACY_PROMPT_END@@`. **You MUST use the `AskUserQuestion` tool** to get proper user approval.

**Required Flow:**
1. Parse the JSON from the hook output
2. Use `AskUserQuestion` with the question data from the JSON
3. Based on user's selection:
   - **"Yes, approve access"** → Use `bash cat "filepath"` to read the file
   - **"No, skip this file"** → Continue without accessing the file

## Python Scripts (Skills)

When running Python scripts from skills, use the venv Python interpreter:
- **Linux/macOS:** `~/.claude/skills/.venv/bin/python3 scripts/xxx.py`
- **Windows:** Not supported in global mode

## Principles

- **YAGNI** — You Aren't Gonna Need It
- **KISS** — Keep It Simple, Stupid
- **DRY** — Don't Repeat Yourself

## Modularization

- If a code file exceeds 200 lines, consider modularizing it
- Check existing modules before creating new ones
- Use kebab-case naming with descriptive names
- Write descriptive code comments

## Documentation

When a project has a `./docs` folder, keep it updated. Use `/docs init` to generate baseline docs for new projects.
CLAUDE_EOF
ok "Global CLAUDE.md generated"

# ── Step 6: PATH + CLI ───────────────────────────────────────────────────────
step 6 "Setting up CLI"

# Create bin directory and adf command
mkdir -p "$ADF_HOME/bin"
cat > "$ADF_HOME/bin/adf" << 'CLI_EOF'
#!/usr/bin/env bash
# ADF CLI — lightweight wrapper
set -euo pipefail

ADF_HOME="${ADF_HOME:-$HOME/.adf}"
CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in
  init)
    # Scaffold project context in current directory
    MODE="${1:-default}"

    # Create .claude/config/ with default adf-config.json
    if [[ ! -f ".claude/config/adf-config.json" ]]; then
      mkdir -p .claude/config
      cat > .claude/config/adf-config.json << 'JSON_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "paths": {
    "docs": "docs",
    "plans": "plans"
  },
  "plan": {
    "namingFormat": "{date}-{issue}-{slug}",
    "dateFormat": "YYMMDD-HHmm"
  },
  "locale": {
    "thinkingLanguage": null,
    "responseLanguage": null
  }
}
JSON_EOF
      echo -e "\033[0;32m✓\033[0m .claude/config/adf-config.json"
    else
      echo -e "\033[0;33m!\033[0m .claude/config/adf-config.json (already exists)"
    fi

    # Create CLAUDE.md if not exists
    if [[ ! -f "CLAUDE.md" ]]; then
      PROJECT_NAME=$(basename "$(pwd)")
      cat > CLAUDE.md << MD_EOF
# $PROJECT_NAME

## Project Overview

<!-- Describe your project here -->

## Tech Stack

<!-- List your technologies -->

## Important Notes

<!-- Project-specific instructions for Claude Code -->

## Documentation

- Read \`./README.md\` for project context
- Docs: \`./docs/\` (generate with \`/docs init\`)
MD_EOF
      echo -e "\033[0;32m✓\033[0m CLAUDE.md"
    else
      echo -e "\033[0;33m!\033[0m CLAUDE.md (already exists)"
    fi

    # Create directories
    mkdir -p docs plans
    echo -e "\033[0;32m✓\033[0m docs/ and plans/ directories"

    # Add to .gitignore if git repo
    if [[ -d ".git" ]] && [[ -f ".gitignore" ]]; then
      if ! grep -q "settings.local.json" .gitignore 2>/dev/null; then
        echo -e "\n# ADF local settings\n.claude/settings.local.json" >> .gitignore
        echo -e "\033[0;32m✓\033[0m Updated .gitignore"
      fi
    elif [[ -d ".git" ]]; then
      echo -e "# ADF local settings\n.claude/settings.local.json" > .gitignore
      echo -e "\033[0;32m✓\033[0m Created .gitignore"
    fi

    echo -e "\n\033[1mProject initialized.\033[0m Run 'claude' to start."
    ;;

  update)
    echo "Updating ADF..."
    cd "$ADF_HOME"
    git pull origin "$(git branch --show-current)" --quiet
    echo -e "\033[0;32m✓\033[0m ADF updated to $(git log -1 --format='%h %s')"
    ;;

  doctor)
    echo -e "\033[1mADF Health Check\033[0m\n"
    ISSUES=0

    # Check ADF repo
    if [[ -d "$ADF_HOME/.git" ]]; then
      echo -e "\033[0;32m✓\033[0m ADF repo: $ADF_HOME"
    else
      echo -e "\033[0;31m✗\033[0m ADF repo not found at $ADF_HOME"
      ((ISSUES++))
    fi

    # Check symlinks
    for item in skills agents rules hooks scripts statusline.cjs statusline.sh; do
      target="$HOME/.claude/$item"
      if [[ -L "$target" ]]; then
        if [[ -e "$target" ]]; then
          echo -e "\033[0;32m✓\033[0m $item → $(readlink "$target")"
        else
          echo -e "\033[0;31m✗\033[0m $item → $(readlink "$target") (broken)"
          ((ISSUES++))
        fi
      else
        echo -e "\033[0;31m✗\033[0m $item (not symlinked)"
        ((ISSUES++))
      fi
    done

    # Check settings.json
    if [[ -f "$HOME/.claude/settings.json" ]] && grep -q "_adf" "$HOME/.claude/settings.json"; then
      echo -e "\033[0;32m✓\033[0m settings.json has ADF hooks"
    else
      echo -e "\033[0;31m✗\033[0m settings.json missing ADF hooks"
      ((ISSUES++))
    fi

    # Check CLAUDE.md
    if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
      echo -e "\033[0;32m✓\033[0m Global CLAUDE.md exists"
    else
      echo -e "\033[0;33m!\033[0m No global CLAUDE.md"
    fi

    # Check dependencies
    echo ""
    if command -v node &>/dev/null; then
      echo -e "\033[0;32m✓\033[0m node $(node -v)"
    else
      echo -e "\033[0;31m✗\033[0m node not found"
      ((ISSUES++))
    fi
    if command -v git &>/dev/null; then
      echo -e "\033[0;32m✓\033[0m git $(git --version | awk '{print $3}')"
    else
      echo -e "\033[0;31m✗\033[0m git not found"
      ((ISSUES++))
    fi
    if command -v python3 &>/dev/null; then
      echo -e "\033[0;32m✓\033[0m python3 $(python3 --version 2>&1 | awk '{print $2}')"
    else
      echo -e "\033[0;33m!\033[0m python3 not found (optional)"
    fi

    echo ""
    if [[ $ISSUES -eq 0 ]]; then
      echo -e "\033[0;32mAll good!\033[0m"
    else
      echo -e "\033[0;31m$ISSUES issue(s) found.\033[0m Run install.sh to fix."
    fi
    ;;

  uninstall)
    bash "$ADF_HOME/install.sh" --uninstall
    ;;

  version)
    if [[ -f "$ADF_HOME/.claude/metadata.json" ]]; then
      ADF_META="$ADF_HOME/.claude/metadata.json" node -pe 'JSON.parse(require("fs").readFileSync(process.env.ADF_META,"utf8")).version'
    else
      echo "unknown"
    fi
    ;;

  help|--help|-h)
    echo -e "\033[1mADF — Agentic Development Framework\033[0m"
    echo ""
    echo "Usage: adf <command>"
    echo ""
    echo "Commands:"
    echo "  init          Scaffold project context in current directory"
    echo "  update        Update ADF to latest version"
    echo "  doctor        Check installation health"
    echo "  uninstall     Remove global ADF installation"
    echo "  version       Show ADF version"
    echo "  help          Show this help"
    echo ""
    echo "ADF home: $ADF_HOME"
    ;;

  *)
    echo "Unknown command: $CMD"
    echo "Run 'adf help' for usage."
    exit 1
    ;;
esac
CLI_EOF
chmod +x "$ADF_HOME/bin/adf"
ok "adf CLI created"

# Add to PATH
PATH_LINE='export PATH="$HOME/.adf/bin:$PATH"'
SHELL_NAME=$(basename "$SHELL")
RC_FILE="$HOME/.${SHELL_NAME}rc"

if [[ -f "$RC_FILE" ]] && grep -q '.adf/bin' "$RC_FILE"; then
  ok "PATH already configured in $(basename "$RC_FILE")"
else
  echo "" >> "$RC_FILE"
  echo "# ADF (Agentic Development Framework)" >> "$RC_FILE"
  echo "$PATH_LINE" >> "$RC_FILE"
  ok "Added to PATH in $(basename "$RC_FILE")"
fi

# Make available in current session
export PATH="$ADF_HOME/bin:$PATH"

# ── Step 7: Install skills dependencies (optional) ───────────────────────────
step 7 "Installing skills dependencies"

if check_command python3 && [[ -f "$ADF_HOME/.claude/skills/install.sh" ]]; then
  info "Installing skills dependencies (this may take a moment)..."
  cd "$ADF_HOME"
  bash .claude/skills/install.sh -y > /dev/null 2>&1 && ok "Skills dependencies installed" || warn "Some skills dependencies failed (non-blocking)"
else
  warn "Skipped (python3 not found or install script missing)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  ${GREEN}ADF installed successfully!${NC}${BOLD}                      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Quick start:${NC}"
echo -e "    cd your-project"
echo -e "    adf init        ${BLUE}# scaffold project context${NC}"
echo -e "    claude           ${BLUE}# start coding with ADF${NC}"
echo ""
echo -e "  ${BOLD}Commands:${NC}"
echo -e "    adf update       ${BLUE}# update ADF${NC}"
echo -e "    adf doctor       ${BLUE}# check health${NC}"
echo -e "    adf uninstall    ${BLUE}# remove ADF${NC}"
echo ""
echo -e "  ${YELLOW}Restart your shell or run:${NC} source $RC_FILE"
echo ""
