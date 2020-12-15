# lizmap-gobsapi-module

## Introduction

This is a Lizmap module to generate an API for G-Obs: https://docs.3liz.org/lizmap-gobsapi-module/api/

## Installation

NB: all the path given are relative to your Lizmap Web Client instance folder.

* Copy the `gobsapi` directory inside the `lizmap/lizmap-modules/` of a working Lizmap Web Client instance to have a new `lizmap/lizmap-modules/gobsapi/` folder containing the files `module.xml`, `events.xml`, and folders.

* Then modify the file `lizmap/var/config/localconfig.ini.php` to add `gobsapi.access=2` in the `[modules]` section, such as

```ini
[modules]
gobsapi.access=2

```

* You need to manually edit the file `lizmap/projects.xml` and add the following content inside the `<entrypoints>` section

```xml
    <entry file="gobsapi.php" config="gobsapi/config.ini.php" type="classic"/>
```

Afterwards, you should have a content like this in the `entrypoints` section

```xml
    <entrypoints>
        <entry file="index.php" config="index/config.ini.php"/>
        <entry file="admin.php" config="admin/config.ini.php" type="classic"/>
        <entry file="script.php" config="cmdline/script.ini.php" type="cmdline"/>
        <entry file="gobsapi.php" config="gobsapi/config.ini.php" type="classic"/>
    </entrypoints>
```

* Copy the folder `gobsapi/install/gobsapi` inside the Lizmap folder `lizmap/var/config/` to have a new folder `lizmap/var/config/gobsapi` with a file `config.ini.php` inside

```bash
cp -R lizmap/lizmap-modules/gobsapi/install/gobsapi lizmap/var/config/gobsapi
```

* Copy the file `gobsapi/install/gobsapi.php` inside the `lizmap/www/` folder

```bash
cp -R lizmap/lizmap-modules/gobsapi/install/gobsapi.php lizmap/www/
```

* Then you need to run the Lizmap installer

```bash
lizmap/install/set_rights.sh
lizmap/install/clean_vartmp.sh
php lizmap/install/installer.php
```

* You need to add a new database profile in the `lizmap/var/config/profiles.ini.php` like the following example (change the required fields)

```ini
[jdb:gobsapi]
driver=pgsql
database=gobs
host=localhost
port=5433
user=gobs_user
password=gobs
persistent=off

```

Then you are ready to test. For example with curl (you need curl to pass JWT token in Authorization header

```bash

# USER
###

# login
TOKEN=$(curl -s -X GET -H 'Content-Type: application/json' "http://lizmap.localhost/gobsapi.php/user/login?username=admin&password=admin" | jq -r '.token') && echo $TOKEN

# User Projects
echo $(curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" http://lizmap.localhost/gobsapi.php/user/projects)

# logUserOut
echo $(curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" http://lizmap.localhost/gobsapi.php/user/logout)

# PROJECT
###

# getProjectByKey
echo $(curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" http://lizmap.localhost/gobsapi.php/project/lizmapdemo~lampadaires)

# getProjectIndicators
echo $(curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" http://lizmap.localhost/gobsapi.php/project/lizmapdemo~lampadaires/indicators)

# INDICATOR
###

# getIndicatorByCode
echo $(curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" http://lizmap.localhost/gobsapi.php/indicator/pluviometry)

# getObservationsByIndicator
echo $(curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" http://lizmap.localhost/gobsapi.php/indicator/pluviometry/observations)

# getDeletedObservationsByIndicator
echo $(curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" http://lizmap.localhost/gobsapi.php/indicator/pluviometry/deletedObservations)
```

## License

Mozilla Public License 2: https://www.mozilla.org/en-US/MPL/2.0/
