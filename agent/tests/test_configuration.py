import ast
from pathlib import Path


AGENT_ROOT = Path(__file__).parents[1]


def test_agent_entrypoint_is_valid_python() -> None:
    ast.parse((AGENT_ROOT / "main.py").read_text(encoding="utf-8"))


def test_secret_files_are_excluded_from_package() -> None:
    ignore_rules = (AGENT_ROOT / ".agentignore").read_text(encoding="utf-8").splitlines()

    assert ".env" in ignore_rules
    assert ".env.*" in ignore_rules
    assert "!.env.example" in ignore_rules


def test_agent_instructions_match_the_deployed_tools() -> None:
    source = (AGENT_ROOT / "main.py").read_text(encoding="utf-8")
    instructions = source.split('INSTRUCTIONS = """', 1)[1].split('"""', 1)[0]

    assert "Databricks Genie tool" in instructions

    # Promising a tool that is not provisioned makes the agent describe capabilities it
    # does not have.
    assert "Fabric" not in instructions

    # A failed Genie call otherwise surfaces as confident SQL against invented tables,
    # which reads like an answer rather than a permissions failure.
    assert "invented table" in instructions


def test_genie_poll_receives_conversation_id() -> None:
    tree = ast.parse((AGENT_ROOT / "main.py").read_text(encoding="utf-8"))
    toolbox_calls = [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "FoundryToolbox"
    ]
    assert toolbox_calls, "FoundryToolbox is not constructed in main.py"

    # Agent Framework drops conversation_id from MCP arguments unless opted in. Genie's
    # poll_response then fails with "conversation_id parameter is required" for every
    # query that does not finish on the first call.
    opted_in = {
        element.value
        for call in toolbox_calls
        for keyword in call.keywords
        if keyword.arg == "additional_tool_argument_names"
        for element in getattr(keyword.value, "elts", [])
        if isinstance(element, ast.Constant)
    }
    assert "conversation_id" in opted_in