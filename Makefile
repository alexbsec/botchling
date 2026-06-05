.PHONY: rathena botchling-infra down

rathena:
	@docker compose up -d rathena-db rathena-login rathena-char rathena-map

botchling-infra:
	@docker compose up -d botchling-mongodb botchling-postgres

down:
	@docker compose down --remove-orphans
