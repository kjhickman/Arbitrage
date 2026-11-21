# LibDBIcon-1.0

Vendored from the trunk of [LibDBIcon-1.0](https://repos.wowace.com/wow/libdbicon-1-0/trunk/) at revision `167`.

LibDataBroker-1.1 and CallbackHandler-1.0 are included from the same upstream revision. LibStub comes from
LibAHTab. CallbackHandler's license is copied from [WoWUIDev/Ace3](https://github.com/WoWUIDev/Ace3), where it is
developed. LibDBIcon and LibDataBroker ship no license file; LibDBIcon's TOC says "All Rights Reserved", and it is
published for addons to embed.

## Updates

The [vendoring workflow](../../.github/workflows/update-libdbicon.yml) checks upstream's trunk every Monday at 08:53
UTC. It pins trunk's last-changed revision rather than the repository's, which also moves when a release is tagged,
copies the three libraries from that revision, updates the pin above, and opens or updates one PR on
`automation/update-libdbicon`. Unchanged upstream produces no new commit or PR.

Like the [LibAHTab workflow](../LibAHTab/README.md#updates), it uses `GITHUB_TOKEN`, dispatches CI on the PR branch,
and needs manual review and merging. Check for updates manually from the Actions tab or run
`gh workflow run update-libdbicon.yml`.
