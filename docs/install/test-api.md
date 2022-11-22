
# Test the API

Then you are ready to test. For example with curl (you need curl to pass JWT token in Authorization header).
Full API Documentation is available: https://docs.3liz.org/lizmap-gobsapi-module/api/

You can find examples in the [tests folder]()

In the following examples, we use `http://lizmap.localhost/` as the base URL:

* Define the API base URL:

```bash
BASEURL="http://lizmap.localhost/gobsapi.php"
```

## User

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


## Project

* Get a project details

```bash
# getProjectByKey
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/gobsapi~gobsapi)
```

* Get the list of indicators

```bash
# getProjectIndicators
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/gobsapi~gobsapi/indicators)
```
returns

* Get the project Geopackage

```bash
# getProjectGeopackage
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobsapi~gobsapi/geopackage --output /tmp/test.gpkg
```
returns the binary file and save it to `/tmp/test.gpkg`

## Indicator

* Get an indicator data
*
```bash
# getIndicatorByCode
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" $BASEURL/project/gobsapi~gobsapi/indicator/hiker_position)
```
`

* Get the observation of a given indicator between two dates

```bash
# getObservationsByIndicator
# between seven days ago and now
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "lastSyncDate: $(date '+%Y-%m-%d %H:%M:%S' -d '7 days ago')" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobsapi~gobsapi/indicator/hiker_position/observations)
```

returns all the matching observations.


* Get the deleted observation on the server between two dates

```bash
# getDeletedObservationsByIndicator
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "lastSyncDate: $(date '+%Y-%m-%d %H:%M:%S' -d '13 days ago')" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobsapi~gobsapi/indicator/hiker_position/deletedObservations)
```

returns a list of the deleted observation uids

```json
["98020996-2dec-4cbe-93d7-c2ba1b43b871","230d5b17-96b3-4bad-8c78-6379f1e9b1c6","ced021b2-6eda-4a80-8903-b013291a6b2d","2d198922-5cd0-4d0f-bc96-dfcc17c01ced","1fc001b6-c147-49ef-ae6e-66f8ea5e0b39"]
```

* Get the indicator documents

```bash
# getIndicatorDocument
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobsapi~gobsapi/indicator/hiker_position/document/946fee64-e86c-40fa-a55e-8d9ad3579734 --output /tmp/test.jpeg
```

## Observation

* Create a new observation
*
```bash
# createObservation
echo $(curl -X POST -H "Accept: application/json" -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H "Content-Type: application/json" -d "{\"id\":null,\"indicator\":\"hiker_position\",\"uuid\":null,\"start_timestamp\":\"2019-07-19 03:30:00\",\"end_timestamp\":null,\"coordinates\":{\"x\":-3.785956510771293,\"y\":48.4744332531894},\"wkt\":\"POINT(-3.78595651077129 48.4744332531894)\",\"values\":[125],\"photo\":null,\"created_at\":null,\"updated_at\":null}" "$BASEURL/project/gobsapi~gobsapi/indicator/hiker_position/observation")
```


* Update an existing observation

```bash
# updateObservation
echo $(curl -X PUT -H "Accept: application/json" -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H "Content-Type: application/json" -d "{\"id\":1,\"indicator\":\"hiker_position\",\"uuid\":\"e8f0a46c-1d24-456a-925a-387740ade1c6\",\"start_timestamp\":\"2019-07-16 03:35:00\",\"end_timestamp\":null,\"coordinates\":{\"x\":-3.785956510771293,\"y\":48.4744332531894},\"wkt\":\"POINT(-3.78595651077999 48.4744332531999)\",\"values\":[1.2],\"photo\":null,\"created_at\":\"2020-12-03 15:04:40\",\"updated_at\":\"2020-12-03 17:55:59\"}" "$BASEURL/project/gobsapi~gobsapi/indicator/hiker_position/observation")
```

* Get an observation data

```bash
# getObservationById
echo $(curl -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobsapi~gobsapi/indicator/hiker_position/observation/e8f0a46c-1d24-456a-925a-387740ade1c6)
```


* Delete an observation

```bash
# deleteObservationById
echo $(curl -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobsapi~gobsapi/indicator/hiker_position/observation/e8f0a46c-1d24-456a-925a-387740ade1c6)
```


## Observation media

* Upload a media for a given observation

```bash
# uploadObservationMedia
echo $(curl -X POST -H  "Accept: application/json" -H  "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" -H  "Content-Type: multipart/form-data" -F "mediaFile=@/home/mdouchin/Documents/3liz/mdouchin_carre.jpeg;type=image/jpeg" $BASEURL/project/gobsapi~gobsapi/indicator/hiker_position/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/uploadMedia)
```


* Delete an observation media

```bash
# deleteObservationMedia
echo $(curl -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobsapi~gobsapi/indicator/hiker_position/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/deleteMedia)
```


* Download an observation media

```bash
# getObservationMedia
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H "requestSyncDate: $(date '+%Y-%m-%d %H:%M:%S')" $BASEURL/project/gobsapi~gobsapi/indicator/hiker_position/observation/e8f0a46c-1d24-456a-925a-387740ade1c6/media --output /tmp/test.jpeg
```

returns the media file in binary and save it to `/tmp/test.jpeg`

