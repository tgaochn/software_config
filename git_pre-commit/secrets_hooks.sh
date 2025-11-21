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

echo -e "${CYAN}\n[1/6] Checking environment...${NC}"

# --- 2. 检查环境 ---
if ! command -v python &> /dev/null; then
    echo -e "${RED}Error: Python not found! Please run inside a venv or ensure python is in PATH.${NC}"
    exit 1
fi

if [ ! -d ".git" ]; then
    echo -e "${RED}Error: Not a git repository! Please run 'git init' first.${NC}"
    exit 1
fi

# --- 3. 安装依赖 ---
echo -e "${CYAN}[2/6] Installing/Updating dependencies...${NC}"
python -m pip install pre-commit detect-secrets --quiet
if [ $? -ne 0 ]; then exit 1; fi

# --- 4. 创建配置文件 ---
echo -e "${CYAN}[3/6] Configuring pre-commit...${NC}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "$CONFIG_CONTENT" > "$CONFIG_FILE"
    echo -e "${GREEN} -> Created $CONFIG_FILE${NC}"
else
    echo -e "${YELLOW} -> $CONFIG_FILE already exists. Skipping.${NC}"
fi

# --- 5. 生成基线文件 ---
echo -e "${CYAN}[4/6] Setting up baseline...${NC}"
if [ ! -f "$BASELINE_FILE" ]; then
    python -m detect_secrets scan > "$BASELINE_FILE"
    git add "$BASELINE_FILE"
    echo -e "${GREEN} -> Generated $BASELINE_FILE${NC}"
else
    echo -e "${YELLOW} -> $BASELINE_FILE already exists. Skipping.${NC}"
fi

# --- 6. 安装 Hooks ---
echo -e "${CYAN}[5/6] Installing Git Hooks...${NC}"
python -m pre_commit install
if [ $? -ne 0 ]; then 
    echo -e "${RED}Failed to install hooks${NC}"
    exit 1
fi

# --- 7. [关键] 验证测试模块 ---
echo -e "\n${CYAN}[6/6] VERIFYING SECURITY SHIELD...${NC}"

# 7.1 准备测试环境
if [ -d "$TEST_DIR" ]; then rm -rf "$TEST_DIR"; fi
mkdir -p "$TEST_DIR"

# 7.2 创建文件
# 正常文件
echo "print('This is a clean file')" > "$TEST_DIR/clean.py"
# 脏文件 (包含 AWS Key 示例)
echo "aws_key = 'AKIAIMNOKEYFORTESTING'" > "$TEST_DIR/dirty.py" # pragma: allowlist secret # gitleaks:allow

echo -e "${GRAY} -> Created temporary test files (Clean & Dirty).${NC}"

# 7.3 加入暂存区
git add "$TEST_DIR"

# 7.4 运行 Pre-commit
echo -e "${GRAY} -> Running pre-commit check on test files...${NC}"
echo -e "${GRAY}---------------------------------------------------${NC}"

# 运行检查
python -m pre_commit run --files "$TEST_DIR/clean.py" "$TEST_DIR/dirty.py"

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
git reset "$TEST_DIR" &> /dev/null
rm -rf "$TEST_DIR"

echo -e "${CYAN}Setup and Verification Complete.${NC}"