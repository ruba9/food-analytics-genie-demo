"""Export and restore Prompt and container-based Hosted Agent definitions.

The project Agent API is the supported source for Prompt Agent definitions. In
standard setup, those definitions are backed by the capability host's Cosmos DB
connection, but reading or rewriting the Cosmos containers directly is not a
supported recovery mechanism.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

import httpx
from azure.ai.projects import AIProjectClient
from azure.core.exceptions import HttpResponseError
from azure.identity import DefaultAzureCredential


SCHEMA_VERSION = 1
UNRESTORABLE_VERSION_STATES = {"deleting", "deleted"}
NONREUSABLE_VERSION_STATES = {"failed", "deleting", "deleted"}
WRITABLE_VERSION_FIELDS = (
    "definition",
    "metadata",
    "description",
    "blueprint_reference",
    "draft",
)
WRITABLE_ENDPOINT_FIELDS = (
    "version_selector",
    "protocol_configuration",
    "authorization_schemes",
)
WRITABLE_AGENT_CARD_FIELDS = (
    "version",
    "description",
    "skills",
)
ASSET_REFERENCE_KEYS = {
    "file_id",
    "file_ids",
    "vector_store_id",
    "vector_store_ids",
}


class RecoveryError(RuntimeError):
    """Raised when the recovery manifest can't be replayed safely."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def to_dict(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, dict):
        return {str(key): to_dict(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [to_dict(item) for item in value]
    if hasattr(value, "as_dict"):
        return to_dict(value.as_dict())
    return dict(value)


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def fingerprint(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def status_text(value: Any) -> str:
    return str(getattr(value, "value", value) or "").lower()


def version_sort_key(value: str) -> tuple[int, int | str]:
    return (0, int(value)) if str(value).isdigit() else (1, str(value))


def write_private_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2), encoding="utf-8")
    try:
        os.chmod(temporary, 0o600)
    except OSError:
        pass
    temporary.replace(path)


def create_body(raw_version: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(raw_version.get("definition"), dict):
        raise RecoveryError("Agent version is missing a materialized definition.")
    body = {
        field: copy.deepcopy(raw_version[field])
        for field in WRITABLE_VERSION_FIELDS
        if field in raw_version and raw_version[field] is not None
    }
    if not body.get("draft"):
        body.pop("draft", None)
    return body


def endpoint_body(raw_agent: dict[str, Any]) -> dict[str, Any] | None:
    endpoint = raw_agent.get("agent_endpoint")
    agent_card = raw_agent.get("agent_card")
    body: dict[str, Any] = {}
    if isinstance(endpoint, dict):
        writable = {
            field: copy.deepcopy(endpoint[field])
            for field in WRITABLE_ENDPOINT_FIELDS
            if field in endpoint and endpoint[field] is not None
        }
        if writable:
            body["agent_endpoint"] = writable
    if isinstance(agent_card, dict):
        writable_card = {
            field: copy.deepcopy(agent_card[field])
            for field in WRITABLE_AGENT_CARD_FIELDS
            if field in agent_card and agent_card[field] is not None
        }
        if writable_card:
            body["agent_card"] = writable_card
    return body or None


def routed_versions(raw_agent: dict[str, Any]) -> set[str]:
    endpoint = raw_agent.get("agent_endpoint") or {}
    selector = endpoint.get("version_selector") or {}
    rules = selector.get("version_selection_rules") or []
    return {
        str(rule["agent_version"])
        for rule in rules
        if isinstance(rule, dict) and rule.get("agent_version") is not None
    }


def latest_version(raw_agent: dict[str, Any]) -> str | None:
    versions = raw_agent.get("versions") or {}
    latest = versions.get("latest") or {}
    version = latest.get("version")
    return str(version) if version is not None else None


def selected_version_ids(
    raw_agent: dict[str, Any],
    raw_versions: list[dict[str, Any]],
    restore_all_versions: bool,
) -> set[str]:
    available = {
        str(version["version"])
        for version in raw_versions
        if status_text(version.get("status")) not in UNRESTORABLE_VERSION_STATES
    }
    routed = routed_versions(raw_agent)
    missing_routed = routed - available
    if missing_routed:
        raise RecoveryError(
            "Agent endpoint routes to unavailable version(s): "
            f"{', '.join(sorted(missing_routed, key=version_sort_key))}."
        )
    latest = latest_version(raw_agent)
    if latest and latest not in available:
        raise RecoveryError(
            f"Agent latest version {latest} isn't available for export."
        )
    if restore_all_versions:
        return available
    selected = set(routed)
    if latest:
        selected.add(latest)
    if not selected and available:
        selected.add(max(available, key=version_sort_key))
    return selected & available


def find_external_asset_warnings(value: Any, path: str = "definition") -> list[str]:
    warnings: list[str] = []
    if isinstance(value, dict):
        for key, item in value.items():
            child_path = f"{path}.{key}"
            if key in ASSET_REFERENCE_KEYS and item:
                warnings.append(
                    f"{child_path} references file/vector assets; preserve and redeploy "
                    "those assets from their durable source."
                )
            warnings.extend(find_external_asset_warnings(item, child_path))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            warnings.extend(find_external_asset_warnings(item, f"{path}[{index}]"))
    return warnings


def analyze_version(
    raw_version: dict[str, Any],
    selected: bool,
    skip_unsupported_agents: bool,
) -> dict[str, Any]:
    body = create_body(raw_version)
    definition = body["definition"]
    kind = str(definition.get("kind", "")).lower()
    supported = kind == "prompt" or (
        kind == "hosted"
        and isinstance(definition.get("container_configuration"), dict)
        and bool(definition["container_configuration"].get("image"))
    )
    reason = None
    source = None
    if kind == "prompt":
        source = "cosmos-backed-foundry-api-export"
    elif kind == "hosted" and supported:
        source = "container-image"
    elif kind == "hosted":
        reason = (
            "Hosted version doesn't contain container_configuration.image. "
            "Redeploy it from its original code or agent manifest."
        )
    else:
        reason = (
            f"Agent kind '{kind or 'unknown'}' isn't supported by this recovery script."
        )
    if selected and not supported and not skip_unsupported_agents:
        raise RecoveryError(reason or "Selected agent version is unsupported.")
    return {
        "original_version": str(raw_version["version"]),
        "original_status": status_text(raw_version.get("status")),
        "selected_by_default": selected,
        "supported": supported,
        "unsupported_reason": reason,
        "recovery_source": source,
        "create_body": body if supported else None,
        "create_body_sha256": fingerprint(body) if supported else None,
        "original_identity_principal_id": (
            (raw_version.get("instance_identity") or {}).get("principal_id")
        ),
        "external_asset_warnings": find_external_asset_warnings(definition),
    }


def remap_endpoint(
    body: dict[str, Any] | None,
    version_mapping: dict[str, str],
) -> dict[str, Any] | None:
    if not body:
        return None
    result = copy.deepcopy(body)
    endpoint = result.get("agent_endpoint") or {}
    selector = endpoint.get("version_selector") or {}
    rules = selector.get("version_selection_rules") or []
    for rule in rules:
        old_version = str(rule.get("agent_version", ""))
        if old_version not in version_mapping:
            raise RecoveryError(
                f"Endpoint routes to version {old_version}, but that version wasn't restored."
            )
        rule["agent_version"] = version_mapping[old_version]
    return result


class RoleAssignments:
    def __init__(self, credential: DefaultAzureCredential):
        self.credential = credential
        self.client = httpx.Client(timeout=60, follow_redirects=False)

    def close(self) -> None:
        self.client.close()

    def _headers(self) -> dict[str, str]:
        token = self.credential.get_token("https://management.azure.com/.default")
        return {
            "Authorization": f"Bearer {token.token}",
            "Content-Type": "application/json",
        }

    def list_for_principal(
        self, principal_id: str, subscription_ids: Iterable[str]
    ) -> list[dict[str, Any]]:
        assignments: dict[tuple[str, str, str | None], dict[str, Any]] = {}
        for subscription_id in subscription_ids:
            url = (
                "https://management.azure.com/subscriptions/"
                f"{subscription_id}/providers/Microsoft.Authorization/roleAssignments"
            )
            params = {
                "api-version": "2022-04-01",
                "$filter": f"principalId eq '{principal_id}'",
            }
            while url:
                response = self.client.get(url, params=params, headers=self._headers())
                response.raise_for_status()
                page = response.json()
                for item in page.get("value", []):
                    properties = item.get("properties") or {}
                    if (
                        properties.get("principalId", "").lower()
                        != principal_id.lower()
                    ):
                        continue
                    value = {
                        "scope": properties["scope"],
                        "role_definition_id": properties["roleDefinitionId"],
                        "condition": properties.get("condition"),
                        "condition_version": properties.get("conditionVersion"),
                        "description": properties.get("description"),
                    }
                    key = (
                        value["scope"].lower(),
                        value["role_definition_id"].lower(),
                        value["condition"],
                    )
                    assignments[key] = value
                url = page.get("nextLink")
                params = None
        return sorted(
            assignments.values(),
            key=lambda item: (
                item["scope"].lower(),
                item["role_definition_id"].lower(),
            ),
        )

    def create_for_principal(
        self, assignment: dict[str, Any], principal_id: str
    ) -> str:
        stable = "|".join(
            (
                assignment["scope"].lower(),
                principal_id.lower(),
                assignment["role_definition_id"].lower(),
                assignment.get("condition") or "",
            )
        )
        assignment_id = str(uuid.uuid5(uuid.NAMESPACE_URL, stable))
        url = (
            "https://management.azure.com"
            f"{assignment['scope']}/providers/Microsoft.Authorization/"
            f"roleAssignments/{assignment_id}"
        )
        properties: dict[str, Any] = {
            "principalId": principal_id,
            "principalType": "ServicePrincipal",
            "roleDefinitionId": assignment["role_definition_id"],
        }
        for source, target in (
            ("condition", "condition"),
            ("condition_version", "conditionVersion"),
            ("description", "description"),
        ):
            if assignment.get(source):
                properties[target] = assignment[source]
        response = self.client.put(
            url,
            params={"api-version": "2022-04-01"},
            headers=self._headers(),
            json={"properties": properties},
        )
        if response.status_code not in (200, 201):
            response.raise_for_status()
        return response.json()["id"]


def wait_for_version(
    project: AIProjectClient,
    agent_name: str,
    agent_version: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    while True:
        current = project.agents.get_version(agent_name, agent_version)
        raw = to_dict(current)
        status = status_text(raw.get("status"))
        if status in ("", "active"):
            return raw
        if status == "failed":
            raise RecoveryError(
                f"Agent {agent_name}:{agent_version} failed provisioning: "
                f"{canonical_json(raw.get('error'))}"
            )
        if status in ("deleting", "deleted"):
            raise RecoveryError(
                f"Agent {agent_name}:{agent_version} entered unexpected state {status}."
            )
        if time.monotonic() >= deadline:
            raise RecoveryError(
                f"Timed out waiting for {agent_name}:{agent_version}; last state: {status}."
            )
        time.sleep(10)


def export_manifest(args: argparse.Namespace) -> dict[str, Any]:
    credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    role_client = None if args.skip_role_assignments else RoleAssignments(credential)
    identities: dict[str, dict[str, Any]] = {}
    manifest: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "captured_at_utc": utc_now(),
        "project_endpoint": args.project_endpoint.rstrip("/"),
        "agent_api_version": "v1",
        "role_assignment_subscription_ids": args.role_subscription_id,
        "agents": [],
        "warnings": [
            "This manifest can contain Prompt Agent tool/authentication configuration "
            "and Hosted Agent environment-variable values. Protect it as a sensitive "
            "operational artifact and don't commit it.",
            "Prompt Agent definitions are exported through the supported Foundry API. "
            "The script never reads or writes Agent Service Cosmos containers directly.",
        ],
    }
    try:
        with AIProjectClient(
            endpoint=manifest["project_endpoint"],
            credential=credential,
        ) as project:
            for agent in project.agents.list():
                raw_agent = to_dict(agent)
                raw_versions = [
                    to_dict(version)
                    for version in project.agents.list_versions(
                        agent_name=raw_agent["name"], include_drafts=True
                    )
                ]
                raw_versions.sort(
                    key=lambda item: version_sort_key(str(item["version"]))
                )
                selected_ids = selected_version_ids(
                    raw_agent, raw_versions, args.restore_all_versions
                )
                versions = [
                    analyze_version(
                        raw_version,
                        str(raw_version["version"]) in selected_ids,
                        args.skip_unsupported_agents,
                    )
                    for raw_version in raw_versions
                ]
                manifest["agents"].append(
                    {
                        "name": raw_agent["name"],
                        "original_id": raw_agent.get("id"),
                        "state": status_text(raw_agent.get("state")),
                        "endpoint_update_body": endpoint_body(raw_agent),
                        "versions": versions,
                    }
                )
                for version in versions:
                    principal_id = version["original_identity_principal_id"]
                    if not principal_id or principal_id in identities:
                        continue
                    assignments = (
                        []
                        if role_client is None
                        else role_client.list_for_principal(
                            principal_id, args.role_subscription_id
                        )
                    )
                    identities[principal_id] = {
                        "role_assignments": assignments,
                    }
        manifest["agents"].sort(key=lambda item: item["name"])
        manifest["identity_role_assignments"] = identities
        manifest["state"] = "exported"
        write_private_json(args.output, manifest)
        return manifest
    finally:
        if role_client is not None:
            role_client.close()
        credential.close()


def existing_versions(
    project: AIProjectClient, agent_name: str
) -> list[dict[str, Any]]:
    try:
        return [
            to_dict(version)
            for version in project.agents.list_versions(
                agent_name=agent_name, include_drafts=True
            )
        ]
    except HttpResponseError as exc:
        if exc.status_code == 404:
            return []
        raise


def reusable_version_pools(
    live_versions: list[dict[str, Any]],
) -> dict[str, list[dict[str, Any]]]:
    pools: dict[str, list[dict[str, Any]]] = {}
    for version in sorted(
        live_versions, key=lambda item: version_sort_key(str(item["version"]))
    ):
        if status_text(version.get("status")) in NONREUSABLE_VERSION_STATES:
            continue
        body_hash = fingerprint(create_body(version))
        pools.setdefault(body_hash, []).append(version)
    return pools


def restore_manifest(args: argparse.Namespace) -> dict[str, Any]:
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    validate_manifest(manifest)
    expected_endpoint = manifest["project_endpoint"].rstrip("/")
    actual_endpoint = args.project_endpoint.rstrip("/")
    if actual_endpoint != expected_endpoint and not args.allow_project_change:
        raise RecoveryError(
            "The manifest belongs to a different project endpoint. "
            "Use --allow-project-change only for an intentional recovery target."
        )
    restore_plan = {
        agent["name"]: versions_for_restore(agent, args.restore_all_versions)
        for agent in manifest["agents"]
    }
    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "started_at_utc": utc_now(),
        "state": "restoring",
        "project_endpoint": actual_endpoint,
        "manifest": str(args.manifest),
        "agents": [],
        "identity_mappings": [],
        "role_assignments": [],
    }
    write_private_json(args.output, report)
    credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    role_client = None if args.skip_role_assignments else RoleAssignments(credential)
    try:
        with AIProjectClient(
            endpoint=actual_endpoint, credential=credential
        ) as project:
            for agent in manifest["agents"]:
                agent_report = {
                    "name": agent["name"],
                    "versions": [],
                    "endpoint": "not-set",
                    "state": "not-set",
                }
                report["agents"].append(agent_report)
                live_versions = existing_versions(project, agent["name"])
                live_by_hash = reusable_version_pools(live_versions)
                selected = restore_plan[agent["name"]]
                selected.sort(
                    key=lambda item: version_sort_key(item["original_version"])
                )
                version_mapping: dict[str, str] = {}
                desired_state = agent["state"]
                agent_disabled = False

                def disable_agent_for_restore(
                    allow_transient_failure: bool = False,
                ) -> None:
                    nonlocal agent_disabled
                    if agent_disabled or args.dry_run:
                        return
                    try:
                        project.agents.disable(agent_name=agent["name"])
                    except HttpResponseError as exc:
                        if allow_transient_failure and exc.status_code in (404, 409):
                            agent_report["state"] = "disable-pending"
                            return
                        raise RecoveryError(
                            f"Couldn't temporarily disable agent {agent['name']}: "
                            f"{exc}"
                        ) from exc
                    agent_disabled = True
                    agent_report["state"] = "temporarily-disabled"

                for version in selected:
                    body = version["create_body"]
                    body_hash = version["create_body_sha256"]
                    matching_versions = live_by_hash.get(body_hash) or []
                    if matching_versions:
                        current = matching_versions.pop(0)
                        disable_agent_for_restore(allow_transient_failure=True)
                        if not args.dry_run and status_text(
                            current.get("status")
                        ) not in ("", "active"):
                            current = wait_for_version(
                                project,
                                agent["name"],
                                str(current["version"]),
                                args.version_timeout_seconds,
                            )
                        action = "reused"
                    elif args.dry_run:
                        current = {
                            "version": f"dry-run-{version['original_version']}",
                            "status": "planned",
                            "instance_identity": None,
                        }
                        action = "planned"
                    else:
                        created = project.agents.create_version(
                            agent_name=agent["name"], body=body
                        )
                        disable_agent_for_restore(allow_transient_failure=True)
                        current = wait_for_version(
                            project,
                            agent["name"],
                            str(created.version),
                            args.version_timeout_seconds,
                        )
                        action = "created"
                    disable_agent_for_restore()
                    new_version = str(current["version"])
                    version_mapping[version["original_version"]] = new_version
                    new_principal = (current.get("instance_identity") or {}).get(
                        "principal_id"
                    )
                    old_principal = version.get("original_identity_principal_id")
                    agent_report["versions"].append(
                        {
                            "original_version": version["original_version"],
                            "restored_version": new_version,
                            "kind": version["create_body"]["definition"]["kind"],
                            "action": action,
                            "status": status_text(current.get("status")),
                            "recovery_source": version["recovery_source"],
                            "external_asset_warnings": version[
                                "external_asset_warnings"
                            ],
                        }
                    )
                    if old_principal and new_principal:
                        report["identity_mappings"].append(
                            {
                                "agent": agent["name"],
                                "original_version": version["original_version"],
                                "restored_version": new_version,
                                "old_principal_id": old_principal,
                                "new_principal_id": new_principal,
                            }
                        )
                        assignments = (
                            manifest.get("identity_role_assignments", {})
                            .get(old_principal, {})
                            .get("role_assignments", [])
                        )
                        for assignment in assignments:
                            if args.dry_run:
                                assignment_id = "planned"
                            elif role_client is None:
                                assignment_id = "skipped"
                            else:
                                assignment_id = role_client.create_for_principal(
                                    assignment, new_principal
                                )
                            report["role_assignments"].append(
                                {
                                    "agent": agent["name"],
                                    "restored_version": new_version,
                                    "new_principal_id": new_principal,
                                    "scope": assignment["scope"],
                                    "role_definition_id": assignment[
                                        "role_definition_id"
                                    ],
                                    "result": assignment_id,
                                }
                            )
                    write_private_json(args.output, report)
                update = remap_endpoint(
                    agent.get("endpoint_update_body"), version_mapping
                )
                if update:
                    if not args.dry_run:
                        project.agents.update_details(
                            agent_name=agent["name"], body=update
                        )
                    agent_report["endpoint"] = "planned" if args.dry_run else "restored"
                    agent_report["endpoint_update_sha256"] = fingerprint(update)
                if args.dry_run:
                    agent_report["state"] = f"planned-{desired_state}"
                elif desired_state == "enabled":
                    project.agents.enable(agent_name=agent["name"])
                    agent_report["state"] = "enabled"
                else:
                    disable_agent_for_restore()
                    agent_report["state"] = "disabled"
                write_private_json(args.output, report)
        report["state"] = "planned" if args.dry_run else "completed"
        report["completed_at_utc"] = utc_now()
        write_private_json(args.output, report)
        return report
    except Exception as exc:
        report["state"] = "error"
        report["completed_at_utc"] = utc_now()
        report["error"] = {"type": type(exc).__name__, "message": str(exc)}
        write_private_json(args.output, report)
        raise
    finally:
        if role_client is not None:
            role_client.close()
        credential.close()


def validate_manifest(manifest: dict[str, Any]) -> None:
    if manifest.get("schema_version") != SCHEMA_VERSION:
        raise RecoveryError(
            f"Unsupported manifest schema: {manifest.get('schema_version')!r}."
        )
    if not isinstance(manifest.get("project_endpoint"), str):
        raise RecoveryError("Manifest is missing project_endpoint.")
    if manifest.get("state") != "exported":
        raise RecoveryError("Manifest isn't in the exported state.")
    if not isinstance(manifest.get("agents"), list):
        raise RecoveryError("Manifest is missing the agents array.")
    identities = manifest.get("identity_role_assignments")
    if not isinstance(identities, dict):
        raise RecoveryError("Manifest is missing identity_role_assignments.")
    for principal_id, identity in identities.items():
        if not isinstance(principal_id, str) or not principal_id:
            raise RecoveryError("Manifest contains an invalid identity principal ID.")
        if not isinstance(identity, dict) or not isinstance(
            identity.get("role_assignments"), list
        ):
            raise RecoveryError(
                f"Manifest identity {principal_id} has invalid role assignments."
            )
        for assignment in identity["role_assignments"]:
            if (
                not isinstance(assignment, dict)
                or not isinstance(assignment.get("scope"), str)
                or not assignment["scope"].startswith("/")
                or not isinstance(assignment.get("role_definition_id"), str)
                or not assignment["role_definition_id"].startswith("/")
            ):
                raise RecoveryError(
                    f"Manifest identity {principal_id} has an invalid role assignment."
                )
    names: set[str] = set()
    for agent in manifest["agents"]:
        if not isinstance(agent, dict):
            raise RecoveryError("Manifest contains an invalid agent record.")
        name = agent.get("name")
        if not isinstance(name, str) or not name:
            raise RecoveryError("Manifest contains an agent without a name.")
        if name in names:
            raise RecoveryError(f"Manifest contains duplicate agent name: {name}.")
        names.add(name)
        if agent.get("state") not in ("enabled", "disabled"):
            raise RecoveryError(
                f"Agent {name} has invalid operational state {agent.get('state')!r}."
            )
        versions = agent.get("versions")
        if not isinstance(versions, list):
            raise RecoveryError(f"Agent {name} is missing the versions array.")
        if not versions:
            raise RecoveryError(f"Agent {name} doesn't contain any versions.")
        version_ids: set[str] = set()
        has_selected_version = False
        for version in versions:
            if not isinstance(version, dict):
                raise RecoveryError(f"Agent {name} contains an invalid version record.")
            original_version = version.get("original_version")
            if not isinstance(original_version, str) or not original_version:
                raise RecoveryError(f"Agent {name} contains a version without an ID.")
            if original_version in version_ids:
                raise RecoveryError(
                    f"Agent {name} contains duplicate version {original_version}."
                )
            version_ids.add(original_version)
            if not isinstance(version.get("supported"), bool):
                raise RecoveryError(
                    f"Agent {name}:{original_version} is missing supported state."
                )
            if not isinstance(version.get("selected_by_default"), bool):
                raise RecoveryError(
                    f"Agent {name}:{original_version} is missing selection state."
                )
            has_selected_version = (
                has_selected_version or version["selected_by_default"]
            )
            if version.get("supported"):
                body = version.get("create_body")
                if not isinstance(body, dict):
                    raise RecoveryError(
                        f"Agent {name}:{original_version} is missing its create body."
                    )
                if fingerprint(body) != version.get("create_body_sha256"):
                    raise RecoveryError(
                        f"Agent {name}:{original_version} definition hash mismatch."
                    )
            principal_id = version.get("original_identity_principal_id")
            if principal_id and principal_id not in identities:
                raise RecoveryError(
                    f"Agent {name}:{original_version} identity is missing its "
                    "role-assignment record."
                )
        if not has_selected_version:
            raise RecoveryError(f"Agent {name} doesn't select a version for restore.")
        endpoint_update = agent.get("endpoint_update_body")
        if endpoint_update is not None and not isinstance(endpoint_update, dict):
            raise RecoveryError(f"Agent {name} contains an invalid endpoint update.")
        missing_routes = routed_versions(endpoint_update or {}) - version_ids
        if missing_routes:
            raise RecoveryError(
                f"Agent {name} endpoint references version(s) absent from the manifest: "
                f"{', '.join(sorted(missing_routes, key=version_sort_key))}."
            )


def versions_for_restore(
    agent: dict[str, Any], restore_all_versions: bool
) -> list[dict[str, Any]]:
    selected = [
        version
        for version in agent["versions"]
        if restore_all_versions or version["selected_by_default"]
    ]
    unsupported = [
        version["original_version"] for version in selected if not version["supported"]
    ]
    if unsupported:
        raise RecoveryError(
            f"Agent {agent['name']} selected version(s) can't be restored: "
            f"{', '.join(sorted(unsupported, key=version_sort_key))}."
        )
    return selected


def summary(manifest: dict[str, Any], path: Path) -> dict[str, Any]:
    versions = [
        version for agent in manifest["agents"] for version in agent.get("versions", [])
    ]
    return {
        "state": manifest["state"],
        "manifest": str(path),
        "agent_count": len(manifest["agents"]),
        "prompt_versions": sum(
            1
            for version in versions
            if (version.get("create_body") or {}).get("definition", {}).get("kind")
            == "prompt"
        ),
        "container_hosted_versions": sum(
            1
            for version in versions
            if (version.get("create_body") or {}).get("definition", {}).get("kind")
            == "hosted"
        ),
        "selected_versions": sum(
            1 for version in versions if version.get("selected_by_default")
        ),
        "unsupported_versions": sum(
            1 for version in versions if not version.get("supported")
        ),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_parser = subparsers.add_parser("export")
    export_parser.add_argument("--project-endpoint", required=True)
    export_parser.add_argument("--output", required=True, type=Path)
    export_parser.add_argument("--role-subscription-id", action="append", required=True)
    export_parser.add_argument("--restore-all-versions", action="store_true")
    export_parser.add_argument("--skip-role-assignments", action="store_true")
    export_parser.add_argument("--skip-unsupported-agents", action="store_true")

    restore_parser = subparsers.add_parser("restore")
    restore_parser.add_argument("--project-endpoint", required=True)
    restore_parser.add_argument("--manifest", required=True, type=Path)
    restore_parser.add_argument("--output", required=True, type=Path)
    restore_parser.add_argument("--restore-all-versions", action="store_true")
    restore_parser.add_argument("--skip-role-assignments", action="store_true")
    restore_parser.add_argument("--allow-project-change", action="store_true")
    restore_parser.add_argument("--dry-run", action="store_true")
    restore_parser.add_argument("--version-timeout-seconds", type=int, default=1800)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--manifest", required=True, type=Path)
    validate_parser.add_argument("--restore-all-versions", action="store_true")
    validate_parser.add_argument("--require-recoverable", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.command == "export":
        result = export_manifest(args)
        print(json.dumps(summary(result, args.output)))
    elif args.command == "restore":
        result = restore_manifest(args)
        print(
            json.dumps(
                {
                    "state": result["state"],
                    "report": str(args.output),
                    "agent_count": len(result["agents"]),
                    "restored_version_count": sum(
                        len(agent["versions"]) for agent in result["agents"]
                    ),
                    "identity_mapping_count": len(result["identity_mappings"]),
                }
            )
        )
    else:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        validate_manifest(manifest)
        if args.require_recoverable:
            for agent in manifest["agents"]:
                versions_for_restore(agent, args.restore_all_versions)
        print(json.dumps(summary(manifest, args.manifest)))


if __name__ == "__main__":
    try:
        main()
    except RecoveryError as exc:
        raise SystemExit(f"Recovery error: {exc}") from None
