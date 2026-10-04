import json
import re
from pathlib import Path


ROOT = Path(__file__).parents[2]


def executable_powershell(path: Path) -> str:
    """Return a script with comments removed.

    Tests that forbid a command must assert on code that actually runs. Documentation
    explaining *why* a command is avoided would otherwise trip the same assertion.
    """
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"<#.*?#>", "", text, flags=re.DOTALL)
    lines = [line for line in text.splitlines() if not line.lstrip().startswith("#")]
    return "\n".join(lines)


def executable_bicep(path: Path) -> str:
    """Return a template with comments removed, for the same reason."""
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    lines = [line for line in text.splitlines() if not line.lstrip().startswith("//")]
    return "\n".join(lines)


def test_private_template_parameters_are_regional() -> None:
    parameters = (ROOT / "deployment" / "food-analytics.bicepparam").read_text(
        encoding="utf-8"
    )

    assert "param location = 'swedencentral'" in parameters
    assert "param modelName = 'gpt-5.1'" in parameters
    assert "param modelVersion = '2025-11-13'" in parameters
    assert "param modelSkuName = 'Standard'" in parameters
    assert "param vnetAddressPrefix = '10.19.0.0/16'" in parameters


def test_azd_manifest_cannot_provision_public_foundry() -> None:
    manifest = (ROOT / "azure.yaml").read_text(encoding="utf-8")

    assert "host: azure.ai.agent" in manifest
    assert "provider: microsoft.foundry" not in manifest
    assert "host: azure.ai.project" not in manifest
    assert "FOUNDRY_PROJECT_ENDPOINT:" not in manifest


def test_unresolved_toolbox_is_not_deployable_by_accident() -> None:
    assert not (ROOT / "agent" / "toolbox.yaml").exists()
    assert (ROOT / "agent" / "toolbox.yaml.example").exists()


def test_databricks_is_reached_privately_with_no_public_fallback() -> None:
    module = (ROOT / "deployment" / "databricks-private-link.bicep").read_text(
        encoding="utf-8"
    )

    assert "'databricks_ui_api'" in module
    assert "privatelink.azuredatabricks.net" in module
    assert "privateDnsZoneGroups" in module
    assert "virtualNetworkLinks" in module

    # Keep the workspace ID required so a missing value fails the deployment instead of going public.
    assert "@minLength(1)" in module
    assert "param databricksWorkspaceResourceId string =" not in module


def test_genie_connection_uses_managed_identity_and_the_guid_audience() -> None:
    module = executable_bicep(ROOT / "deployment" / "foundry-connections.bicep")

    assert "category: 'RemoteTool'" in module
    assert "authType: 'ProjectManagedIdentity'" in module

    # Databricks validates the aud claim against the application ID GUID and rejects
    # the https://azuredatabricks.net/ form with HTTP 400, despite it being a valid
    # Entra identifier for the same service.
    assert "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" in module
    assert "audience: databricksResourceId" in module
    assert "azuredatabricks.net/'" not in module

    # No credential may reappear in the connection.
    assert "@secure()" not in module
    assert "custom-keys" not in module


def test_databricks_identity_grant_includes_entitlements() -> None:
    script = (ROOT / "deployment" / "grant-databricks-identity.ps1").read_text(encoding="utf-8")

    # Databricks returns 403 for a registered principal that holds object permissions
    # but no workspace entitlements, so both parts are required.
    assert "workspace-access" in script
    assert "databricks-sql-access" in script
    assert "CAN_RUN" in script
    assert "CAN_USE" in script
    assert "SELECT" in script

    # Least privilege: the agent identity must never be made a workspace admin.
    assert "CAN_MANAGE" not in script
    assert "admins" not in script


def test_agent_package_builds_with_pip_not_poetry() -> None:
    requirements = (ROOT / "agent" / "requirements.txt").read_text(encoding="utf-8")
    agentignore = (ROOT / "agent" / ".agentignore").read_text(encoding="utf-8").splitlines()

    # The remote builder treats any pyproject.toml as a Poetry project and fails with
    # "[tool.poetry] section not found", so the deployed package must not contain one.
    assert "pyproject.toml" in agentignore

    # An editable install would pull pyproject.toml back into the build.
    assert "-e ." not in requirements
    assert "agent-framework-foundry" in requirements


def test_jumpbox_restricts_rdp_to_a_single_operator_address() -> None:
    module = (ROOT / "deployment" / "jumpbox.bicep").read_text(encoding="utf-8")

    assert "destinationPortRange: '3389'" in module
    assert "sourceAddressPrefix: allowedSourceIp" in module
    assert "@minLength(7)" in module

    # A wildcard source would expose RDP to the internet.
    assert "sourceAddressPrefix: '*'\n          sourcePortRange: '*'\n          destinationAddressPrefix: '*'\n          destinationPortRange: '3389'" not in module
    assert "access: 'Deny'" in module

    # The password must never be a plain parameter or carry a default.
    assert "@secure()" in module
    assert "param adminPassword string =" not in module


def test_toolbox_references_the_genie_connection() -> None:
    spec = (ROOT / "agent" / "toolbox.yaml.example").read_text(encoding="utf-8")

    assert "server_label: databricks_genie" in spec
    assert "project_connection_id: databricks-genie" in spec

    # The spec is deployed as-is, so an unrendered placeholder would reach Foundry.
    assert "<" not in spec
    assert "fabric" not in spec.lower()


def test_deployment_plan_referenced_by_agent_guidance_exists() -> None:
    guidance = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    assert "docs/deployment-plan.md" in guidance
    assert (ROOT / "docs" / "deployment-plan.md").exists()


def test_local_env_and_rendered_toolbox_are_git_ignored() -> None:
    ignored = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()

    assert ".env" in ignored
    assert "!.env.example" in ignored
    assert "agent/toolbox.yaml" in ignored


def test_key_vault_purge_protection_patch_survives_revendoring() -> None:
    module = (
        ROOT / "deployment" / "template-19" / "modules-network-secured" / "key-vault.bicep"
    ).read_text(encoding="utf-8")

    # Azure rejects an explicit false; re-vendoring upstream reintroduces this and breaks deployment.
    assert "enablePurgeProtection: false" not in module

    provenance = (ROOT / "deployment" / "TEMPLATE19_SOURCE.md").read_text(encoding="utf-8")
    assert "key-vault.bicep" in provenance


def test_genie_space_reads_only_the_shared_views() -> None:
    script = executable_powershell(ROOT / "deployment" / "create-genie-space.ps1")

    for view in ("sales_analytics", "sales_kpi", "waste_analytics"):
        assert f"$views.{view}" in script

    # Raw tables let Genie derive its own aggregates and disagree with the dashboard.
    for raw in ("fact_sales", "fact_food_waste", "dim_product", "dim_store", "dim_date"):
        assert raw not in script

    # There must be one definition; a second copy drifts and silently reverts the space.
    assert not (ROOT / "deployment" / "jumpbox-update-genie-space.ps1").exists()


def test_genie_kpi_names_match_the_sales_kpi_view() -> None:
    """Genie picked the wrong KPI row when its instructions and the view disagreed."""
    views = (ROOT / "deployment" / "jumpbox-create-shared-views.ps1").read_text(encoding="utf-8")
    kpi_view = views.split("CREATE OR REPLACE VIEW $catalog.$schema.sales_kpi", 1)[1].split('"@', 1)[0]
    view_names = set(re.findall(r"SELECT '([^']+)'", kpi_view))

    script = executable_powershell(ROOT / "deployment" / "create-genie-space.ps1")
    declared = script.split("$kpiNames = @(", 1)[1].split(")", 1)[0]
    genie_names = set(re.findall(r"'([^']+)'", declared))

    assert view_names, "no metric names parsed from the sales_kpi view"
    assert genie_names == view_names

    # Every example query must select a metric that exists, by exact name.
    for used in re.findall(r"Get-KpiSql '([^']+)'", script):
        assert used in view_names
    assert "LIKE" not in script.split("$exampleSql = @(", 1)[1].split("$instructions", 1)[0]


def test_no_stored_credential_reappears_anywhere_in_deployment() -> None:
    """The design authenticates entirely with managed identity.

    Databricks OAuth secrets require an Entra Global Administrator to mint, which is
    not available here, so a reintroduced credential would be unrotatable.
    """
    offenders = []
    for path in (ROOT / "deployment").rglob("*"):
        if not path.is_file() or "template-19" in path.parts:
            continue
        if path.suffix.lower() not in {".bicep", ".ps1", ".bicepparam"}:
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        if "DATABRICKS_CLIENT_SECRET" in text or "databricks-client-secret" in text:
            offenders.append(path.name)

    assert offenders == []




ENVIRONMENT_IDENTIFIERS = {
    "subscription ID": re.compile(r"/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I),
    "Databricks workspace host": re.compile(r"adb-(?!1234567890123456\b)\d{12,}"),
    "SQL warehouse ID": re.compile(r"warehouses/[0-9a-f]{16}\b"),
    "Genie space ID": re.compile(r"\b[0-9a-f]{32}\b"),
    "tenant user": re.compile(r"@[a-z0-9-]+\.onmicrosoft\.com", re.I),
}


def committed_text_files() -> list[Path]:
    skip = {"template-19", ".git", ".venv", "venv", "__pycache__", ".pytest_cache", ".azure", ".vscode", "relay"}
    files = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or skip.intersection(path.relative_to(ROOT).parts):
            continue
        if path.name == "environment.json" or path.suffix.lower() in {".png", ".pyc", ".abf"}:
            continue
        files.append(path)
    return files


def test_no_environment_identifiers_are_committed() -> None:
    """The repository is public; real identifiers belong in deployment/environment.json."""
    offenders = []
    for path in committed_text_files():
        text = path.read_text(encoding="utf-8", errors="ignore")
        for label, pattern in ENVIRONMENT_IDENTIFIERS.items():
            for match in pattern.findall(text):
                offenders.append(f"{path.relative_to(ROOT)}: {label} {match}")

    assert offenders == []


def test_environment_file_is_ignored_and_the_example_covers_every_script() -> None:
    ignored = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
    assert "deployment/environment.json" in ignored

    example = json.loads((ROOT / "deployment" / "environment.example.json").read_text(encoding="utf-8"))

    # Invoke-OnJumpbox.ps1 fills mandatory parameters by name from environment.json, so a
    # parameter with no matching key would make run-command fail on the jumpbox.
    scripts = list((ROOT / "deployment").glob("jumpbox-*.ps1")) + [ROOT / "deployment" / "create-genie-space.ps1"]
    mandatory = re.compile(r"\[Parameter\(Mandatory\)\](?:\s*\[[^\]]*\])*\s*\$(\w+)")
    for script in scripts:
        for name in mandatory.findall(script.read_text(encoding="utf-8")):
            assert name in example, f"{script.name} needs {name}"


def test_power_bi_connection_is_rendered_from_the_environment() -> None:
    expressions = (ROOT / "powerbi" / "FoodAnalytics.SemanticModel" / "definition" / "expressions.tmdl").read_text(encoding="utf-8")
    assert '"<databricks-host>"' in expressions
    assert "<sql-warehouse-id>" in expressions

    push = (ROOT / "deployment" / "push-powerbi-to-jumpbox.ps1").read_text(encoding="utf-8")
    assert "'<databricks-host>'" in push
    assert "'<sql-warehouse-id>'" in push
