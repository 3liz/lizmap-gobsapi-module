# Run Lizmap stack with docker compose

Steps:

- Launch Lizmap with docker compose
    ```
    # Clean previous versions (optional)
    make clean

    # Run the different services
    make run
    ```

- A simple `gobsapi` project is present, but you have to set rights in administration to view it.

- Open your browser at http://localhost:9095

For more information, refer to the [docker compose documentation](https://docs.docker.com/compose/)

## Access to the dockerized PostgreSQL instance

You can access the docker PostgreSQL test database `lizmap` from your host by configuring a
[service file](https://docs.qgis.org/latest/en/docs/user_manual/managing_data_source/opening_data.html#postgresql-service-connection-file).
The service file can be stored in your user home `~/.pg_service.conf` and should contains this section

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

## Add the test data

### PostgreSQL gobs data

You can add some data in your docker test PostgreSQL database by running the SQL `tests/sql/test_data.sql`.

```bash
make import-data
```
or
```bash
psql service=lizmap-gobsapi -f tests/sql/test_data.sql
```

### Lizmap Web Client groups, users and rights

Before running manual or automatic tests, you also need to add some Lizmap groups, users and rights

```bash
make add-test-users
```

Create group:
* `gobsapi`, label `GobsAPI group`

Created users (all inside `gobsapi` group):
* `gobsapi_writer`, with
  * email `al@al.al`
  * password `al_password`
  * which corresponds to the Gobs actor `Al A.`
  * it can get, create, update and delete observations.
* `gobsapi_reader`, with:
  * email `bob@bob.bob`
  * password `bob_password`
  * which corresponds to the Gobs actor `Bob B.`
  * it has only read access

They can both access the [Lizmap test map](http://localhost:9095/index.php/view/map/?repository=gobsapi&project=gobsapi).

## Test the API with Python unit tests

You can use `pytest` to run the available unit tests:

```bash
# create & activate virtual env
python3 -m venv /tmp/gobsapi
source /tmp/gobsapi/bin/activate

# install requirements
cd tests/api_tests/
pip3 install -r requirements/tests.txt

# Run tests
pytest

# Deactivate env
deactiate
```
