SHELL = bash
.ONESHELL:
.PHONY: env
#

LIZMAP_DIR=$(shell pwd)/lizmap

LIZMAP_USER_ID:=$(shell id -u)
LIZMAP_USER_GID:=$(shell id -g)

LIZMAP_VERSION_TAG:=3.9
QGIS_VERSION_TAG:=ltr-rc
POSTGIS_VERSION_TAG:=17-3

QGIS_MAP_WORKERS:=1

LIZMAP_PORT:=127.0.0.1:9095
OWS_PORT:=127.0.0.1:9096
LZMPGPORT:=127.0.0.1:9097

MODULE_SRC:=$(shell realpath ..)

main:
	@cat <<- EOF
		Commandes:
			run:   initialise environnement and run stack
			stop:  stop docker and remove containers
			clean: reset containers and remove lizmap configuration
			shell: open a shell in Lizmap web container
			install-module: install the module on the Lizmap test instance
			install-plugins: install QGIS Server plugins
			import-test-data: import test data inside the PostgreSQL database
			export-test-data: export test data to tests/sql/test_data.sql

			Note: Un fichier d'environnement pour docker compose
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
			  $(MODULE_SRC)/tests/api_tests/.pytest_cache \
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
		MODULE_SRC=$(MODULE_SRC)
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

install-plugins: dirs
	@echo "Install QGIS server plugins"
	docker run \
		-u $(LIZMAP_USER_ID):$(LIZMAP_USER_GID) \
		--rm -it \
		-e QGSRV_SERVER_PLUGINPATH=/srv/plugins \
		-e QGIS_PLUGIN_MANAGER_SOURCES_FILE=/tmp/sources-plugin-manager.list \
		-e QGIS_PLUGIN_MANAGER_CACHE_DIR=/tmp/cache-plugin-manager \
		-v $(LIZMAP_DIR)/qgis-server-plugins:/srv/plugins \
		-v $(shell pwd)/:/src \
		--entrypoint /src/add-server-plugins.sh \
		3liz/qgis-map-server:${QGIS_VERSION_TAG}

import-test-data:
	sql/import.sh

export-test-data:
	@echo "Export demo data to tests/sql/test_data.sql"
	docker compose exec -u $(LIZMAP_USER_ID) pgsql /bin/sh -c " \
		pg_dump -U postgres -d lizmap --no-owner --no-acl -n gobs -Fp
	" > $(shell pwd)/sql/test_data.sql


import-lizmap-acl:
	@echo "Set repositories and users rights if needed"
	@echo "Set view project"
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c ' \
		php lizmap/console.php acl2:add __anonymous "lizmap.repositories.view" tests ; \
		php lizmap/console.php acl2:add users "lizmap.repositories.view" tests ; \
		php lizmap/console.php acl2:add admins "lizmap.repositories.view" tests'
	@echo "Display WMS links"
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c ' \
		php lizmap/console.php acl2:add __anonymous "lizmap.tools.displayGetCapabilitiesLinks" tests ; \
		php lizmap/console.php acl2:add users "lizmap.tools.displayGetCapabilitiesLinks" tests ; \
		php lizmap/console.php acl2:add admins "lizmap.tools.displayGetCapabilitiesLinks" tests'
	@echo "Edition"
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c ' \
		php lizmap/console.php acl2:add __anonymous "lizmap.tools.edition.use" tests ; \
		php lizmap/console.php acl2:add users "lizmap.tools.edition.use" tests ; \
		php lizmap/console.php acl2:add admins "lizmap.tools.edition.use" tests'
	@echo "Export layers"
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c ' \
		php lizmap/console.php acl2:add __anonymous "lizmap.tools.layer.export" tests ; \
		php lizmap/console.php acl2:add users "lizmap.tools.layer.export" tests ; \
		php lizmap/console.php acl2:add admins "lizmap.tools.layer.export" tests'
	@echo "Add GobsAPI users"
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/scripts/script.php jcommunity~user:create -v --no-error-if-exists --admin gobsapi_writer al@al.al al_password'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/scripts/script.php jcommunity~user:create -v --no-error-if-exists gobsapi_reader bob@bob.bob bob_password'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/scripts/script.php jcommunity~user:create -v --no-error-if-exists gobsapi_writer_filtered md@md.md md_password'
	@echo "Add GobsAPI groups"
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/console.php acl2group:create gobsapi_group "GobsAPI group"'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/console.php acl2group:create gobsapi_global_group "GobsAPI global group"'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/console.php acl2group:create gobsapi_filtered_group "GobsAPI filtered group"'
	@echo "Put users in their groups"
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/console.php acl2user:addgroup gobsapi_writer gobsapi_group'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/console.php acl2user:addgroup gobsapi_reader gobsapi_group'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/console.php acl2user:addgroup gobsapi_writer_filtered gobsapi_group'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/console.php acl2user:addgroup gobsapi_writer gobsapi_global_group'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/console.php acl2user:addgroup gobsapi_reader gobsapi_global_group'
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/console.php acl2user:addgroup gobsapi_writer_filtered gobsapi_filtered_group'
	@echo "Set rights for groups"
	docker compose exec -u $(LIZMAP_USER_ID) lizmap /bin/sh -c 'php lizmap/console.php acl2:add gobsapi_group "lizmap.repositories.view" tests'


install-module:
	# @echo "Install SAML modules"
	# docker compose exec -u ${LIZMAP_USER_ID} touch /www/lizmap/my-packages/composer.json
	# docker compose exec -u ${LIZMAP_USER_ID} lizmap composer --working-dir=/www/lizmap/my-packages require jelix/saml-module:2.1.*
	# docker compose exec -u ${LIZMAP_USER_ID} lizmap php /www/lizmap/install/configurator.php --no-interaction --force saml
	# docker compose exec -u ${LIZMAP_USER_ID} lizmap php /www/lizmap/install/configurator.php --no-interaction --force samladmin
	# docker compose exec -u ${LIZMAP_USER_ID} lizmap php /www/lizmap/install/installer.php -v

	@echo "Install GobsApi module"
	docker compose exec -u ${LIZMAP_USER_ID} lizmap php /www/lizmap/install/configurator.php --no-interaction --force gobsapi
	docker compose exec -u ${LIZMAP_USER_ID} lizmap php /www/lizmap/install/installer.php -v

shell:
	docker compose exec -u ${LIZMAP_USER_ID} lizmap /bin/sh -l

postgres:
	docker compose exec -u postgres pgsql psql lizmap
