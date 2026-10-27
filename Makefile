# make help lists every target. Nothing here needs a Google Cloud account except deploy, prove, break-*, restore-* and teardown.
PYTHON ?= $(shell command -v python3.13 || command -v python3.12 || command -v python3)
VENV := .venv
PY := $(VENV)/bin/python
STAMP := $(VENV)/.installed
ENV_DIR := infra/environments/lab
TF ?= terraform

-include .env
export

.PHONY: help install lint lint-python lint-terraform lint-manifests format test test-python test-terraform test-e2e \
        validate validate-terraform plan security audit check triage clean deploy prove teardown up run down

help: ## list the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | sort

$(STAMP): requirements-dev.lock pyproject.toml
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install -q --require-hashes -r requirements-dev.lock
	$(VENV)/bin/pip install -q --no-deps -e .
	touch $@

install: $(STAMP) ## create .venv from the lock file

lint: lint-python lint-terraform lint-manifests ## Python (ruff, mypy, import rules), shell, Terraform format and tflint, manifests

lint-python: $(STAMP)
	$(VENV)/bin/ruff check .
	$(VENV)/bin/ruff format --check .
	$(VENV)/bin/mypy
	$(VENV)/bin/lint-imports
	shellcheck scripts/*.sh

lint-terraform:
	$(TF) fmt -check -recursive -diff infra
	cd infra && tflint --init >/dev/null && tflint --recursive --config "$$PWD/.tflint.hcl"

lint-manifests: ## kubectl kustomize renders both overlays offline
	kubectl kustomize manifests/base >/dev/null
	kubectl kustomize manifests/overlays/wrong-identity >/dev/null

format: $(STAMP) ## apply ruff and terraform fmt
	$(VENV)/bin/ruff check --fix .
	$(VENV)/bin/ruff format .
	$(TF) fmt -recursive infra

# The classifier, the principal builder, the manifests and the Terraform guardrails; no cluster, no cloud account.
test: test-python test-terraform ## unit tests with coverage, then the Terraform tests with a mock provider

test-python: $(STAMP)
	$(PY) -m pytest tests/unit --cov=gke_triage --cov-report=term
	$(PY) -m coverage report --include='src/gke_triage/domain/*,src/gke_triage/application/*' --fail-under=95

test-e2e: $(STAMP) ## the command-line program as a subprocess over the lesson's error texts
	$(PY) -m pytest tests/e2e -m e2e

test-terraform:
	@for dir in infra/modules/* $(ENV_DIR); do \
	  if [ -d $$dir/tests ]; then \
	    echo "== $$dir"; \
	    (cd $$dir && $(TF) init -backend=false -input=false >/dev/null && $(TF) test) || exit 1; \
	  fi; \
	done

validate: validate-terraform security ## terraform init -backend=false, validate, an offline plan, and checkov

validate-terraform:
	@for dir in infra/modules/* $(ENV_DIR); do \
	  echo "== $$dir"; \
	  (cd $$dir && $(TF) init -backend=false -input=false >/dev/null && $(TF) validate) || exit 1; \
	done
	$(MAKE) --no-print-directory plan

# The plan needs no credentials: nothing in the configuration reads from Google Cloud, so a placeholder token is enough.
plan:
	cd $(ENV_DIR) && GOOGLE_OAUTH_ACCESS_TOKEN=offline-placeholder $(TF) plan -input=false -lock=false \
	  -var-file=lab.tfvars.example

security: ## checkov over the Terraform, the manifests and the workflow
	checkov --config-file .checkov.yaml

audit: $(STAMP) ## check the locked dependencies for known vulnerabilities
	$(VENV)/bin/pip-audit --no-deps --disable-pip -r requirements-dev.lock

check: lint test validate ## everything that needs no cluster and no cloud

triage: $(STAMP) ## render the triage table from captures/*.txt (written by the break scripts)
	$(VENV)/bin/gke-triage table captures | tee docs/triage-table.generated.md

deploy: ## terraform apply, then the manifests (needs the project)
	scripts/deploy.sh

up: deploy ## alias of deploy (needs the project)

run: $(STAMP) ## classify the lesson's error texts and print the triage table (no project needed)
	$(VENV)/bin/gke-triage classify tests/fixtures/wrong-service-account.txt
	$(VENV)/bin/gke-triage table tests/fixtures

prove: ## the runbook checks for Done when steps 1 and 2 (needs the project)
	scripts/prove.sh

teardown: ## destroy the cluster and bucket, then delete the project (needs the project)
	scripts/teardown.sh

down: teardown ## alias of teardown (needs the project)

clean:
	rm -rf $(VENV) .pytest_cache .mypy_cache .ruff_cache .coverage .import_linter_cache
	find infra -name .terraform -type d -prune -exec rm -rf {} +
