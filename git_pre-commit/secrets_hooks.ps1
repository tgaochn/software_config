<#
.SYNOPSIS
    一键配置 Git 安全防护 (Gitleaks + Detect-secrets) 并进行自测
.DESCRIPTION
    1. 检查 Python/Git 环境
    2. 配置项目文件 (.vscode/settings.json & .gitignore)
    3. 安装/更新 pre-commit 和 detect-secrets
    4. 自动配置 .pre-commit-config.yaml
    5. 生成 .secrets.baseline
    6. 安装 Git Hooks
    7. 创建测试文件并验证拦截功能是否生效
#>

# --- 1. 配置区域 ---
$ConfigFile = ".pre-commit-config.yaml"
$BaselineFile = ".secrets.baseline"
$TestDir = ".tmp_security_check" # 临时测试目录名
$VSCodeDir = ".vscode"
$VSCodeSettings = ".vscode/settings.json"
$GitignoreFile = ".gitignore"

$ConfigContent = @"
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.2
    hooks:
      - id: gitleaks
  - repo: https://github.com/Yelp/detect-secrets
    rev: v1.5.0
    hooks:
      - id: detect-secrets
        args: ['--baseline', '$BaselineFile']
        exclude: package-lock.json|yarn.lock
"@

# --- 2. 检查环境 ---
Write-Host "`n[1/8] Checking environment..." -ForegroundColor Cyan

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Error "Python not found! Please run inside a generic terminal or activate venv."
    exit 1
}

if (-not (Test-Path .git)) {
    Write-Error "Not a git repository! Please run 'git init' first."
    exit 1
}

# --- 3. 配置 VS Code 设置 ---
Write-Host "[2/8] Configuring VS Code settings..." -ForegroundColor Cyan
if (-not (Test-Path ".vscode")) {
    New-Item -ItemType Directory -Force ".vscode" | Out-Null
}

if (-not (Test-Path ".vscode/settings.json")) {
    $VSCodeContent = @'
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
        ".vscode": true,
        ".cursorignore": true
    }
}
'@
    Set-Content -Path ".vscode/settings.json" -Value $VSCodeContent -Encoding UTF8
    Write-Host " -> Created .vscode/settings.json" -ForegroundColor Green
} else {
    Write-Host " -> .vscode/settings.json already exists. Skipping." -ForegroundColor Yellow
}

# --- 4. 配置 .gitignore ---
Write-Host "[3/8] Configuring .gitignore..." -ForegroundColor Cyan
if (-not (Test-Path ".gitignore")) {
    $GitignoreContent = @'
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
'@
    Set-Content -Path ".gitignore" -Value $GitignoreContent -Encoding UTF8
    Write-Host " -> Created .gitignore" -ForegroundColor Green
} else {
    Write-Host " -> .gitignore already exists. Skipping." -ForegroundColor Yellow
}

# --- 5. 安装依赖 ---
Write-Host "[4/8] Installing/Updating dependencies..." -ForegroundColor Cyan
python -m pip install pre-commit detect-secrets --quiet
if ($LASTEXITCODE -ne 0) { exit 1 }

# --- 6. 创建配置文件 ---
Write-Host "[5/8] Configuring pre-commit..." -ForegroundColor Cyan
if (-not (Test-Path ".pre-commit-config.yaml")) {
    Set-Content -Path ".pre-commit-config.yaml" -Value $ConfigContent
    Write-Host " -> Created .pre-commit-config.yaml" -ForegroundColor Green
} else {
    Write-Host " -> .pre-commit-config.yaml already exists. Skipping." -ForegroundColor Yellow
}

# --- 7. 生成基线文件 ---
Write-Host "[6/8] Setting up baseline..." -ForegroundColor Cyan
if (-not (Test-Path ".secrets.baseline")) {
    # Fix encoding issue: Force UTF-8 output without BOM
    $PrevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    python -m detect_secrets scan | Out-File -FilePath ".secrets.baseline" -Encoding utf8NoBOM
    [Console]::OutputEncoding = $PrevEncoding
    git add ".secrets.baseline"
    Write-Host " -> Generated .secrets.baseline (UTF-8)" -ForegroundColor Green
} else {
    Write-Host " -> .secrets.baseline already exists. Skipping." -ForegroundColor Yellow
}

# --- 8. 安装 Hooks ---
Write-Host "[7/8] Installing Git Hooks..." -ForegroundColor Cyan
python -m pre_commit install
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to install hooks"; exit 1 }

# --- 9. [关键] 验证测试模块 ---
Write-Host "`n[8/8] VERIFYING SECURITY SHIELD..." -BackgroundColor DarkBlue -ForegroundColor White

# 7.1 准备测试环境
if (Test-Path ".tmp_security_check") { Remove-Item ".tmp_security_check" -Recurse -Force }
New-Item -ItemType Directory -Force ".tmp_security_check" | Out-Null

# 7.2 创建文件
# 正常文件
Set-Content -Path ".tmp_security_check/clean.py" -Value "print('This is a clean file')"
# 脏文件 (包含 AWS Key 示例)
Set-Content -Path ".tmp_security_check/dirty.py" -Value "aws_key = 'AKIAIMNOKEYFORTESTING'" # pragma: allowlist secret # gitleaks:allow

Write-Host " -> Created temporary test files (Clean & Dirty)." -ForegroundColor Gray

# 7.3 加入暂存区 (Pre-commit 需要)
git add ".tmp_security_check"

# 7.4 运行 Pre-commit
Write-Host " -> Running pre-commit check on test files..." -ForegroundColor Gray
Write-Host "---------------------------------------------------" -ForegroundColor DarkGray

# 运行检查，同时捕获退出代码
# 注意：我们期望它失败（返回非0），因为它应该发现 dirty.py
python -m pre_commit run --files ".tmp_security_check/clean.py" ".tmp_security_check/dirty.py"

$CheckResult = $LASTEXITCODE

Write-Host "---------------------------------------------------" -ForegroundColor DarkGray

# 7.5 判定结果
if ($CheckResult -ne 0) {
    # 退出代码不为0，说明拦截成功
    Write-Host "`n[PASS] SUCCESS! The system successfully BLOCKED the secret token." -ForegroundColor Green
    Write-Host "       (You can see the 'Failed' message above, which is what we want.)" -ForegroundColor Green
} else {
    # 退出代码为0，说明拦截失败
    Write-Host "`n[FAIL] DANGER! The system ALLOWED the secret token to pass." -ForegroundColor Red
    Write-Host "       Please check your configuration." -ForegroundColor Red
}

# 7.6 清理现场
Write-Host "`n[Cleanup] Cleaning up temporary test files..." -ForegroundColor DarkGray
git reset ".tmp_security_check" | Out-Null
Remove-Item ".tmp_security_check" -Recurse -Force

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Setup and Verification Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

# --- 10. [可选] 扫描当前项目 ---
Write-Host "`n[OPTIONAL] Do you want to scan all files in current project?" -ForegroundColor Yellow
Write-Host "This will check all existing files for secrets (may take some time)." -ForegroundColor Gray
Write-Host "Press [Y] to scan, or any other key to skip..." -ForegroundColor Gray

$Response = Read-Host

if ($Response -eq 'Y' -or $Response -eq 'y') {
    Write-Host "`n[Scanning] Running pre-commit on all files..." -ForegroundColor Cyan
    Write-Host "---------------------------------------------------" -ForegroundColor DarkGray
    
    python -m pre_commit run --all-files
    
    $ScanResult = $LASTEXITCODE
    
    Write-Host "---------------------------------------------------" -ForegroundColor DarkGray
    
    if ($ScanResult -eq 0) {
        Write-Host "`n[CLEAN] All files passed security checks!" -ForegroundColor Green
    } else {
        Write-Host "`n[WARNING] Some files failed security checks." -ForegroundColor Red
        Write-Host "Please review the output above and fix any issues." -ForegroundColor Yellow
        Write-Host "You can run 'pre-commit run --all-files' anytime to re-check." -ForegroundColor Yellow
    }
} else {
    Write-Host "`nSkipped project scan. You can run it manually later:" -ForegroundColor Yellow
    Write-Host "  pre-commit run --all-files" -ForegroundColor Gray
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "All Done! Happy Coding!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan