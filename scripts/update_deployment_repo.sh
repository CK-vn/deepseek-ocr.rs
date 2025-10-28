#!/bin/bash
# Update Terraform user-data to use your fork

set -e

echo "=========================================="
echo "Update Deployment Repository"
echo "=========================================="
echo ""

# Check if we're in the right directory
if [ ! -f "terraform/user-data.sh" ]; then
    echo "Error: terraform/user-data.sh not found"
    exit 1
fi

FORK_REPO="https://github.com/CK-vn/deepseek-ocr.rs.git"
FORK_BRANCH="feature/default-grounding-bbox"

echo "This will update the deployment to use:"
echo "  Repository: $FORK_REPO"
echo "  Branch: $FORK_BRANCH"
echo ""
read -p "Continue? (y/n): " CONFIRM

if [ "$CONFIRM" != "y" ]; then
    echo "Aborted"
    exit 1
fi

# Backup original user-data.sh
echo "Creating backup..."
cp terraform/user-data.sh terraform/user-data.sh.backup
echo "✓ Backup created: terraform/user-data.sh.backup"
echo ""

# Update the repository URL and add branch specification
echo "Updating user-data.sh..."
sed -i.tmp "s|https://github.com/TimmyOVO/deepseek-ocr.rs.git|$FORK_REPO|g" terraform/user-data.sh

# Update the git clone command to specify branch
sed -i.tmp "s|git clone https://github.com/CK-vn/deepseek-ocr.rs.git|git clone -b $FORK_BRANCH $FORK_REPO|g" terraform/user-data.sh

# Also update the git pull to use the correct branch
sed -i.tmp "s|git pull|git pull origin $FORK_BRANCH|g" terraform/user-data.sh

rm -f terraform/user-data.sh.tmp

echo "✓ user-data.sh updated"
echo ""

# Show the changes
echo "Changes made:"
echo "----------------------------------------"
grep -n "github.com" terraform/user-data.sh | head -5
echo "----------------------------------------"
echo ""

echo "✓ Deployment configuration updated!"
echo ""
echo "Next steps:"
echo "1. Review the changes in terraform/user-data.sh"
echo "2. Deploy the changes:"
echo "   ./scripts/deploy_changes.sh"
echo ""
