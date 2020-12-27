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
echo $(curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "lastSyncDate: $(date '+%Y-%m-%d %H:%M:%S' -d '7 days ago')" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" http://lizmap.localhost/gobsapi.php/indicator/pluviometry/observations)

# getDeletedObservationsByIndicator
echo $(curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "lastSyncDate: $(date '+%Y-%m-%d %H:%M:%S' -d '13 days ago')" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" http://lizmap.localhost/gobsapi.php/indicator/pluviometry/deletedObservations)

# OBSERVATION
###


# createObservation
echo $(curl -X POST -H "Accept: application/json" -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H "Content-Type: application/json" -d "{\"id\":null,\"indicator\":\"pluviometry\",\"uuid\":null,\"start_timestamp\":\"2019-07-19 03:30:00\",\"end_timestamp\":null,\"coordinates\":{\"x\":-3.785956510771293,\"y\":48.4744332531894},\"wkt\":\"POINT(-3.78595651077129 48.4744332531894)\",\"values\":[0.8],\"photo\":null,\"created_at\":null,\"updated_at\":null}" "http://lizmap.localhost/gobsapi.php/observation")

{"id":3595,"indicator":"pluviometry","uuid":"04686b0c-2ccd-4130-bc00-18ccf06cf573","start_timestamp":"2019-07-19T03:30:00","end_timestamp":null,"coordinates":{"x":-3.78595651077129,"y":48.4744332531894},"wkt":"POINT(-3.78595651077129 48.4744332531894)","values":[0.8],"photo":null,"created_at":"2020-12-24T15:17:43","updated_at":"2020-12-24T15:17:43"}

# updateObservation
echo $(curl -X PUT -H "Accept: application/json" -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H "Content-Type: application/json" -d "{\"id\":1,\"indicator\":\"pluviometry\",\"uuid\":\"745b18a6-1c1c-4576-9f26-72a0216d420e\",\"start_timestamp\":\"2019-07-16 03:35:00\",\"end_timestamp\":null,\"coordinates\":{\"x\":-3.785956510771293,\"y\":48.4744332531894},\"wkt\":\"POINT(-3.78595651077000 48.4744332531000)\",\"values\":[1.2],\"photo\":null,\"created_at\":\"2020-12-03 15:04:40\",\"updated_at\":\"2020-12-03 17:55:59\"}" "http://lizmap.localhost/gobsapi.php/observation")

# createObservations
todo

# getObservationsById
echo $(curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" http://lizmap.localhost/gobsapi.php/observation/04686b0c-2ccd-4130-bc00-18ccf06cf573)

# deleteObservationById
echo $(curl -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" http://lizmap.localhost/gobsapi.php/observation/04686b0c-2ccd-4130-bc00-18ccf06cf573)

# uploadObservationMedia
echo $(curl -X POST -H  "Accept: application/json" -H  "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H  "Content-Type: multipart/form-data" -F "mediaFile=@/home/mdouchin/Documents/3liz/mdouchin_carre.jpeg;type=image/jpeg" http://lizmap.localhost/gobsapi.php/observation/04686b0c-2ccd-4130-bc00-18ccf06cf573/uploadMedia)

# deleteObservationMedia
echo $(curl -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" http://lizmap.localhost/gobsapi.php/observation/04686b0c-2ccd-4130-bc00-18ccf06cf573/deleteMedia)

```

## License

Mozilla Public License 2: https://www.mozilla.org/en-US/MPL/2.0/
