# Installation

## Lizmap Web Client gobsapi module

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

## Authentication driver

If your Lizmap Web Client uses **SAMLv2** to authenticate the users, you need to force the gobsapi module to use another driver. The SAML protocol is based on URL redirections, which are not suitable for the G-Obs API end point.

You can override the configuration to force the `gobsapi.php` entry point to use another driver. To do so, you must first edit the file `localconfig.ini.php` and change the `[module]` section into:

```ini
[modules]
;; uncomment it if you want to use ldap for authentication
;; see documentation to complete the ldap configuration
ldapdao.access=0
lizmap.installparam=
multiauth.access=0

;; we deactivate gobs & saml which must be activated
;; only for the entry points index and admin
;; by editing their configuration files lizmap/var/config/index/config.ini.php
;; and lizmap/var/config/admin/config.ini.php
gobs.access=0
saml.access=0
;; we then activate the gobsapi module
gobsapi.access=2
```

We have deactivated gobs & saml in the main config (localconfig): they must now be activated only for the entry points index and admin by editing their configuration files `lizmap/var/config/index/config.ini.php` and `lizmap/var/config/admin/config.ini.php`. Example contents

* for the index entrypoint:


```ini
;<?php die(''); ?>
;for security reasons , don't remove or modify the first line

startModule=view
startAction="default:index"

[coordplugins]
jacl2=1

saml="saml/saml.coord.ini.php"
saml.name=auth

[modules]
dataviz.access=2
dynamicLayers.access=2
jelix.access=2
lizmap.access=2
view.access=2
filter.access=2
action.access=2

jacl2db_admin.access=1
jauthdb_admin.access=1
master_admin.access=1

saml.access=2
saml.installparam="localconfig;useradmin=mdouchin;emailadmin=mdouchin@3liz.com"
saml.path="app:my-packages/vendor/jelix/saml-module/saml"
gobs.access=2

[coordplugin_auth]
;; uncomment it if you want to use ldap for authentication
;; see documentation to complete the ldap configuration
driver=saml
```

* for the admin entrypoint:

```ini
;<?php die(''); ?>
;for security reasons , don't remove or modify the first line

startModule=master_admin
startAction="default:index"

[responses]
html=adminHtmlResponse
htmlauth=adminLoginHtmlResponse

[modules]
admin.access=2
jauthdb_admin.access=2
jacl2db_admin.access=2
master_admin.access=2
jcommunity.access=2

saml.access=2
saml.installparam="localconfig;useradmin=mdouchin;emailadmin=mdouchin@3liz.com"
saml.path="app:my-packages/vendor/jelix/saml-module/saml"
gobs.access=2

[coordplugins]
jacl2=1

saml="saml/saml.coord.ini.php"
saml.name=auth

[coordplugin_auth]
;; uncomment it if you want to use ldap for authentication
;; see documentation to complete the ldap configuration
driver=saml

```

* for the gobsapi entrypoint:

```ini
[modules]
jelix.access=1
lizmap.access=1
view.access=1

jacl2db_admin.access=1
jauthdb_admin.access=1
master_admin.access=1

;; on active le module gobsapi
gobsapi.access=2

;; et ldapdao
ldapdao.access=1
jacl2.access=1
jauth.access=1
jauthdb.access=1

[coordplugins]
jacl2=1
auth="gobsapi/auth.coord.ini.php"

[coordplugin_jacl2]
on_error=2
error_message="jacl2~errors.action.right.needed"
on_error_action="jelix~error:badright"

```


## Test the API

Then you are ready to test. For example with curl (you need curl to pass JWT token in Authorization header). Full API Documentation is available: https://docs.3liz.org/lizmap-gobsapi-module/api/

In the following examples, we use `http://lizmap.localhost/` as the base URL:

* Define the API base URL:

```bash
BASEURL="http://lizmap.localhost/gobsapi.php"
```

* User:

```bash
# USER
###

# login
# we get the authentication TOKEN variable by first log the user in
TOKEN=$(curl -s -X GET -H 'Content-Type: application/json' "$BASEURL/user/login?username=admin&password=admin" | jq -r '.token') && echo $TOKEN

# User Projects
# we use the $TOKEN variable in the Authorization header
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/user/projects)

# logUserOut
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/user/logout)

```

* Project:

```bash
# PROJECT
###

# getProjectByKey
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/lizmapdemo~lampadaires)

# getProjectIndicators
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/lizmapdemo~lampadaires/indicators)

# getProjectGeopackage
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/lizmapdemo~lampadaires/geopackage --output /tmp/test.gpkg
```

* Indicator:

```bash
# INDICATOR
###

# getIndicatorByCode
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/lizmapdemo~lampadaires/indicator/pluviometry)

# getObservationsByIndicator
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "lastSyncDate: $(date '+%Y-%m-%d %H:%M:%S' -d '7 days ago')" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/lizmapdemo~lampadaires/indicator/pluviometry/observations)

# getDeletedObservationsByIndicator
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "lastSyncDate: $(date '+%Y-%m-%d %H:%M:%S' -d '13 days ago')" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/lizmapdemo~lampadaires/indicator/pluviometry/deletedObservations)

# getIndicatorDocument
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/lizmapdemo~lampadaires/indicator/pluviometry/document/946fee64-e86c-40fa-a55e-8d9ad3579734 --output /tmp/test.jpeg
```

* Observation:

```bash
# OBSERVATION
###


# createObservation
echo $(curl -X POST -H "Accept: application/json" -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H "Content-Type: application/json" -d "{\"id\":null,\"indicator\":\"pluviometry\",\"uuid\":null,\"start_timestamp\":\"2019-07-19 03:30:00\",\"end_timestamp\":null,\"coordinates\":{\"x\":-3.785956510771293,\"y\":48.4744332531894},\"wkt\":\"POINT(-3.78595651077129 48.4744332531894)\",\"values\":[0.8],\"photo\":null,\"created_at\":null,\"updated_at\":null}" "$BASEURL/project/lizmapdemo~lampadaires/indicator/pluviometry/observation")

{"id":3595,"indicator":"pluviometry","uuid":"e8f0a46c-1d24-456a-925a-387740ade1c6","start_timestamp":"2019-07-19T03:30:00","end_timestamp":null,"coordinates":{"x":-3.78595651077129,"y":48.4744332531894},"wkt":"POINT(-3.78595651077129 48.4744332531894)","values":[0.8],"photo":null,"created_at":"2020-12-24T15:17:43","updated_at":"2020-12-24T15:17:43"}

# updateObservation
echo $(curl -X PUT -H "Accept: application/json" -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H "Content-Type: application/json" -d "{\"id\":1,\"indicator\":\"pluviometry\",\"uuid\":\"e8f0a46c-1d24-456a-925a-387740ade1c6\",\"start_timestamp\":\"2019-07-16 03:35:00\",\"end_timestamp\":null,\"coordinates\":{\"x\":-3.785956510771293,\"y\":48.4744332531894},\"wkt\":\"POINT(-3.78595651077999 48.4744332531999)\",\"values\":[1.2],\"photo\":null,\"created_at\":\"2020-12-03 15:04:40\",\"updated_at\":\"2020-12-03 17:55:59\"}" "$BASEURL/project/lizmapdemo~lampadaires/indicator/pluviometry/observation")

# getObservationById
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/lizmapdemo~lampadaires/indicator/pluviometry/observation/e8f0a46c-1d24-456a-925a-387740ade1c6)

# deleteObservationById
echo $(curl -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/lizmapdemo~lampadaires/indicator/pluviometry/observation/e8f0a46c-1d24-456a-925a-387740ade1c6)
```

* Observation media:

```bash
# uploadObservationMedia
echo $(curl -X POST -H  "Accept: application/json" -H  "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H  "Content-Type: multipart/form-data" -F "mediaFile=@/home/mdouchin/Documents/3liz/mdouchin_carre.jpeg;type=image/jpeg" $BASEURL/project/lizmapdemo~lampadaires/indicator/pluviometry/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/uploadMedia)

# deleteObservationMedia
echo $(curl -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/lizmapdemo~lampadaires/indicator/pluviometry/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/deleteMedia)

# getObservationMedia
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/lizmapdemo~lampadaires/indicator/pluviometry/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/media --output /tmp/test.jpeg
```

## Debug

You can activate the **debug mode** by manually editing the configuration file `lizmap/var/config/gobsapi.ini.php` and modify the variable `log_api_calls' with the `debug` value:

```ini
[gobsapi]
log_api_calls=debug
```

You will then be able to see the API calls log written in the file `lizmap/var/log/messages.log`

```bash
tail -f lizmap/var/log/messages.log
```

Messages will be like

```
2021-02-09 17:18:52	127.0.0.1	default	GOBSAPI - ################
2021-02-09 17:19:05	127.0.0.1	default	GOBSAPI - path: getProjectByKey
2021-02-09 17:19:05	127.0.0.1	default	GOBSAPI - input_data: {"projectKey":"lizmapdemo~a_fake_project","module":"gobsapi","action":"project:getProjectByKey"}
2021-02-09 17:19:05	127.0.0.1	default	GOBSAPI - http_code: 404
2021-02-09 17:19:05	127.0.0.1	default	GOBSAPI - status: error
2021-02-09 17:19:05	127.0.0.1	default	GOBSAPI - message: The given project key does not refer to a known project
2021-02-09 17:19:05	127.0.0.1	default	GOBSAPI - ################

```
