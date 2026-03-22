all: backend frontend

backend:
	dub build

frontend:
	cd web && npm ci
	cd web && npm run build

run: all
	dub run

setup:
	git config core.hooksPath .githooks

dot: backend
	./build/cydo --dot defs/task-types.yaml | dot -Tsvg -o defs/task-types.svg

clean:
	rm -rf build web/dist web/node_modules

.PHONY: all backend frontend run setup clean dot
