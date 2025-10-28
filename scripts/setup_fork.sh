#!/bin/bash
# Setup fork and push changes

set -e

echo "=========================================="
echo "Setting up Fork: CK-vn/deepseek-ocr.rs"
echo "=========================================="
echo ""

# Check if we're in the right directory
if [ ! -f "Cargo.toml" ]; then
    echo "Error: Must run from project root directory"
    exit 1
fi

# Step 1: Add your fork as a remote
echo "Step 1: Adding fork remote..."
FORK_URL="https://github.com/CK-vn/deepseek-ocr.rs.git"

# Check if fork remote already exists
if git remote | grep -q "^fork$"; then
    echo "Fork remote already exists, updating URL..."
    git remote set-url fork "$FORK_URL"
else
    echo "Adding fork remote..."
    git remote add fork "$FORK_URL"
fi

# Keep original as upstream
if ! git remote | grep -q "^upstream$"; then
    echo "Adding upstream remote..."
    git remote add upstream https://github.com/TimmyOVO/deepseek-ocr.rs.git
fi

echo "✓ Remotes configured:"
git remote -v
echo ""

# Step 2: Create a feature branch
echo "Step 2: Creating feature branch..."
BRANCH_NAME="feature/default-grounding-bbox"
CURRENT_BRANCH=$(git branch --show-current)

if [ "$CURRENT_BRANCH" = "$BRANCH_NAME" ]; then
    echo "Already on branch: $BRANCH_NAME"
elif git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
    echo "Branch $BRANCH_NAME exists, switching to it..."
    git checkout "$BRANCH_NAME"
else
    echo "Creating new branch: $BRANCH_NAME"
    git checkout -b "$BRANCH_NAME"
fi
echo ""

# Step 3: Stage and commit changes
echo "Step 3: Staging changes..."
git add -A

echo ""
echo "Files to be committed:"
git status --short
echo ""

read -p "Commit these changes? (y/n): " COMMIT_CONFIRM
if [ "$COMMIT_CONFIRM" != "y" ]; then
    echo "Aborted by user"
    exit 1
fi

echo ""
echo "Committing changes..."
git commit -m "feat: Add default grounding mode for bounding boxes

- Automatically inject <|grounding|> tag into prompts
- Support official DeepSeek-OCR bbox format: <|det|>[[x1,y1,x2,y2]]<|/det|>
- Add bbox extraction and visualization
- Include annotated images in API responses
- Add comprehensive documentation and tests
- Backward compatible with explicit 'Free OCR' mode

This enables bounding box output by default without requiring
users to modify their prompts or configuration." || echo "No changes to commit or already committed"

echo "✓ Changes committed"
echo ""

# Step 4: Push to fork
echo "Step 4: Pushing to fork..."
echo "This will push to: $FORK_URL"
echo "Branch: $BRANCH_NAME"
echo ""
read -p "Continue with push? (y/n): " PUSH_CONFIRM

if [ "$PUSH_CONFIRM" = "y" ]; then
    echo "Pushing to fork..."
    git push -u fork "$BRANCH_NAME"
    echo "✓ Pushed to fork"
    echo ""
    echo "=========================================="
    echo "Fork Setup Complete!"
    echo "=========================================="
    echo ""
    echo "Your changes are now at:"
    echo "  https://github.com/CK-vn/deepseek-ocr.rs/tree/$BRANCH_NAME"
    echo ""
    echo "Next steps:"
    echo "1. (Optional) Create a Pull Request to upstream if you want to contribute back"
    echo "2. Update deployment to use your fork:"
    echo "   ./scripts/update_deployment_repo.sh"
    echo ""
else
    echo "Push cancelled. You can push later with:"
    echo "  git push -u fork $BRANCH_NAME"
fi
