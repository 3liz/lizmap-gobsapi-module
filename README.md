# lizmap-gobsapi-module

## Introduction

This is a Lizmap module to generate an API for G-Obs: https://docs.3liz.org/lizmap-gobsapi-module/api/

## Module installation

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

## Usage

The G-Obs API module is tightly linked to the G-Obs QGIS plugin, and to the use of Lizmap Web Client as the web map publication tool.

We write here some help regarding the specific configuration needed for G-Obs API. A full documentation on Lizmap Web Client is available here: https://docs.lizmap.com/

### Project

A project in G-Obs corresponds to a QGIS project published to Lizmap, with some specifities:

* **Indicators**: In the QGIS Project properties, you need to have a **project variable** `gobs_indicators` containing the list of indicators that you want to publish in the project. To do so, open the project properties (CTRL+MAJ+P), go to the `Variables` tab, and add a new variable: name `gobs_indicators` and value begining **exactly** with the term `gobs_indicators:`, and containing the list of indicator **codes** separated by comma. For example: `gobs_indicators:pluviometry,population` will "publish" these two indicators (pluviometry and population) with the QGIS project.

* **Additionnal spatial data**: you can also publish a **Geopackage file** alongside the project, to be used by any software to display referential spatial layers on the map with the observation data. To do so, just create and save a Geopackage file containing vector layers (and raster layers if needed) named as the QGIS project. For example, if you project file is `my_gobs_project.qgs`, you must save the Geopackage file in the same folder with the name `my_gobs_project.qgs.gpkg`. You can create and populate this Geopackage with the QGIS processing tool `Package layers` accessible with the **Processing / Toolbox** menu.

### Indicators

#### Documents

In the G-Obs database, you can add documents to illustrate each indicator. To do so, the table `gobs.document` must be filled with appropriate data.

An indicator can have different types of documents:

* `document`: any document such as PDF, ODT, DOC, DOCX, ZIP file
* `icon`: the icon of the indicator (a simple and small image file). Must be a jpeg, jpg, png or gif.
* `image`: an image file (photo, illustration)
* `other`: any other unspecified type of document
* `preview`: the image to be shown as the main illustration of the indicator. Must be a jpeg, jpg, png or gif.
* `video`: a video file.
* `url`: an URL pointing to an external ressource

All the document files must be stored in the API server. The document files must stored inside a `media/gobsapi/documents/` folder, with the `media` folder located in Lizmap repository root folder. This `media` folder must be writable. Do it for example with

```bash
chown -R :www-data /srv/data/media
chmod 775 -R /srv/data/media
```

For example, if Lizmap Web Client repository root folder is `/srv/data/`, the root gobsapi media folder will be `/srv/data/media/` and the documents must be stored in `/srv/data/media/gobsapi/documents/INDICATOR_CODE/DOCUMENT_TYPE/DOCUMENT_FILE_NAME.EXT`, where

* `INDICATOR_CODE` is the code of the indicator, for example `pluviometry`
* `DOCUMENT_TYPE` is the type of the document, for example `image`
* `DOCUMENT_FILE_NAME.EXT` is the name of the file, for example `a_picture.jpg`

Two examples:

* `/srv/data/media/gobsapi/documents/pluviometry/image/a_picture.jpg`
* `/srv/data/media/gobsapi/documents/population/document/explaining_demography.pdf`

In the **table** `gobs.document` of the **G-Obs database** , the path must be stored **relative to the folder** `/srv/data/media/gobsapi/documents`, and must begin only with the code of the indicator. For example :

* `pluviometry/image/a_picture.jpg`
* `population/document/explaining_demography.pdf`

The API module will then propose an URL to acccess each document, returned when querying the details of an indicator.

### Observations

#### Media

Each observation can have a photo, called media. When uploading this media file with the API entry point `/project/PROJECT_CODE/indicator/INDICATOR_CODE/observation/OBSERVATION_UID/uploadMedia`, the media file will be stored in the full path `/srv/data/media/gobsapi/observations/OBSERVATION_UID.EXT` where:

* `INDICATOR_CODE` is the code of the indicator, for example `pluviometry`
* `OBSERVATION_UID` is the UUID of the osbervation, for example `e8f0a46c-1d24-456a-925a-387740ade1c6`
* `EXT` is the extension of the original file sent, for example `jpeg`

which can build the example path: `/srv/data/media/gobsapi/observations/e8f0a46c-1d24-456a-925a-387740ade1c6.jpeg`



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

```



## License

Mozilla Public License 2: https://www.mozilla.org/en-US/MPL/2.0/
