# Template 19 Provenance

The files under `template-19/` are copied without modification from:

- Repository: `https://github.com/microsoft-foundry/foundry-samples.git`
- Path: `infrastructure/infrastructure-setup-bicep/19-private-network-agent-tools`
- Commit: `74b93d65e1b2c1e22d661ef883a747962f47a8ee`
- Template version: `1.1.0`

At import time, all 74 copied files matched the source file list and SHA-256 hashes. Project-specific values live in `food-analytics.bicepparam`, outside the vendored directory.

## Deviations from the vendored source

One file has been modified since import. Re-applying the upstream copy will reintroduce the bug.

### `modules-network-secured/key-vault.bicep`

Removed `enablePurgeProtection: false`. Azure rejects an explicit `false` for this property with:

```
BadRequest: The property "enablePurgeProtection" cannot be set to false.
Enabling the purge protection for a vault is an irreversible action.
```

The property must be `true` or omitted. As shipped, the template cannot deploy its Key Vault at all.

### `modules-network-secured/application-insights.bicep`

Added a `disablePublicQuery` parameter (default `true`) and applied it to Application Insights
`publicNetworkAccessForQuery`, which upstream hard-codes to `'Enabled'`. Also set
`publicNetworkAccessForIngestion` and `publicNetworkAccessForQuery` on the Log Analytics workspace,
which upstream omits entirely — so both default to public.

### `modules-network-secured/monitor-private-link-scope.bicep`

Added a `queryAccessMode` parameter (default `'PrivateOnly'`) for the AMPLS, which upstream
hard-codes to `'Open'`.

Together these close public log query. **Consequence:** portal and CLI log queries now require a
client inside the VNet. Set `disablePublicQuery: false` and `queryAccessMode: 'Open'` to restore
external access.

### `modules-network-secured/vnet.bicep`, `modules-network-secured/network-agent-vnet.bicep`, `main.bicep`

Added two extra subnets for Databricks VNet injection — a host subnet and a container subnet, each
delegated to `Microsoft.Databricks/workspaces` with a shared NSG. Upstream ships three subnets and
has no concept of Databricks.

The parameters must be threaded through **all three** files. `main.bicep` does not call `vnet.bicep`
directly; it calls `network-agent-vnet.bicep`, which in turn calls `vnet.bicep`. Patching only
`vnet.bicep` silently has no effect, because the intermediate module never passes the new parameters
down.
