#!/bin/bash

# ==============================================================================
# SYNOPSIS
#     一键配置 Git 安全防护 (Gitleaks + Detect-secrets) 并进行自测 (Linux/macOS版)
# ==============================================================================

# --- 0. 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# --- 1. 配置区域 ---
CONFIG_FILE=".pre-commit-config.yaml"
BASELINE_FILE=".secrets.baseline"
TEST_DIR=".tmp_security_check"
VSCODE_DIR=".vscode"
VSCODE_SETTINGS="$VSCODE_DIR/settings.json"
GITIGNORE_FILE=".gitignore"

# 使用 heredoc 生成 YAML 内容
read -r -d '' CONFIG_CONTENT << EOM
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.2
    hooks:
      - id: gitleaks
  - repo: https://github.com/Yelp/detect-secrets
    rev: v1.5.0
    hooks:
      - id: detect-secrets
        args: ['--baseline', '$BASELINE_FILE']
        exclude: package-lock.json|yarn.lock
EOM

echo -e "${CYAN}\n[1/8] Checking environment...${NC}"

# --- 2. 检查环境 ---
if ! command -v python &> /dev/null; then
    echo -e "${RED}Error: Python not found! Please run inside a venv or ensure python is in PATH.${NC}"
    exit 1
fi

if [ ! -d ".git" ]; then
    echo -e "${RED}Error: Not a git repository! Please run 'git init' first.${NC}"
    exit 1
fi

# --- 3. 配置 VS Code 设置 ---
echo -e "${CYAN}[2/8] Configuring VS Code settings...${NC}"
if [ ! -d ".vscode" ]; then
    mkdir -p ".vscode"
fi

if [ ! -f ".vscode/settings.json" ]; then
    cat > "$VSCODE_SETTINGS" << 'EOF'
{
    "files.exclude": {
        "**/.git": true,
        "**/.svn": true,
        "**/.hg": true,
        "**/.DS_Store": true,
        "**/Thumbs.db": true,
        "**/__init__.py": true,
        "**/__pycache__": true,
        "**/.classpath": true,
        "**/.factorypath": true,
        "**/.project": true,
        "**/.settings": true,
        "**/*.pyc": true,
        "**/node_modules": true,
        "**/CVS": true,
        "_media-sync_resources": true,
        "_pasted_img": true,
        ".obsidian": true,
        ".pre-commit-config.yaml": true,
        ".secrets.baseline": true,
        ".vscode": false,
        ".cursorignore": true
    }
}
EOF
    echo -e "${GREEN} -> Created .vscode/settings.json${NC}"
else
    echo -e "${YELLOW} -> .vscode/settings.json already exists. Skipping.${NC}"
fi

# --- 4. 配置 .gitignore ---
echo -e "${CYAN}[3/8] Configuring .gitignore...${NC}"
if [ ! -f ".gitignore" ]; then
    cat > "$GITIGNORE_FILE" << 'EOF'
# ==============================================================================
# Git Ignore Configuration
# ==============================================================================

# Windows/macOS/Linux
.DS_Store
Thumbs.db
ehthumbs.db
Desktop.ini
.directory
.Trash-*

# IDE and Editor settings
.vscode/
.idea/
.settings/
*.swp
*.swo
.project
.classpath
.factorypath

# Obsidian
.obsidian/

# Log/Temporary files
tempfile/
logs/
*.log.*
*.tmp
*.bak

# Executable files
*.exe

# Sensitive information
.env
.env.*
secrets.json
credentials.json
EOF
    echo -e "${GREEN} -> Created .gitignore${NC}"
else
    echo -e "${YELLOW} -> .gitignore already exists. Skipping.${NC}"
fi

# --- 5. 安装依赖 ---
echo -e "${CYAN}[4/8] Installing/Updating dependencies...${NC}"
python -m pip install pre-commit detect-secrets --quiet
if [ $? -ne 0 ]; then exit 1; fi

# --- 6. 创建配置文件 ---
echo -e "${CYAN}[5/8] Configuring pre-commit...${NC}"
if [ ! -f ".pre-commit-config.yaml" ]; then
    echo "$CONFIG_CONTENT" > ".pre-commit-config.yaml"
    echo -e "${GREEN} -> Created .pre-commit-config.yaml${NC}"
else
    echo -e "${YELLOW} -> .pre-commit-config.yaml already exists. Skipping.${NC}"
fi

# --- 7. 生成基线文件 ---
echo -e "${CYAN}[6/8] Setting up baseline...${NC}"
if [ ! -f ".secrets.baseline" ]; then
    # Fix encoding issue: Ensure UTF-8 encoding
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
    python -m detect_secrets scan > ".secrets.baseline"
    git add ".secrets.baseline"
    echo -e "${GREEN} -> Generated .secrets.baseline (UTF-8)${NC}"
else
    echo -e "${YELLOW} -> .secrets.baseline already exists. Skipping.${NC}"
fi

# --- 8. 安装 Hooks ---
echo -e "${CYAN}[7/8] Installing Git Hooks...${NC}"
python -m pre_commit install
if [ $? -ne 0 ]; then 
    echo -e "${RED}Failed to install hooks${NC}"
    exit 1
fi

# --- 9. [关键] 验证测试模块 ---
echo -e "\n${CYAN}[8/8] VERIFYING SECURITY SHIELD...${NC}"

# 7.1 准备测试环境
if [ -d ".tmp_security_check" ]; then rm -rf ".tmp_security_check"; fi
mkdir -p ".tmp_security_check"

# 7.2 创建文件
# 正常文件
echo "print('This is a clean file')" > ".tmp_security_check/clean.py"
# 脏文件 (包含 AWS Key 示例)
echo "aws_key = 'AKIAIMNOKEYFORTESTING'" > ".tmp_security_check/dirty.py" # pragma: allowlist secret # gitleaks:allow

echo -e "${GRAY} -> Created temporary test files (Clean & Dirty).${NC}"

# 7.3 加入暂存区
git add ".tmp_security_check"

# 7.4 运行 Pre-commit
echo -e "${GRAY} -> Running pre-commit check on test files...${NC}"
echo -e "${GRAY}---------------------------------------------------${NC}"

# 运行检查
python -m pre_commit run --files ".tmp_security_check/clean.py" ".tmp_security_check/dirty.py"

# 获取退出代码
CHECK_RESULT=$?

echo -e "${GRAY}---------------------------------------------------${NC}"

# 7.5 判定结果 (期望失败/非0)
if [ $CHECK_RESULT -ne 0 ]; then
    echo -e "\n${GREEN}[PASS] SUCCESS! The system successfully BLOCKED the secret token.${NC}"
    echo -e "${GREEN}       (You can see the 'Failed' message above, which is what we want.)${NC}"
else
    echo -e "\n${RED}[FAIL] DANGER! The system ALLOWED the secret token to pass.${NC}"
    echo -e "${RED}       Please check your configuration.${NC}"
fi

# 7.6 清理现场
echo -e "\n${GRAY}[Cleanup] Cleaning up temporary test files...${NC}"
git reset ".tmp_security_check" &> /dev/null
rm -rf ".tmp_security_check"

echo -e "\n${CYAN}========================================${NC}"
echo -e "${GREEN}Setup and Verification Complete!${NC}"
echo -e "${CYAN}========================================${NC}"

# --- 10. [可选] 扫描当前项目 ---
echo -e "\n${YELLOW}[OPTIONAL] Do you want to scan all files in current project?${NC}"
echo -e "${GRAY}This will check all existing files for secrets (may take some time).${NC}"
echo -e "${GRAY}Press [Y/y] to scan, or any other key to skip...${NC}"

read -n 1 -r RESPONSE
echo

if [[ $RESPONSE =~ ^[Yy]$ ]]; then
    echo -e "\n${CYAN}[Scanning] Running pre-commit on all files...${NC}"
    echo -e "${GRAY}---------------------------------------------------${NC}"
    
    python -m pre_commit run --all-files
    
    SCAN_RESULT=$?
    
    echo -e "${GRAY}---------------------------------------------------${NC}"
    
    if [ $SCAN_RESULT -eq 0 ]; then
        echo -e "\n${GREEN}[CLEAN] All files passed security checks!${NC}"
    else
        echo -e "\n${RED}[WARNING] Some files failed security checks.${NC}"
        echo -e "${YELLOW}Please review the output above and fix any issues.${NC}"
        echo -e "${YELLOW}You can run 'pre-commit run --all-files' anytime to re-check.${NC}"
    fi
else
    echo -e "\n${YELLOW}Skipped project scan. You can run it manually later:${NC}"
    echo -e "${GRAY}  pre-commit run --all-files${NC}"
fi

echo -e "\n${CYAN}========================================${NC}"
echo -e "${GREEN}All Done! Happy Coding!${NC}"
echo -e "${CYAN}========================================${NC}"