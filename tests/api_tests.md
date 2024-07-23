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
source .venv/bin/activate

# install requirements
pip3 install -r requirements/tests.txt

# Run tests
pytest

# Run only tests corresponding to a wildcard
pytest -v -k _with_spatial_layer

# Deactivate env
deactivate
```
