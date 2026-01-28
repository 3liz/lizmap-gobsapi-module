# Configuration

The G-Obs **API module** is tightly linked to the **G-Obs QGIS plugin**, and to the use of Lizmap Web Client as the web map publication tool.

We write here some help regarding the specific configuration needed for G-Obs API.
A full documentation on Lizmap Web Client is available here: https://docs.lizmap.com/

## Project

### GeoPackage file

You can publish a **Geopackage file** alongside each G-Obs project,
to be used by any software to display **referential spatial layers** on the map.

To do so, just create and save in the appropriate folder a **Geopackage file**
containing vector layers (and raster layers if needed) named **as the QGIS project**.
For example, if your G-Obs project code is `my_gobs_project`, you must
save the Geopackage file in the Lizmap data folder `media/gobsapi/geopackage/my_gobs_project.gpkg`.

You can create and populate this **Geopackage** with the **QGIS** processing tool `Package layers`
accessible with the **Processing / Toolbox** menu.

## Indicators

### Documents

In the G-Obs database, you can add documents to illustrate each indicator. To do so,
the table `gobs.document` must be filled with appropriate data.

An indicator can have different types of documents:

* `document`: any document such as PDF, ODT, DOC, DOCX, ZIP file
* `icon`: the icon of the indicator (a simple and small image file). Must be a `jpeg`, `jpg`, `png` or `gif`.
* `image`: an image file (photo, illustration)
* `other`: any other unspecified type of document
* `preview`: the image to be shown as the main illustration of the indicator. Must be a `jpeg`, `jpg`, `png` or `gif`.
* `video`: a video file.
* `url`: a URL pointing to an external web page or document.

All the document files must be stored in the API server. The document files must be stored
inside a `media/gobsapi/documents/` folder,
with the `media` folder located in Lizmap repository root folder.
This `media` folder must be writable. Do it for example with the following command:

```bash
chown -R :www-data /srv/data/media
chmod 775 -R /srv/data/media
```

For example, if Lizmap Web Client repository root folder is `/srv/data/`,
the root gobsapi media folder will be `/srv/data/media/` and the documents must be stored
in `/srv/data/media/gobsapi/documents/INDICATOR_CODE/DOCUMENT_TYPE/DOCUMENT_FILE_NAME.EXT`,
where:

* `INDICATOR_CODE` is the code of the indicator, for example `pluviometry`
* `DOCUMENT_TYPE` is the type of the document, for example `image`
* `DOCUMENT_FILE_NAME.EXT` is the name of the file, for example `a_picture.jpg`

Two examples:

* `/srv/data/media/gobsapi/documents/pluviometry/image/a_picture.jpg`
* `/srv/data/media/gobsapi/documents/population/document/explaining_demography.pdf`

In the **table** `gobs.document` of the **G-Obs database** , the path must be stored
**relative to the folder** `/srv/data/media/gobsapi/documents`, and must begin
only with the code of the indicator. For example :

* `pluviometry/image/a_picture.jpg`
* `population/document/explaining_demography.pdf`

The API module will then propose a URL to access each document,
returned when querying the details of an indicator.

## Observations

### Media

Each observation can have a photo, called media. When uploading this media file
with the API entry point `/project/PROJECT_CODE/series/SERIES_ID/observation/OBSERVATION_UID/uploadMedia`,
the media file will be stored in the full path
`/srv/data/media/gobsapi/observations/OBSERVATION_UID.EXT`
where:

* `INDICATOR_CODE` is the code of the indicator, for example `pluviometry`
* `OBSERVATION_UID` is the UUID of the observation, for example `e8f0a46c-1d24-456a-925a-387740ade1c6`
* `EXT` is the extension of the original file sent, for example `jpeg`

which can build the example path: `/srv/data/media/gobsapi/observations/e8f0a46c-1d24-456a-925a-387740ade1c6.jpeg`
