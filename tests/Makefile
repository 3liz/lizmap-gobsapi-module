SHELL = bash
.ONESHELL:
.PHONY: env
#

LIZMAP_DIR=$(shell pwd)/lizmap

LIZMAP_USER_ID:=$(shell id -u)
LIZMAP_USER_GID:=$(shell id -g)

LIZMAP_VERSION_TAG:=3.5
QGIS_VERSION_TAG:=ltr-rc
POSTGIS_VERSION_TAG:=11-2.5

QGIS_MAP_WORKERS:=1

LIZMAP_PORT:=127.0.0.1:9095
OWS_PORT:=127.0.0.1:9096
LZMPGPORT:=127.0.0.1:9097

GOBSAPI_MODULE_SRC:=$(shell realpath ..)

main:
	@cat <<- EOF
		Commandes:
			run:   initialise environnement and run stack
			stop:  stop docker and remove containers
			clean: reset containers and remove lizmap configuration
			shell: open a shell in Lizmap web container
			install-plugins: install QGIS Server plugins
			import-data: import test data inside the PostgreSQL database

			Note: Un fichier d'environment pour docker compose
			est crée à chaque invocation de 'run'.
			Cela permet d'utiliser les commandes 'docker compose'
			sans passer par le Makefile
	EOF

dirs:
	@mkdir -p $(LIZMAP_DIR)/var/log/nginx \
		      $(LIZMAP_DIR)/var/nginx-cache \
		      $(LIZMAP_DIR)/qgis-server-plugins \
		      $(LIZMAP_DIR)/local-python \
		      $(LIZMAP_DIR)/cache-python \
		      $(GOBSAPI_MODULE_SRC)/tests/api_tests/.pytest_cache \
		      $*

env: dirs
	@cat <<- EOF > .env
		COMPOSE_PROJECT_NAME=gobsapi
		LIZMAP_DIR=$(LIZMAP_DIR)
		LIZMAP_USER_ID=$(LIZMAP_USER_ID)
		LIZMAP_USER_GID=$(LIZMAP_USER_GID)
		QGIS_MAP_WORKERS=$(QGIS_MAP_WORKERS)
		LIZMAP_PORT=$(LIZMAP_PORT)
		OWS_PORT=$(OWS_PORT)
		LZMPGPORT=$(LZMPGPORT)
		GOBSAPI_MODULE_SRC=$(GOBSAPI_MODULE_SRC)
		LIZMAP_VERSION_TAG=$(LIZMAP_VERSION_TAG)
		QGIS_VERSION_TAG=$(QGIS_VERSION_TAG)
		POSTGIS_VERSION_TAG=$(POSTGIS_VERSION_TAG)
		EOF

run: stop env install-plugins
	docker compose up -d

stop:
	docker compose down || true

clean: stop
	docker compose down -v
	rm -rf $(LIZMAP_DIR)/www/*
	rm -rf $(LIZMAP_DIR)/var/*

# Pull images from github 3liz
pull:
	docker pull 3liz/lizmap-web-client:${LIZMAP_VERSION_TAG}
	docker pull 3liz/qgis-map-server:${QGIS_VERSION_TAG}
	docker pull 3liz/postgis:${POSTGIS_VERSION_TAG}

shell:
	docker compose exec -u ${LIZMAP_USER_ID} lizmap /bin/sh -l

install-plugins: dirs
	@echo "Install QGIS server plugins"
	docker run \
		-u $(LIZMAP_USER_ID):$(LIZMAP_USER_GID) \
		--rm -i \
		-e QGSRV_SERVER_PLUGINPATH=/srv/plugins \
		-e QGIS_PLUGIN_MANAGER_SOURCES_FILE=/tmp/sources-plugin-manager.list \
		-e QGIS_PLUGIN_MANAGER_CACHE_DIR=/tmp/cache-plugin-manager \
		-v $(LIZMAP_DIR)/qgis-server-plugins:/srv/plugins \
		-v $(shell pwd)/:/src \
		--entrypoint /bin/bash \
		3liz/qgis-map-server:$(QGIS_VERSION_TAG) \
		-c "\
		    echo "https://packages.3liz.org/pub/server-plugins-repository/unstable/plugins.[VERSION].xml" > /tmp/sources-plugin-manager.list; \
		    qgis-plugin-manager update; \
		    qgis-plugin-manager install 'Lizmap server'"

export-data:
	export PGPASSWORD=lizmap1234!; pg_dump -h localhost -U lizmap -d lizmap -p 9097 --no-acl --no-owner -Fp -f sql/test_data.sql

import-data:
	export PGPASSWORD=lizmap1234!; psql -h localhost -U lizmap -d lizmap -p 9097 -c 'DROP SCHEMA IF EXISTS gobs CASCADE;'
	export PGPASSWORD=lizmap1234!; psql -h localhost -U lizmap -d lizmap -p 9097 -f sql/test_data.sql

import-lizmap-acl:
	@echo "Set repositories and users rights if needed"
	@echo "Set view project"
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2right add __anonymous "lizmap.repositories.view" gobsapi'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2right add users "lizmap.repositories.view" gobsapi'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2right add admins "lizmap.repositories.view" gobsapi'
	@echo "Display WMS links"
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2right add __anonymous "lizmap.tools.displayGetCapabilitiesLinks" gobsapi'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2right add users "lizmap.tools.displayGetCapabilitiesLinks" gobsapi'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2right add admins "lizmap.tools.displayGetCapabilitiesLinks" gobsapi'
	@echo "Edition"
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2right add __anonymous "lizmap.tools.edition.use" gobsapi'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2right add users "lizmap.tools.edition.use" gobsapi'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2right add admins "lizmap.tools.edition.use" gobsapi'
	@echo "Export layers"
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2right add __anonymous "lizmap.tools.layer.export" gobsapi'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2right add users "lizmap.tools.layer.export" gobsapi'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2right add admins "lizmap.tools.layer.export" gobsapi'
	@echo "Add users and groups"
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/scripts/script.php jcommunity~user:create -v --no-error-if-exists --admin gobsapi_writer al@al.al al_password'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/scripts/script.php jcommunity~user:create -v --no-error-if-exists gobsapi_reader bob@bob.bob bob_password'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2group create gobsapi_group "GobsAPI group"'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2group adduser gobsapi_group gobsapi_reader'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2group adduser gobsapi_group gobsapi_writer'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/cmd.php acl2right add gobsapi_group "lizmap.repositories.view" "gobsapi"'
