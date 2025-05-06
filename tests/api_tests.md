## API Tests

### Fully inside docker

When the docker compose stack is running

```bash
docker compose run --rm pytest
```

### Local pytest

But against the docker compose project

You can use `pytest` to run the available unit tests:

```bash
# Go the the Python test directory
cd tests/api_tests/

# create & activate virtual env
python3 -m venv .venv
# source .venv/bin/activate

# install requirements
.venv/bin/pip3 install -r requirements/tests.txt

# Run tests
.venv/bin/pytest

# Run only tests corresponding to a wildcard
.venv/bin/pytest -v -k _with_spatial_layer

# Deactivate env
# deactivate
```

**NB**: If you have some errors (get only 401 errors) such as `AssertionError: 401 != 200`
you should check that the file `tests/lizmap/var/lizmap-config/gobsapi/config.ini.php`
contains `ldapdao.enabled=off` (and not `on`) in the section `[modules]`
and that the `driver=ldapdao` is commented in the section `[coordplugin_auth]`
