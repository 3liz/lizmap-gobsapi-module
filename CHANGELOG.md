# Changelog

## Unreleased

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
