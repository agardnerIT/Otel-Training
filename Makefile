# OTel Training — environment orchestration shortcuts (ISI-6837).
#
# These are thin wrappers over .devcontainer/bootstrap/deploy-environment.sh so
# attendees have a one-liner. Run from the repo root inside the devcontainer.
#
#   make up         bring up the full environment (observability + Dynatrace +
#                   GitOps-synced casino); idempotent, safe to re-run
#   make up-direct  same, but deploy the casino directly (no GitOps; debug path)
#   make reset      tear down app/obs/dt/gitops, keep the kind cluster
#   make verify     re-run the component verify/validate scripts + M0 banner
#   make dco-setup  enable the DCO sign-off git hook (.githooks/) for this clone
#   make help       list targets

ORCH := .devcontainer/bootstrap/deploy-environment.sh

.DEFAULT_GOAL := help

.PHONY: up up-direct reset verify dco-setup help

up: ## Bring up the full training environment (GitOps path)
	bash $(ORCH)

up-direct: ## Bring up the environment with the casino applied directly (no GitOps)
	DEPLOY_MODE=direct bash $(ORCH)

reset: ## Tear down app/obs/dt/gitops (keep the cluster)
	bash $(ORCH) --reset

verify: ## Re-run verification + print the M0 env-check banner
	bash $(ORCH)

dco-setup: ## Enable the DCO sign-off git hook (auto Signed-off-by on every commit)
	git config core.hooksPath .githooks
	@echo "DCO hook enabled (core.hooksPath=.githooks). Ensure git user.name/user.email are set."

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'
