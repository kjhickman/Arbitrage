# LibAHTab

Vendored from [TheMouseNest/LibAHTab](https://github.com/TheMouseNest/LibAHTab) at commit
`2ddbec58c8be37b2cd911bee7512d597e7dfdfe1`.

LibStub is included from the same upstream repository.

## Updates

The [vendoring workflow](../../.github/workflows/update-libah-tab.yml) checks upstream's
default branch every Monday at 08:23 UTC. It copies LibAHTab, bundled LibStub, and the
license from a single commit, updates the pin above, and opens or updates one PR on
`automation/update-libah-tab`. Unchanged upstream produces no new commit or PR.

The workflow uses `GITHUB_TOKEN` and explicitly dispatches CI on the PR branch, so no
PAT is needed. Enable **Settings → Actions → General → Workflow permissions → Allow
GitHub Actions to create and approve pull requests**. Updates require manual review
and merging.

Once the workflow is on `main`, check for updates manually from the Actions tab or run
`gh workflow run update-libah-tab.yml`.
