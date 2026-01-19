# Installation

## Lizmap Web Client gobsapi module


### For Lizmap Web Client >= 3.7.x

NB: all the path given in the following sections are relative
to your Lizmap Web Client instance folder.

#### SAML

See https://github.com/jelix/saml-module/

```bash
cd lizmap/my-packages/
composer require "jelix/saml-module"
cd ../..
php lizmap/install/configurator.php saml
php lizmap/install/configurator.php samladmin
```

For more information about configuration, go to https://github.com/jelix/saml-module/

#### LDAPDAO

See https://github.com/jelix/ldapdao-module

```bash
cd lizmap/my-packages/
composer require "jelix/ldapdao-module"
cd ../..
php lizmap/install/configurator.php ldapdao
```

For more information about configuration, go to https://github.com/jelix/ldapdao-module

#### GOBSAPI

Get the module with composer

```bash
cd lizmap/my-packages/
composer require "lizmap/lizmap-gobsapi-module"

cd ../..
php lizmap/install/configurator.php gobsapi
```

### Run the installer script

Then you need to run the Lizmap installer

```bash
lizmap/install/set_rights.sh
lizmap/install/clean_vartmp.sh
php lizmap/install/installer.php
```

## Authentication driver

If your Lizmap Web Client uses **SAMLv2** with the module `saml`
to authenticate the users, you need to force the `gobsapi` module
to use another driver, for example `ldapdao`.
The `SAML` protocol is based on URL redirections,
which are not suitable for the G-Obs API end point.

You can override the configuration to force the `gobsapi.php` entry point
to use another driver. To do so, you must first edit
the file `lizmap/var/config/localconfig.ini.php`
and change the content of the following sections:

```ini
[modules]

; deactivate ldapdao
ldapdao.enabled=off
; deactivate multiauth
multiauth.enabled=off
; activate saml
saml.enabled=on
; activate samladmin
samladmin.enabled=on
saml.localconf=1
samladmin.localconf=1

; activate gobsapi
gobsapi.enabled=on
gobsapi.localconf=1
ldapdao.localconf=1

jcommunity.installparam[eps]="[index,admin]"
jcommunity.installparam[manualconfig]=off
jcommunity.installparam[defaultusers]=

[coordplugin_auth]
; use the driver saml
driver=saml

[coordplugins]
lizmap=lizmapConfig.ini.php
auth.class=samlCoordPlugin

; gobsapi configuration for SAML group synchronization
[gobsapi]
adminSAMLGobsRoleName[]=ROLE_GOBS_ADMIN
adminSAMLGobsRoleName[]=GOBS_ADMIN
```

We have then activated the SAML auth for the entry points **index** and **admin**.

Now we must activate another driver for the `gobsapi` entry point, by editing
the file `lizmap/var/config/gobsapi/config.ini.php`:

```ini
[modules]

ldapdao.enabled=on
multiauth.enabled=off
samladmin.enabled=off
saml.enabled=off
saml.localconf=1
samladmin.localconf=1
gobsapi.enabled=on
gobsapi.localconf=1
ldapdao.localconf=1

[coordplugin_auth]
driver=ldapdao

[coordplugins]
jacl2=1
auth="index/auth.coord.ini.php"

[coordplugin_jacl2]
on_error=2
error_message="jacl2~errors.action.right.needed"
on_error_action="jelix~error:badright"
```

You may need to change the file `lizmap/var/config/localurls.xml`.
Check its content is like:


```xml
<?xml version="1.0" encoding="utf-8"?>
<urls xmlns="http://jelix.org/ns/urls/1.0">
    <entrypoint name="index" default="true">
        <url include="urls.xml" module="saml" pathinfo="/saml"/>
        <url module="ldapdao" pathinfo="/ldapdao"/>
    </entrypoint>

    <entrypoint name="admin">
        <url include="urls.xml" module="saml" pathinfo="/saml"/>
        <url include="urls.xml" module="samladmin" pathinfo="/samladmin"/>
    </entrypoint>

    <entrypoint name="gobsapi" type="classic">
        <url include="urls.xml" module="gobsapi" pathinfo="/gobsapi"/>
    </entrypoint>
    <entrypoint name="cmdline" type="cmdline"/>
</urls>
```

After this configuration, apply with the following commands:

```bash
lizmap/install/clean_vartmp.sh
lizmap/install/set_rights.sh
php lizmap/install/installer.php
lizmap/install/set_rights.sh
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
TOKEN=$(curl -s -X GET -H 'Content-Type: application/json' "$BASEURL/user/login?username=gobsapi_writer&password=al_password" | jq -r '.token') && echo $TOKEN
# OR
# we can use Basic authentication to avoid using username & password in the URL
TOKEN=$(curl -s -X GET -H 'Content-Type: application/json' -u "gobsapi_writer:al_password" "$BASEURL/user/login" | jq -r '.token') && echo $TOKEN
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

* Log out

```bash
# logUserOut
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/user/logout)
```


### Project

* Get a project details

```bash
# getProjectByKey
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/default_project)
```

* Get the list of indicators

```bash
# getProjectIndicators
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/default_project/indicators)
```
returns

* Get the project Geopackage

```bash
# getProjectGeopackage
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/default_project/geopackage --output /tmp/test.gpkg
```
returns the binary file and save it to `/tmp/test.gpkg`

### Indicator

* Get an indicator data
*
```bash
# getIndicatorByCode
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/default_project/series/3)
```
`

* Get the observation of a given indicator between two dates

```bash
# getObservationsByIndicator
# between seven days ago and now
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "lastSyncDate: $(date '+%Y-%m-%d %H:%M:%S' -d '7 days ago')" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/default_project/series/3/observations)
```

returns all the matching observations.


* Get the deleted observation on the server between two dates

```bash
# getDeletedObservationsByIndicator
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "lastSyncDate: $(date '+%Y-%m-%d %H:%M:%S' -d '13 days ago')" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/default_project/series/3/deletedObservations)
```

returns a list of the deleted observation uids, for example

```json
["98020996-2dec-4cbe-93d7-c2ba1b43b871","230d5b17-96b3-4bad-8c78-6379f1e9b1c6","ced021b2-6eda-4a80-8903-b013291a6b2d","2d198922-5cd0-4d0f-bc96-dfcc17c01ced","1fc001b6-c147-49ef-ae6e-66f8ea5e0b39"]
```

* Get the indicator documents

```bash
# getIndicatorDocument
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/default_project/series/3/document/946fee64-e86c-40fa-a55e-8d9ad3579734 --output /tmp/test.jpeg
```

### Observation

* Create a new observation
*
```bash
# createObservation
echo $(curl -X POST -H "Accept: application/json" -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H "Content-Type: application/json" -d "{\"id\":null,\"series\":3,\"indicator\":\"hiker_position\",\"uuid\":null,\"start_timestamp\":\"2019-07-19 03:30:00\",\"end_timestamp\":null,\"coordinates\":{\"x\":-3.785956510771293,\"y\":48.4744332531894},\"wkt\":\"POINT(-3.78595651077129 48.4744332531894)\",\"values\":[125],\"photo\":null,\"created_at\":null,\"updated_at\":null}" "$BASEURL/project/default_project/series/3/observation")
```


* Update an existing observation

```bash
# updateObservation
echo $(curl -X PUT -H "Accept: application/json" -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H "Content-Type: application/json" -d "{\"id\":1,\"series\":3,\"indicator\":\"hiker_position\",\"uuid\":\"e8f0a46c-1d24-456a-925a-387740ade1c6\",\"start_timestamp\":\"2019-07-16 03:35:00\",\"end_timestamp\":null,\"coordinates\":{\"x\":-3.785956510771293,\"y\":48.4744332531894},\"wkt\":\"POINT(-3.78595651077999 48.4744332531999)\",\"values\":[1.2],\"photo\":null,\"created_at\":\"2020-12-03 15:04:40\",\"updated_at\":\"2020-12-03 17:55:59\"}" "$BASEURL/project/default_project/series/3/observation")
```

* Get an observation data

```bash
# getObservationById
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/default_project/series/3/observation/e8f0a46c-1d24-456a-925a-387740ade1c6)
```


* Delete an observation

```bash
# deleteObservationById
echo $(curl -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/default_project/series/3/observation/e8f0a46c-1d24-456a-925a-387740ade1c6)
```


### Observation media

* Upload a media for a given observation

```bash
# uploadObservationMedia
echo $(curl -X POST -H  "Accept: application/json" -H  "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H  "Content-Type: multipart/form-data" -F "mediaFile=@/home/mdouchin/Documents/3liz/mdouchin_carre.jpeg;type=image/jpeg" $BASEURL/project/default_project/series/3/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/uploadMedia)
```


* Delete an observation media

```bash
# deleteObservationMedia
echo $(curl -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/default_project/series/3/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/deleteMedia)
```


* Download an observation media

```bash
# getObservationMedia
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/default_project/series/3/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/media --output /tmp/test.jpeg
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
