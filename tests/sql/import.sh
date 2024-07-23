# Import SQL data for test purpose
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Delete the previous demo data
echo "=== Drop the existing demo schema and data"
psql service=lizmap-gobsapi -c "DROP SCHEMA IF EXISTS gobs CASCADE;"

# Import data
echo "=== Add the gobs schema with test data"
psql service=lizmap-gobsapi -f "$SCRIPT_DIR"/test_data.sql
