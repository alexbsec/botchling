.PHONY: rathena botchling-infra down builder botchling up

rathena:
	@docker compose up -d rathena-db rathena-login rathena-char rathena-map

botchling-infra:
	@docker compose up -d botchling-mongodb botchling-postgres

down:
	@docker compose down --remove-orphans

builder:
	@docker compose up rathena-builder

botchling:
	@cd backend && cargo build --release

up:
	@docker compose up -d

