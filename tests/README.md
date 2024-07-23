## Run Lizmap stack with docker compose

Steps:

* Launch Lizmap with docker compose

```bash
# Clean previous versions (optional)
make clean
# Pull docker images
make pull

# Run the different services
make run
```

- Open your browser at http://localhost:9095

For more information, refer to the [docker compose documentation](https://docs.docker.com/compose/)


## Add the test data

You can add some data in your docker test PostgreSQL database by running the SQL `tests/sql/test_data.sql`.

```bash
make import-test-data
```

If you have modified your test data suite (for example after upgrading to a new version)
please run :

```bash
make export-test-data
```

Then add the modified file `tests/sql/test_data.sql` to your pull request.


## Install the module

* Install the module with:

```bash
make install-module
```

* Add the needed Lizmap rights:


```bash
make import-lizmap-acl
```


Created groups:
* `gobsapi_group`, label `GobsAPI group`
* `gobsapi_global_group`, label `GobsAPI global group`
* `gobsapi_filtered_group`, label `GobsAPI filtered group`

Created users (all inside `gobsapi` group):
* `gobsapi_writer`, with
  * email `al@al.al`
  * password `al_password`
  * which corresponds to the Gobs actor `Al A.`
  * it belongs to the groups `gobsapi_group` & `gobsapi_global_group`
  * it can get, create, update and delete observations.
* `gobsapi_reader`, with:
  * email `bob@bob.bob`
  * password `bob_password`
  * which corresponds to the Gobs actor `Bob B.`
  * it belongs to the groups `gobsapi_group` & `gobsapi_global_group`
  * it has only read access but can see all data of the test project
* `gobsapi_writer_filtered`, with:
  * email `md@md.md`
  * password `md_password`
  * which corresponds to the Gobs actor `Md M.`
  * it belongs to the groups `gobsapi_group` & `gobsapi_filtered_group`
  * it has read & write access but can only view & edit data filtered inside by the project view geometry

They can both access the [Lizmap test map](http://localhost:9095/index.php/view/map/?repository=tests&project=gobsapi).

## Access to the dockerized PostgreSQL instance

You can access the docker PostgreSQL test database `lizmap` from your host by configuring a
[service file](https://docs.qgis.org/latest/en/docs/user_manual/managing_data_source/opening_data.html#postgresql-service-connection-file).
The service file can be stored in your user home `~/.pg_service.conf` and should contain this section

```ini
[lizmap-gobsapi]
dbname=lizmap
host=localhost
port=9097
user=lizmap
password=lizmap1234!
```

Then you can use any PostgreSQL client (psql, QGIS, PgAdmin, DBeaver) and use the `service`
instead of the other credentials (host, port, database name, user and password).

```bash
psql service=lizmap-gobsapi
```

## Access to the lizmap container

If you want to enter into the lizmap container to execute some commands,
execute `make shell`.


## API tests

You can run API tests by following this guide: [API Tests](api_tests.md)
