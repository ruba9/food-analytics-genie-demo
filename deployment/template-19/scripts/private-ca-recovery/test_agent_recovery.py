import copy
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import agent_recovery


class AgentRecoveryTests(unittest.TestCase):
    def prompt_version(self, version="1"):
        return {
            "id": f"agent:prompt:{version}",
            "name": "prompt-agent",
            "version": version,
            "status": "active",
            "created_at": "2026-09-14T00:00:00Z",
            "metadata": {"owner": "sample"},
            "definition": {
                "kind": "prompt",
                "model": "sample-model",
                "instructions": "Answer briefly.",
            },
        }

    def hosted_version(self, version="1"):
        return {
            "id": f"agent:hosted:{version}",
            "name": "hosted-agent",
            "version": version,
            "status": "active",
            "metadata": {},
            "definition": {
                "kind": "hosted",
                "cpu": "1",
                "memory": "2Gi",
                "container_configuration": {
                    "image": "sample.azurecr.io/agent@sha256:abc"
                },
                "protocol_versions": [{"protocol": "responses", "version": "2.0.0"}],
            },
            "instance_identity": {"principal_id": "old-principal"},
        }

    def test_role_assignment_client_uses_bearer_token(self):
        class Credential:
            def get_token(self, _scope):
                return type("Token", (), {"token": "sentinel"})()

        client = agent_recovery.RoleAssignments(Credential())
        try:
            self.assertEqual(
                client._headers()["Authorization"],
                "Bearer sentinel",
            )
        finally:
            client.close()

    def test_selected_versions_include_latest_and_endpoint_route(self):
        agent = {
            "versions": {"latest": {"version": "3"}},
            "agent_endpoint": {
                "version_selector": {
                    "version_selection_rules": [
                        {"type": "FixedRatio", "agent_version": "2"}
                    ]
                }
            },
        }
        versions = [
            self.prompt_version("1"),
            self.prompt_version("2"),
            self.prompt_version("3"),
        ]
        self.assertEqual(
            agent_recovery.selected_version_ids(agent, versions, False),
            {"2", "3"},
        )
        self.assertEqual(
            agent_recovery.selected_version_ids(agent, versions, True),
            {"1", "2", "3"},
        )

    def test_unavailable_routed_version_fails_export_preflight(self):
        agent = {
            "versions": {"latest": {"version": "1"}},
            "agent_endpoint": {
                "version_selector": {
                    "version_selection_rules": [{"agent_version": "9"}]
                }
            },
        }
        with self.assertRaisesRegex(
            agent_recovery.RecoveryError, "unavailable version"
        ):
            agent_recovery.selected_version_ids(
                agent, [self.prompt_version("1")], False
            )

    def test_prompt_version_uses_supported_cosmos_backed_export(self):
        result = agent_recovery.analyze_version(
            self.prompt_version(), selected=True, skip_unsupported_agents=False
        )
        self.assertTrue(result["supported"])
        self.assertEqual(result["recovery_source"], "cosmos-backed-foundry-api-export")
        self.assertNotIn("id", result["create_body"])
        self.assertNotIn("status", result["create_body"])

    def test_hosted_version_requires_container_image(self):
        result = agent_recovery.analyze_version(
            self.hosted_version(), selected=True, skip_unsupported_agents=False
        )
        self.assertTrue(result["supported"])
        self.assertEqual(result["recovery_source"], "container-image")
        code_hosted = self.hosted_version()
        code_hosted["definition"].pop("container_configuration")
        code_hosted["definition"]["code_configuration"] = {
            "runtime": "python",
            "entry_point": "main.py",
        }
        with self.assertRaisesRegex(agent_recovery.RecoveryError, "original code"):
            agent_recovery.analyze_version(
                code_hosted, selected=True, skip_unsupported_agents=False
            )

    def test_agent_card_export_keeps_only_writable_fields(self):
        body = agent_recovery.endpoint_body(
            {
                "agent_card": {
                    "version": "1.0",
                    "description": "Recovery card",
                    "skills": [{"id": "recover", "name": "Recover"}],
                    "service_generated_field": "omit",
                }
            }
        )
        self.assertEqual(
            body["agent_card"],
            {
                "version": "1.0",
                "description": "Recovery card",
                "skills": [{"id": "recover", "name": "Recover"}],
            },
        )

    def test_endpoint_versions_are_remapped_without_mutating_manifest(self):
        body = {
            "agent_endpoint": {
                "version_selector": {
                    "version_selection_rules": [
                        {
                            "type": "FixedRatio",
                            "agent_version": "4",
                            "traffic_percentage": 100,
                        }
                    ]
                },
                "protocol_configuration": {"responses": {}},
            }
        }
        original = copy.deepcopy(body)
        remapped = agent_recovery.remap_endpoint(body, {"4": "1"})
        self.assertEqual(
            remapped["agent_endpoint"]["version_selector"]["version_selection_rules"][
                0
            ]["agent_version"],
            "1",
        )
        self.assertEqual(body, original)

    def test_missing_routed_version_is_an_explicit_error(self):
        body = {
            "agent_endpoint": {
                "version_selector": {
                    "version_selection_rules": [{"agent_version": "9"}]
                }
            }
        }
        with self.assertRaisesRegex(agent_recovery.RecoveryError, "wasn't restored"):
            agent_recovery.remap_endpoint(body, {"1": "1"})

    def test_reusable_versions_preserve_identical_version_cardinality(self):
        version_one = self.prompt_version("1")
        version_two = self.prompt_version("2")
        pools = agent_recovery.reusable_version_pools([version_two, version_one])
        body_hash = agent_recovery.fingerprint(agent_recovery.create_body(version_one))
        self.assertEqual(
            [version["version"] for version in pools[body_hash]],
            ["1", "2"],
        )

    def test_failed_versions_are_not_reused(self):
        failed = self.prompt_version("1")
        failed["status"] = "failed"
        self.assertEqual(agent_recovery.reusable_version_pools([failed]), {})

    def test_file_and_vector_references_are_reported(self):
        warnings = agent_recovery.find_external_asset_warnings(
            {
                "tools": [
                    {
                        "type": "file_search",
                        "file_ids": ["file-1"],
                        "vector_store_ids": ["vs-1"],
                    }
                ]
            }
        )
        self.assertEqual(len(warnings), 2)

    def test_manifest_hash_validation_detects_edits(self):
        version = agent_recovery.analyze_version(
            self.prompt_version(), selected=True, skip_unsupported_agents=False
        )
        manifest = {
            "schema_version": 1,
            "state": "exported",
            "project_endpoint": "https://example.test/api/projects/project",
            "identity_role_assignments": {},
            "agents": [
                {
                    "name": "prompt-agent",
                    "state": "enabled",
                    "versions": [version],
                }
            ],
        }
        agent_recovery.validate_manifest(manifest)
        manifest["agents"][0]["versions"][0]["create_body"]["definition"][
            "instructions"
        ] = "Changed after export."
        with self.assertRaisesRegex(agent_recovery.RecoveryError, "hash mismatch"):
            agent_recovery.validate_manifest(manifest)

    def test_restore_preflight_rejects_selected_unsupported_version(self):
        unsupported = agent_recovery.analyze_version(
            {
                **self.hosted_version(),
                "definition": {
                    "kind": "hosted",
                    "cpu": "1",
                    "memory": "2Gi",
                    "code_configuration": {
                        "runtime": "python",
                        "entry_point": "main.py",
                    },
                },
            },
            selected=True,
            skip_unsupported_agents=True,
        )
        agent = {"name": "hosted-agent", "versions": [unsupported]}
        with self.assertRaisesRegex(agent_recovery.RecoveryError, "can't be restored"):
            agent_recovery.versions_for_restore(agent, False)

    def test_restore_preflight_allows_unselected_unsupported_history(self):
        supported = agent_recovery.analyze_version(
            self.hosted_version("2"),
            selected=True,
            skip_unsupported_agents=False,
        )
        unsupported_raw = self.hosted_version("1")
        unsupported_raw["definition"].pop("container_configuration")
        unsupported_raw["definition"]["code_configuration"] = {
            "runtime": "python",
            "entry_point": "main.py",
        }
        unsupported = agent_recovery.analyze_version(
            unsupported_raw,
            selected=False,
            skip_unsupported_agents=True,
        )
        agent = {
            "name": "hosted-agent",
            "versions": [unsupported, supported],
        }
        self.assertEqual(
            agent_recovery.versions_for_restore(agent, False),
            [supported],
        )

    def test_restore_temporarily_disables_then_reenables_agent(self):
        version = agent_recovery.analyze_version(
            self.prompt_version(),
            selected=True,
            skip_unsupported_agents=False,
        )
        manifest = {
            "schema_version": 1,
            "state": "exported",
            "project_endpoint": "https://example.test/api/projects/project",
            "identity_role_assignments": {},
            "agents": [
                {
                    "name": "prompt-agent",
                    "state": "enabled",
                    "endpoint_update_body": None,
                    "versions": [version],
                }
            ],
        }
        calls = []

        class Agents:
            def list_versions(self, **_kwargs):
                calls.append("list")
                return []

            def create_version(self, **_kwargs):
                calls.append("create")
                return SimpleNamespace(version="1")

            def disable(self, **_kwargs):
                calls.append("disable")

            def get_version(self, *_args, **_kwargs):
                calls.append("get")
                return {
                    "version": "1",
                    "status": "active",
                    "instance_identity": None,
                }

            def enable(self, **_kwargs):
                calls.append("enable")

        class Project:
            agents = Agents()

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

        class Credential:
            def close(self):
                pass

        with tempfile.TemporaryDirectory() as directory:
            manifest_path = Path(directory) / "agents.json"
            output_path = Path(directory) / "report.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            args = SimpleNamespace(
                manifest=manifest_path,
                project_endpoint=manifest["project_endpoint"],
                allow_project_change=False,
                restore_all_versions=False,
                skip_role_assignments=True,
                output=output_path,
                dry_run=False,
                version_timeout_seconds=1,
            )
            with (
                patch.object(
                    agent_recovery,
                    "DefaultAzureCredential",
                    return_value=Credential(),
                ),
                patch.object(
                    agent_recovery,
                    "AIProjectClient",
                    return_value=Project(),
                ),
            ):
                report = agent_recovery.restore_manifest(args)

        self.assertEqual(calls, ["list", "create", "disable", "get", "enable"])
        self.assertEqual(report["agents"][0]["state"], "enabled")

    def test_private_json_writer_is_atomic_and_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            agent_recovery.write_private_json(path, {"state": "exported"})
            self.assertEqual(json.loads(path.read_text()), {"state": "exported"})
            self.assertFalse(path.with_suffix(".json.tmp").exists())


if __name__ == "__main__":
    unittest.main()
