-include .env
export

TF ?= terraform
TF_DIR := deployment/terraform
TF_STATE_PREFIX ?= wad-demo/gke
INIT_SENTINEL := $(TF_DIR)/.terraform/terraform.tfstate

.DEFAULT_GOAL := help
.PHONY: help bootstrap init fmt fmt-check validate plan apply destroy output

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

bootstrap: ## One-time GCP setup (state bucket, SA, WIF). Requires PROJECT_ID, GITHUB_REPO
	@test -n "$(PROJECT_ID)" || { echo "PROJECT_ID must be set" >&2; exit 1; }
	@test -n "$(GITHUB_REPO)" || { echo "GITHUB_REPO must be set" >&2; exit 1; }
	PROJECT_ID=$(PROJECT_ID) GITHUB_REPO=$(GITHUB_REPO) $(if $(REGION),REGION=$(REGION)) ./$(TF_DIR)/bootstrap.sh

init: ## Init with GCS backend. Requires TF_STATE_BUCKET
	@test -n "$(TF_STATE_BUCKET)" || { echo "TF_STATE_BUCKET must be set" >&2; exit 1; }
	$(TF) -chdir=$(TF_DIR) init \
		-backend-config="bucket=$(TF_STATE_BUCKET)" \
		-backend-config="prefix=$(TF_STATE_PREFIX)"

$(INIT_SENTINEL):
	@$(MAKE) init

fmt: ## Format .tf files recursively
	$(TF) -chdir=$(TF_DIR) fmt -recursive

fmt-check: ## Fail if formatting would change any file
	$(TF) -chdir=$(TF_DIR) fmt -check -recursive

validate: $(INIT_SENTINEL) ## Validate configuration
	$(TF) -chdir=$(TF_DIR) validate

plan: $(INIT_SENTINEL) ## Show planned changes
	$(TF) -chdir=$(TF_DIR) plan

apply: $(INIT_SENTINEL) ## Apply changes
	$(TF) -chdir=$(TF_DIR) apply

destroy: $(INIT_SENTINEL) ## Destroy all managed resources
	$(TF) -chdir=$(TF_DIR) destroy

output: $(INIT_SENTINEL) ## Show root outputs
	$(TF) -chdir=$(TF_DIR) output
