# Installation

This documentation is only for Lizmap 3.6+. 

## Lizmap Web Client gobsapi module

NB: all the path given are relative to your Lizmap Web Client instance folder.

### installing source code from sources

Copy the `gobsapi` directory inside the `lizmap/lizmap-modules/` of a working
Lizmap Web Client instance to have a new `lizmap/lizmap-modules/gobsapi/` folder
containing the files `module.xml`, `events.xml`, and folders.

### installing source code with Composer

If you have Composer (the package manager for PHP), `lizmap/my-packages/` and 
create the composer.json file if it does not exists:

```bash
cp lizmap/my-packages/composer.json.dist lizmap/my-packages/composer.json
```

Then declare the package of the gobsapi module:

```bash
composer --working-dir=lizmap/my-packages/ require "lizmap/lizmap-gobsapi-module"
```

### Run the Lizmap Web Client installer

* Enable the module by running the configurator of lizmap

```bash
php lizmap/install/configurator.php gobsapi
```

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

In the `lizmap/var/config/gobsapi/config.ini.php`, set these parameters:

```ini
[coordplugins]
auth="gobsapi/auth.coord.ini.php"
```

And create the file `lizmap/var/config/gobsapi/auth.coord.ini.php`, containing:

```ini
;<?php die(''); ?>
;for security reasons , don't remove or modify the first line
driver=Db
session_name=JELIX_USER
secure_with_ip=0
timeout=0
auth_required=off
on_error=2
error_message="jcommunity~login.error.notlogged"
on_error_action="jcommunity~login:out"
bad_ip_action="jcommunity~login:out"
on_error_sleep=0
after_login="view~default:index"
after_logout="jcommunity~login:index"
enable_after_login_override=on
enable_after_logout_override=on
persistant_enable=on
persistant_cookie_name=LizmapSession
persistant_duration=1
password_hash_method=1
password_hash_options=

[Db]
dao="lizmap~user"
profile=jauth
password_crypt_function=sha1
form="lizmap~account_admin"
userform="lizmap~account"
uploadsDirectory=
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
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/test_project_a)
```

* Get the list of indicators

```bash
# getProjectIndicators
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/test_project_a/indicators)
```
returns

* Get the project Geopackage

```bash
# getProjectGeopackage
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/test_project_a/geopackage --output /tmp/test.gpkg
```
returns the binary file and save it to `/tmp/test.gpkg`

### Indicator

* Get an indicator data
*
```bash
# getIndicatorByCode
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/test_project_a/indicator/hiker_position)
```
`

* Get the observation of a given indicator between two dates

```bash
# getObservationsByIndicator
# between seven days ago and now
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "lastSyncDate: $(date '+%Y-%m-%d %H:%M:%S' -d '7 days ago')" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/test_project_a/indicator/hiker_position/observations)
```

returns all the matching observations.


* Get the deleted observation on the server between two dates

```bash
# getDeletedObservationsByIndicator
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "lastSyncDate: $(date '+%Y-%m-%d %H:%M:%S' -d '13 days ago')" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/test_project_a/indicator/hiker_position/deletedObservations)
```

returns a list of the deleted observation uids

```json
["98020996-2dec-4cbe-93d7-c2ba1b43b871","230d5b17-96b3-4bad-8c78-6379f1e9b1c6","ced021b2-6eda-4a80-8903-b013291a6b2d","2d198922-5cd0-4d0f-bc96-dfcc17c01ced","1fc001b6-c147-49ef-ae6e-66f8ea5e0b39"]
```

* Get the indicator documents

```bash
# getIndicatorDocument
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/test_project_a/indicator/hiker_position/document/946fee64-e86c-40fa-a55e-8d9ad3579734 --output /tmp/test.jpeg
```

### Observation

* Create a new observation
*
```bash
# createObservation
echo $(curl -X POST -H "Accept: application/json" -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H "Content-Type: application/json" -d "{\"id\":null,\"indicator\":\"hiker_position\",\"uuid\":null,\"start_timestamp\":\"2019-07-19 03:30:00\",\"end_timestamp\":null,\"coordinates\":{\"x\":-3.785956510771293,\"y\":48.4744332531894},\"wkt\":\"POINT(-3.78595651077129 48.4744332531894)\",\"values\":[125],\"photo\":null,\"created_at\":null,\"updated_at\":null}" "$BASEURL/project/test_project_a/indicator/hiker_position/observation")
```


* Update an existing observation

```bash
# updateObservation
echo $(curl -X PUT -H "Accept: application/json" -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H "Content-Type: application/json" -d "{\"id\":1,\"indicator\":\"hiker_position\",\"uuid\":\"e8f0a46c-1d24-456a-925a-387740ade1c6\",\"start_timestamp\":\"2019-07-16 03:35:00\",\"end_timestamp\":null,\"coordinates\":{\"x\":-3.785956510771293,\"y\":48.4744332531894},\"wkt\":\"POINT(-3.78595651077999 48.4744332531999)\",\"values\":[1.2],\"photo\":null,\"created_at\":\"2020-12-03 15:04:40\",\"updated_at\":\"2020-12-03 17:55:59\"}" "$BASEURL/project/test_project_a/indicator/hiker_position/observation")
```

* Get an observation data

```bash
# getObservationById
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/test_project_a/indicator/hiker_position/observation/e8f0a46c-1d24-456a-925a-387740ade1c6)
```


* Delete an observation

```bash
# deleteObservationById
echo $(curl -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/test_project_a/indicator/hiker_position/observation/e8f0a46c-1d24-456a-925a-387740ade1c6)
```


### Observation media

* Upload a media for a given observation

```bash
# uploadObservationMedia
echo $(curl -X POST -H  "Accept: application/json" -H  "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H  "Content-Type: multipart/form-data" -F "mediaFile=@/home/mdouchin/Documents/3liz/mdouchin_carre.jpeg;type=image/jpeg" $BASEURL/project/test_project_a/indicator/hiker_position/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/uploadMedia)
```


* Delete an observation media

```bash
# deleteObservationMedia
echo $(curl -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/test_project_a/indicator/hiker_position/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/deleteMedia)
```


* Download an observation media

```bash
# getObservationMedia
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/test_project_a/indicator/hiker_position/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/media --output /tmp/test.jpeg
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
