
## Synchronization

API Documentation URL: https://3liz.github.io/lizmap-gobsapi-module/api/

### Prerequisites:

* Each device (tablet, smartphone) must have a unique ID in the UUID form,

    - device A: 847bd592-0bc5-84d7-bf79-ae40fa544557
    - device B: 9d10aaab-84f9-87ca-e564-515e746fb2ba
    - device C: 3ee487d9-f909-634d-2455-0c8fbead6e4e

* In the database, each observation contains information on the devices which have downloaded the data:

```
[observation 1]
id = 1
uuid = e715352e-edb0-553e-2c69-09b6dc768ea7
indicator = pluviometry
values = ...
timestamp = 1999-01-01 00:00:00
import = 3
devices = {
    '847bd592-0bc5-84d7-bf79-ae40fa544557': 2,
    '9d10aaab-84f9-87ca-e564-515e746fb2ba': 3
}
```

Every time a device downloads observation data for an indicator, it passes its UUID, and the database only returns:

* observations which column "devices" does not yet have a key corresponding to the device ID.
* observations which column "devices" has a value different of the column "import" for the device key.

In this example,

* device A will get the observation 1, because the version number (2) in the "devices" column is different from the "import" (3)
* device B will not get the observation, because it already has the same version as in the server
* device C will get the observation 1, because it is not referenced as a key in the "devices" column

Every requests must pass the device UUID in the header to allow the synchronization. If not given, all the data will be sent by the server

### Example


* Ask the user to log in and get a cookie id. Other queries must pass the cookie ID in header
API: /user/login
* Get the list of projects for the user
API: /user/projects
* Choose a projet, and get the list of project indicators
API: /project/indicators
* For each indicator, get the documents which describes the indicator
API: /indicator/INDICATOR_CODE/documents
* For each indicator, get the observation data. Only data with a version different of the ones stored in the device will be downloaded. The device UID must be sent in the request header
API: /indicator/INDICATOR_CODE/observations
* Choose an indicator, and create observation data (1 or many)
* Send the newly created observation data and get in return the observation id, uuid and import uid for the sent observations (if success).
API: observation/observations
* Update the local observations wich have been pushed to the server: remove the "local only" flag, and update each observation with data generated by the server
* Logs out
API: /user/logout
* Time goes by...
* Re-connect the user
API: /user/login
* Synchronize the data:
API: /indicator/INDICATOR_CODE/observations
