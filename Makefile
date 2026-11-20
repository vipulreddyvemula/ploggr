.DEFAULT_GOAL := help
.PHONY: help setup api app check validate validate-auth validate-plog validate-evidence down

DEVICE ?= linux

help:
	@printf '%s\n' \
	  'make setup     Install locked dependencies and create missing local config files' \
	  'make api       Start PostgreSQL and image storage, apply migrations and run the Nest watch server' \
	  'make app       Run the configured Flutter app (DEVICE defaults to linux)' \
	  'make check     Analyze and test Flutter and the backend without Docker' \
	  'make validate  Run the full isolated Linux foundation checks' \
	  'make validate-auth DEVICE=emulator-5554  Verify M2 on an empty Android emulator' \
	  'make validate-plog DEVICE=emulator-5554  Verify M3 GPS tracking and completion' \
	  'make validate-evidence DEVICE=emulator-5554  Verify Android garbage-photo completion' \
	  'make down      Stop development services and retain their volumes'

setup: backend/.env config/development.local.json
	node backend/tool/setup-auth-key.mjs
	flutter pub get --enforce-lockfile
	npm --prefix backend ci --include=dev

backend/.env:
	cp backend/.env.example "$@"

config/development.local.json:
	cp config/development.example.json "$@"

api:
	npm --prefix backend run db:up
	npm --prefix backend run migration:run
	npm --prefix backend run start:dev

app:
	flutter run -d "$(DEVICE)" --dart-define-from-file=config/development.local.json

check:
	flutter analyze --no-pub
	flutter test --no-pub
	npm --prefix backend run check

validate:
	node tool/validate_foundation.mjs

validate-auth:
	node tool/validate_auth.mjs "$(DEVICE)"

validate-plog validate-evidence:
	node tool/validate_plog.mjs "$(DEVICE)"

down:
	npm --prefix backend run db:down
