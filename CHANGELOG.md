# Changelog

## Unreleased

## 0.7.0 - 2023-07-25

### Changed

* Projects - remove the link between Lizmap projects and G-Obs project & use the project table
* Observations - Restrict read & write access based on the user accessible project views

### Added

* Plugin Lizmap compatibility - Add a way to get Lizmap Web Client metadata from G-Obs API

### Fixed

* Ensure the entry point `gobsapi.php` is overwritten on each version upgrade

## 0.6.0 - 2023-03-27

### Changed

* Indicator - Move the dimensions characteristics into a new dedicated table `dimension`

## 0.5.1 - 2023-02-21

### Added

* Observation - Allow to create an observation by passing a spatial object reference
  The API will not create a new dedicated spatial object to reference the observation
  but will use the given spatial object


## 0.5.0 - 2022-11-02

### Added

* Observation - Respect and use the given `UUID` when creating a new observation
  instead of always generate a new one

### Changed

* Installation - improve the installation process and adapt the code for LWC >= 3.5
* Logs - Add the user login as a prefix in the API logs if available
* Docs:
  * Add the entry point `/project/{projectKey}/indicator/{indicatorCode}/document/{documentUuid}`
    in the [API documentation](https://docs.3liz.org/lizmap-gobsapi-module/api/)
  * Remove the useless mention of `jDb` profile

### Tests

* Unit tests - Add a full dockerized stack with Lizmap Web Client to test the API entry points
  * Add test data (taken from the G-Obs QGIS plugin)
  * Add a QGIS project with the test data and the needed variables
  * Allow to use the make command to run the test stack and import the needed data
  * Add 14 Python unit tests to cover the main API entry points

## 0.4.1 - 2022-04-22

* Observation - Return the full geometry (Point, Linestring or Polygon)
  and not the centroid anymore in the "wkt" property of the observation.
* QGIS Project - Get the QGIS PostgreSQL connection name and use it as the name of the
  PostgreSQL service file to use for the database connection.
* Installation - Use the new method `createEntryPoint` to correctly install gobsapi.php
* CI - Create a release on GitHub after a publishing a tag
* Docs - Switch to MkDocs

## 0.4.0 - 2021-07-04

* User - Automatically create an actor in the G-Obs database for the authenticated user
* Indicator - Automatically create a series for the authenticated user and the given indicator, allowing the user to directly create observations for this indicator
* Docs - Add installation, configuration & changelog chapters in https://docs.3liz.org/lizmap-gobsapi-module/

## 0.3.3 - 2021-03-02

* Observation - Add editable field to let API consumer knows whether the observation can be edited

## 0.3.2 - 2021-02-10

* Config - Add option to log every API call in Lizmap Web Client default log file
* Docs - Update README with debug chapter
* Add CHANGELOG.md file

## 0.3.1 - 2020-11-01

* Media - Use gobsapi.php URL for project geopackage, indicator documents and observation media
* Project - Add default maximum extent if project projection unknown
* Docs - Update README
