.PHONY: help up down logs ps build rebuild reset psql seed mock mock-small test test-coverage lint clean local-setup

SHELL := /bin/bash
DB := subly-db
USER := subly
NAME := subly_test

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

up: ## Start PostgreSQL
	docker compose up -d db

down: ## Stop the stack
	docker compose down

logs: ## Tail container logs
	docker compose logs -f db

ps: ## Show running containers
	docker compose ps

build: ## Build images
	docker compose build

rebuild: ## Recreate PostgreSQL container (keeps db volume)
	docker compose up -d --force-recreate db

reset: ## ⚠ Drop the db volume and re-init from scratch
	docker compose down -v
	docker compose up -d

psql: ## Open psql inside the db container
	docker compose exec db psql -U $(USER) -d $(NAME)

seed: ## Run init scripts (only needed on a non-docker local install)
	docker compose exec db sh -c 'for f in /docker-entrypoint-initdb.d/*.sql; do psql -v ON_ERROR_STOP=1 -U $(USER) -d $(NAME) -f $$f; done'

mock: ## Generate 1k users + events/invoices/payments/refunds/usage
	docker compose run --rm --entrypoint bash tests -lc "pip install --quiet -r /requirements.txt && python /scripts/generate_mock_data.py"

mock-small: ## Generate 200 users (faster, for CI)
	docker compose run --rm --entrypoint bash tests -lc "pip install --quiet -r /requirements.txt && python /scripts/generate_mock_data.py --users 200"

test: ## Run pytest suite
	docker compose run --rm --entrypoint bash tests -lc "pip install --quiet -r /requirements.txt && pytest -v"

test-coverage: ## Run pytest with coverage
	docker compose run --rm --entrypoint bash tests -lc "pip install --quiet -r /requirements.txt && pytest -v --cov=tests --cov-report=term-missing"

lint: ## Validate initialization SQL in a disposable PostgreSQL database
	@set -euo pipefail; \
	 docker compose up -d db; \
	 docker compose exec -T db dropdb --if-exists -U $(USER) subly_lint; \
	 docker compose exec -T db createdb -U $(USER) subly_lint; \
	 trap 'docker compose exec -T db dropdb --if-exists -U $(USER) subly_lint >/dev/null' EXIT; \
	 for f in init/*.sql; do \
	   echo "applying $$f to disposable database"; \
	   docker compose exec -T db psql -v ON_ERROR_STOP=1 -U $(USER) -d subly_lint -f "/docker-entrypoint-initdb.d/$$(basename "$$f")"; \
	 done

clean: ## Remove all generated artifacts
	rm -rf .pytest_cache __pycache__ */__pycache__ */*/__pycache__ .coverage

local-setup: ## Apply schema + indexes to a local Postgres instance (no Docker)
	PSQL_USER=$(USER) PSQL_DB=$(NAME) bash -c 'for f in init/*.sql; do psql -U $$PSQL_USER -d $$PSQL_DB -v ON_ERROR_STOP=1 -f $$f; done'
	set -a; [ ! -f .env ] || . ./.env; set +a; python scripts/generate_mock_data.py
