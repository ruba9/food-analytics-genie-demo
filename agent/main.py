import asyncio
import os

from agent_framework import Agent
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import FoundryToolbox, ResponsesHostServer
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

# Local debugging reads agent/.env; in Foundry these are platform-injected.
load_dotenv()


# Genie is the only tool. Adding a second metric authority means updating these
# instructions so the agent knows which system owns which metric.
INSTRUCTIONS = """You are the Food Analytics Genie, an enterprise analytics agent.

Use the Databricks Genie tool for every question about food retail sales and waste.
It is the authoritative source. The data it queries is the Unity Catalog gold layer
(food_analytics.gold), which also backs the BI dashboard.

Always call the tool for a question about a number, even if a similar question was
answered earlier in the conversation. Never answer a numeric question from memory or
from earlier context.

Answer with the figure and its unit. A definition of the metric is not an answer: give
the value first, then any explanation. Report the number exactly as the tool returns it,
without rounding or rescaling, so it matches the dashboard.

Never calculate or silently reinterpret a governed metric yourself. Report the
authoritative result and name its source.

If the tool fails or returns no result, say so plainly and stop. Do not fall back on
remembered or invented table and column names, and do not present example SQL as if it
answered the question. A failed tool call usually means a permissions or connectivity
problem, not something you can reason around.
"""


def create_agent() -> Agent:
    credential = DefaultAzureCredential()
    # Agent Framework strips "conversation_id" from MCP tool arguments by default because it
    # collides with an internal kwarg. Genie's poll_response tool requires it, so without this
    # opt-in any Genie query that is still running after the first call fails. The framework
    # removes its own conversation_id before this point, so only the model's value is forwarded.
    toolbox = FoundryToolbox(credential, additional_tool_argument_names=["conversation_id"])
    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model=os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"],
        credential=credential,
    )

    return Agent(
        client=client,
        name="food-analytics-genie",
        instructions=INSTRUCTIONS,
        tools=toolbox,
        default_options={"store": False},
    )


async def main() -> None:
    server = ResponsesHostServer(create_agent())
    await server.run_async()


if __name__ == "__main__":
    asyncio.run(main())