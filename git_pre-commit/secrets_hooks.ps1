<#
.SYNOPSIS
    一键配置 Git 安全防护 (Gitleaks + Detect-secrets) 并进行自测
.DESCRIPTION
    1. 检查 Python/Git 环境
    2. 安装/更新 pre-commit 和 detect-secrets
    3. 自动配置 .pre-commit-config.yaml
    4. 生成 .secrets.baseline
    5. 安装 Git Hooks
    6. [NEW] 创建测试文件并验证拦截功能是否生效
#>

# --- 1. 配置区域 ---
$ConfigFile = ".pre-commit-config.yaml"
$BaselineFile = ".secrets.baseline"
$TestDir = ".tmp_security_check" # 临时测试目录名

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
Write-Host "`n[1/6] Checking environment..." -ForegroundColor Cyan

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Error "Python not found! Please run inside a generic terminal or activate venv."
    exit 1
}

if (-not (Test-Path .git)) {
    Write-Error "Not a git repository! Please run 'git init' first."
    exit 1
}

# --- 3. 安装依赖 ---
Write-Host "[2/6] Installing/Updating dependencies..." -ForegroundColor Cyan
python -m pip install pre-commit detect-secrets --quiet
if ($LASTEXITCODE -ne 0) { exit 1 }

# --- 4. 创建配置文件 ---
Write-Host "[3/6] Configuring pre-commit..." -ForegroundColor Cyan
if (-not (Test-Path $ConfigFile)) {
    Set-Content -Path $ConfigFile -Value $ConfigContent
    Write-Host " -> Created $ConfigFile" -ForegroundColor Green
} else {
    Write-Host " -> $ConfigFile already exists. Skipping." -ForegroundColor Yellow
}

# --- 5. 生成基线文件 ---
Write-Host "[4/6] Setting up baseline..." -ForegroundColor Cyan
if (-not (Test-Path $BaselineFile)) {
    python -m detect_secrets scan > $BaselineFile
    git add $BaselineFile
    Write-Host " -> Generated $BaselineFile" -ForegroundColor Green
} else {
    Write-Host " -> $BaselineFile already exists. Skipping." -ForegroundColor Yellow
}

# --- 6. 安装 Hooks ---
Write-Host "[5/6] Installing Git Hooks..." -ForegroundColor Cyan
python -m pre_commit install
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to install hooks"; exit 1 }

# --- 7. [关键] 验证测试模块 ---
Write-Host "`n[6/6] VERIFYING SECURITY SHIELD..." -BackgroundColor DarkBlue -ForegroundColor White

# 7.1 准备测试环境
if (Test-Path $TestDir) { Remove-Item $TestDir -Recurse -Force }
New-Item -ItemType Directory -Force $TestDir | Out-Null

# 7.2 创建文件
# 正常文件
Set-Content -Path "$TestDir/clean.py" -Value "print('This is a clean file')"
# 脏文件 (包含 AWS Key 示例)
Set-Content -Path "$TestDir/dirty.py" -Value "aws_key = 'AKIAIMNOKEYFORTESTING'" # pragma: allowlist secret # gitleaks:allow

Write-Host " -> Created temporary test files (Clean & Dirty)." -ForegroundColor Gray

# 7.3 加入暂存区 (Pre-commit 需要)
git add $TestDir

# 7.4 运行 Pre-commit
Write-Host " -> Running pre-commit check on test files..." -ForegroundColor Gray
Write-Host "---------------------------------------------------" -ForegroundColor DarkGray

# 运行检查，同时捕获退出代码
# 注意：我们期望它失败（返回非0），因为它应该发现 dirty.py
python -m pre_commit run --files "$TestDir/clean.py" "$TestDir/dirty.py"

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
git reset $TestDir | Out-Null
Remove-Item $TestDir -Recurse -Force

Write-Host "Setup and Verification Complete." -ForegroundColor Cyan