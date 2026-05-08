# Branch Protection Rules

This document describes the branch protection rules applied to the `main` branch. These rules must be configured manually via the GitHub UI or using the `gh api` command below.

## main branch

- **Require pull request before merging**: Yes
- **Required approving reviews**: 1
- **Dismiss stale pull request approvals when new commits are pushed**: Yes
- **Require status checks to pass before merging**: Yes
  - Status check: `ci-success`
- **Require branches to be up to date before merging**: Yes
- **Require linear history**: Yes (no merge commits)
- **Require signed commits**: Optional (recommended for audit trail, but not enforced by this configuration)
- **Restrict who can push to matching branches**: Yes – only repository administrators
- **Allow force pushes**: No
- **Allow deletions**: No

## Apply via gh CLI

Run the following command to set branch protection on `main` (replace `{owner}` and `{repo}` with your actual values):

```bash
gh api repos/{owner}/{repo}/branches/main/protection \
  --method PUT \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["ci-success"]
  },
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true
  },
  "enforce_admins": true,
  "restrictions": {
    "users": [],
    "teams": []
  },
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
```

This JSON body sets:
- `required_status_checks.strict` – ensures branches are up to date with base branch before merging
- `required_pull_request_reviews.required_approving_review_count` – requires 1 approval
- `dismiss_stale_reviews` – dismisses reviews when new commits are pushed
- `enforce_admins` – applies restrictions to administrators
- `restrictions` – empty arrays limit push access to only admins (since `enforce_admins` is true)
- `required_linear_history` – prevents merge commits
- `allow_force_pushes` and `allow_deletions` are disabled

## Verify

After applying, verify the configuration with:

```bash
gh api repos/{owner}/{repo}/branches/main/protection | jq '.required_status_checks, .required_pull_request_reviews'
```

Expected output should show the contexts and review settings you defined.

## Bypass policy

- **Bypass allowed for**: Repository administrators only
- **Logging**: All bypass events (e.g., force push by admin, merging without status checks) are automatically logged in the repository's audit log
- **Record**: Each bypass should be documented in the pull request or commit message with justification
