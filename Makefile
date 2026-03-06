all: backend frontend

backend:
	dub build

frontend:
	cd web && npm install
	cd web && npm run build

run: all
	dub run

setup:
	git config core.hooksPath .githooks

clean:
	rm -rf build web/dist web/node_modules

.PHONY: all backend frontend run setup clean
