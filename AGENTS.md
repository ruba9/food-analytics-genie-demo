# Agent Guidance

This project was built with the microsoft-foundry skill. Before working on or answering questions about Foundry agents, read the microsoft-foundry skill first.

Template 19 owns Foundry infrastructure. Do not add an `infra` provider or an `azure.ai.project` service to `azure.yaml`; doing so can provision a separate public Foundry project. Do not deploy until the checks in `docs/deployment-plan.md` pass and the user explicitly approves deployment.