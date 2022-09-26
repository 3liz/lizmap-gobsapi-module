# Installation

## Lizmap Web Client gobsapi module

NB: all the path given are relative to your Lizmap Web Client instance folder.

* Copy the `gobsapi` directory inside the `lizmap/lizmap-modules/` of a working
  Lizmap Web Client instance to have a new `lizmap/lizmap-modules/gobsapi/` folder
  containing the files `module.xml`, `events.xml`, and folders.

* Then modify the file `lizmap/var/config/localconfig.ini.php`
  to add `gobsapi.access=2` in the `[modules]` section, such as

```ini
[modules]
gobsapi.access=2

```

### For Lizmap Web Client <= 3.4.x

* You need to manually edit the file `lizmap/projects.xml`
  and add the following content inside the `<entrypoints>` section

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

* Copy the folder `gobsapi/install/gobsapi` inside the Lizmap folder `lizmap/var/config/`
  to have a new folder `lizmap/var/config/gobsapi` with a file `config.ini.php` inside

```bash
cp -R lizmap/lizmap-modules/gobsapi/install/gobsapi lizmap/var/config/gobsapi
```

* Copy the file `gobsapi/install/gobsapi.php` inside the `lizmap/www/` folder

```bash
cp -R lizmap/lizmap-modules/gobsapi/install/gobsapi.php lizmap/www/
```

### For Lizmap Web Client >= 3.5.x

You do not need to copy, modify or create files, everything is done by the module installer.

### Run the Lizmap Web Client installer

* Then you need to run the Lizmap installer

```bash
lizmap/install/set_rights.sh
lizmap/install/clean_vartmp.sh
php lizmap/install/installer.php
```

## Authentication driver

If your Lizmap Web Client uses **SAMLv2** to authenticate the users,
you need to force the `gobsapi` module to use another driver.
The `SAML` protocol is based on URL redirections, which are not suitable for the G-Obs API end point.

You can override the configuration to force the `gobsapi.php` entry point to use another driver.
To do so, you must first edit the file `localconfig.ini.php` and change the `[module]` section into:

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

We have deactivated gobs & saml in the main config (localconfig):
they must now be activated **only** for the entry points **index** and **admin**
by editing their configuration files `lizmap/var/config/index/config.ini.php` and `lizmap/var/config/admin/config.ini.php`.

Example contents:

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

Then you are ready to test. For example with curl (you need curl to pass JWT token in Authorization header).
Full API Documentation is available: https://docs.3liz.org/lizmap-gobsapi-module/api/

You can find examples in the [tests folder]()

In the following examples, we use `http://lizmap.localhost/` as the base URL:

* Define the API base URL:

```bash
BASEURL="http://lizmap.localhost/gobsapi.php"
```

### User

* Log in

```bash
# login
# we get the authentication TOKEN variable by first log the user in
TOKEN=$(curl -s -X GET -H 'Content-Type: application/json' "$BASEURL/user/login?username=admin&password=admin" | jq -r '.token') && echo $TOKEN
```

returns the token, for example

```
dacf5135c6686417c3916a649adbd146
```

* Get the user projects

```bash
# User Projects
# we use the $TOKEN variable in the Authorization header
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/user/projects)
```

returns

```json
[{"key":"gobs~gobsapi","label":"gobsapi","description":"","media_url":"http:\/\/lizmap.localhost\/3_5\/index.php\/view\/media\/illustration?repository=gobs&project=gobsapi","geopackage_url":"http:\/\/lizmap.localhost\/3_5\/gobsapi.php\/project\/gobs~gobsapi\/geopackage","extent":{"xmin":"-5.56054637104951","ymin":"46.6872332512938","xmax":"-0.76410351074025","ymax":"49.4663846292183"}}]
```


* Log out

```bash
# logUserOut
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/user/logout)
```

returns

```json
{"code":1,"status":"success","message":"The user has been successfully logged out"}
```

### Project

* Get a project details

```bash
# getProjectByKey
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/gobs~gobsapi)
```
returns

```json
{"key":"gobs~gobsapi","label":"gobsapi","description":"","media_url":"http:\/\/lizmap.localhost\/3_5\/index.php\/view\/media\/illustration?repository=gobs&project=gobsapi","geopackage_url":"http:\/\/lizmap.localhost\/3_5\/gobsapi.php\/project\/gobs~gobsapi\/geopackage","extent":{"xmin":"-5.56054637104951","ymin":"46.6872332512938","xmax":"-0.76410351074025","ymax":"49.4663846292183"}}
```

* Get the list of indicators

```bash
# getProjectIndicators
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/gobs~gobsapi/indicators)
```
returns

```json
[{"id":1,"code":"pluviometry","label":"Hourly pluviometry ","description":"Hourly rainfall pluviometry in millimetre","category":"Water","date_format":"hour","values":[{"code":"pluviometry","name":"Pluviometry","type":"real","unit":"mm"}],"documents":[],"preview":null,"icon":null,"created_at":"2022-05-30T15:54:34.818617","updated_at":"2022-05-30T15:54:34.818617"},{"id":2,"code":"population","label":"Population ","description":"Number of inhabitants for city","category":"Population","date_format":"year","values":[{"code":"population","name":"Population","type":"integer","unit":"people"}],"documents":[],"preview":null,"icon":null,"created_at":"2022-05-30T15:54:34.818617","updated_at":"2022-05-30T15:54:34.818617"}]
```

* Get the project Geopackage

```bash
# getProjectGeopackage
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobs~gobsapi/geopackage --output /tmp/test.gpkg
```
returns the binary file and save it to `/tmp/test.gpkg`

### Indicator

* Get an indicator data
*
```bash
# getIndicatorByCode
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/gobs~gobsapi/indicator/pluviometry)
```

returns

```json
{"id":1,"code":"pluviometry","label":"Hourly pluviometry ","description":"Hourly rainfall pluviometry in millimetre","category":"Water","date_format":"hour","values":[{"code":"pluviometry","name":"Pluviometry","type":"real","unit":"mm"}],"documents":[],"preview":null,"icon":null,"created_at":"2022-05-30T15:54:34.818617","updated_at":"2022-05-30T15:54:34.818617"}
```

* Get the observation of a given indicator between two dates

```bash
# getObservationsByIndicator
# between seven days ago and now
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "lastSyncDate: $(date '+%Y-%m-%d %H:%M:%S' -d '7 days ago')" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobs~gobsapi/indicator/pluviometry/observations)
```

returns all the matching observations.

```json
[{"id":32800,"indicator":"pluviometry","uuid":"7b35c3af-7d7d-4791-b7a4-eed9a781dc91","start_timestamp":"2019-07-16T06:00:00","end_timestamp":null,"coordinates":{"x":-2.16761209396085,"y":48.2541044163058},"wkt":"POINT(-2.16761209396085 48.2541044163058)","values":[0],"media_url":null,"created_at":"2022-05-30T17:38:00","updated_at":"2022-05-30T17:38:00","editable":false},{"id":32801,"indicator":"pluviometry","uuid":"2d9e94bc-2472-4db0-bff3-c02247cf28f8","start_timestamp":"2019-07-16T06:00:00","end_timestamp":null,"coordinates":{"x":-3.87242472398041,"y":48.354208417112},"wkt":"POINT(-3.87242472398041 48.354208417112)","values":[0],"media_url":null,"created_at":"2022-05-30T17:38:00","updated_at":"2022-05-30T17:38:00","editable":false}]
```

* Get the deleted observation on the server between two dates

```bash
# getDeletedObservationsByIndicator
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "lastSyncDate: $(date '+%Y-%m-%d %H:%M:%S' -d '13 days ago')" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobs~gobsapi/indicator/pluviometry/deletedObservations)
```

returns a list of the deleted observation uids

```json
["98020996-2dec-4cbe-93d7-c2ba1b43b871","230d5b17-96b3-4bad-8c78-6379f1e9b1c6","ced021b2-6eda-4a80-8903-b013291a6b2d","2d198922-5cd0-4d0f-bc96-dfcc17c01ced","1fc001b6-c147-49ef-ae6e-66f8ea5e0b39"]
```

* Get the indicator documents

```bash
# getIndicatorDocument
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobs~gobsapi/indicator/pluviometry/document/946fee64-e86c-40fa-a55e-8d9ad3579734 --output /tmp/test.jpeg
```

### Observation

* Create a new observation
*
```bash
# createObservation
echo $(curl -X POST -H "Accept: application/json" -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H "Content-Type: application/json" -d "{\"id\":null,\"indicator\":\"pluviometry\",\"uuid\":null,\"start_timestamp\":\"2019-07-19 03:30:00\",\"end_timestamp\":null,\"coordinates\":{\"x\":-3.785956510771293,\"y\":48.4744332531894},\"wkt\":\"POINT(-3.78595651077129 48.4744332531894)\",\"values\":[0.8],\"photo\":null,\"created_at\":null,\"updated_at\":null}" "$BASEURL/project/gobs~gobsapi/indicator/pluviometry/observation")
```

returns

```json
{"id":3595,"indicator":"pluviometry","uuid":"e8f0a46c-1d24-456a-925a-387740ade1c6","start_timestamp":"2019-07-19T03:30:00","end_timestamp":null,"coordinates":{"x":-3.78595651077129,"y":48.4744332531894},"wkt":"POINT(-3.78595651077129 48.4744332531894)","values":[0.8],"photo":null,"created_at":"2020-12-24T15:17:43","updated_at":"2020-12-24T15:17:43"}
```

* Update an existing observation

```bash
# updateObservation
echo $(curl -X PUT -H "Accept: application/json" -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H "Content-Type: application/json" -d "{\"id\":1,\"indicator\":\"pluviometry\",\"uuid\":\"e8f0a46c-1d24-456a-925a-387740ade1c6\",\"start_timestamp\":\"2019-07-16 03:35:00\",\"end_timestamp\":null,\"coordinates\":{\"x\":-3.785956510771293,\"y\":48.4744332531894},\"wkt\":\"POINT(-3.78595651077999 48.4744332531999)\",\"values\":[1.2],\"photo\":null,\"created_at\":\"2020-12-03 15:04:40\",\"updated_at\":\"2020-12-03 17:55:59\"}" "$BASEURL/project/gobs~gobsapi/indicator/pluviometry/observation")
```

returns

```json

```

* Get an observation data

```bash
# getObservationById
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobs~gobsapi/indicator/pluviometry/observation/e8f0a46c-1d24-456a-925a-387740ade1c6)
```

returns

```json

```

* Delete an observation

```bash
# deleteObservationById
echo $(curl -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobs~gobsapi/indicator/pluviometry/observation/e8f0a46c-1d24-456a-925a-387740ade1c6)
```

returns

```json

```

### Observation media

* Upload a media for a given observation

```bash
# uploadObservationMedia
echo $(curl -X POST -H  "Accept: application/json" -H  "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H  "Content-Type: multipart/form-data" -F "mediaFile=@/home/mdouchin/Documents/3liz/mdouchin_carre.jpeg;type=image/jpeg" $BASEURL/project/gobs~gobsapi/indicator/pluviometry/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/uploadMedia)
```

returns

```json

```

* Delete an observation  media

```bash
# deleteObservationMedia
echo $(curl -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobs~gobsapi/indicator/pluviometry/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/deleteMedia)
```

returns

```json

```

* Download an observation media

```bash
# getObservationMedia
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobs~gobsapi/indicator/pluviometry/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/media --output /tmp/test.jpeg
```

returns the media file in binary and save it to `/tmp/test.jpeg`


## Debug

You can activate the **debug mode** by manually editing the configuration file `lizmap/var/config/gobsapi.ini.php`
and modify the variable `log_api_calls' with the `debug` value:

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
