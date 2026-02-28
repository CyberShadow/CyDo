all: backend frontend

backend:
	dub build

frontend:
	cd web && npm install
	cd web && npm run build
	cp web/index.html web/dist/index.html
	cp web/src/styles.css web/dist/styles.css

run: all
	dub run

clean:
	rm -rf build web/dist web/node_modules

.PHONY: all backend frontend run clean
