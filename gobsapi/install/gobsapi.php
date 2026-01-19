<?php

use Gobsapi\Request;

/**
 * Entry point for G-Obs API.
 *
 * @author    3liz
 * @copyright 2018-2020 3liz
 *
 * @see      http://3liz.com
 *
 * @license   GPL 3
 */
require '../application.init.php';

require JELIX_LIB_CORE_PATH.'request/jClassicRequest.class.php';

checkAppOpened();

// mapping of url to basic url (/module/controller/method)
$mapping = array(
    '/lizmap/metadata' => '/gobsapi/app/metadata',

    '/user/login' => '/gobsapi/user/logUserIn',
    '/user/logout' => '/gobsapi/user/logUserOut',
    '/user/projects' => '/gobsapi/user/getUserProjects',

    '/project/:projectKey' => '/gobsapi/project/getProjectByKey',
    '/project/:projectKey/geopackage' => '/gobsapi/project/getProjectGeopackage',
    '/project/:projectKey/illustration' => '/gobsapi/project/getProjectIllustration',
    '/project/:projectKey/series' => '/gobsapi/project/getProjectSeries',

    '/project/:projectKey/series/:seriesId' => '/gobsapi/series/getSeriesById',
    '/project/:projectKey/series/:seriesId/document/:documentId' => '/gobsapi/series/getIndicatorDocument',
    '/project/:projectKey/series/:seriesId/observations' => '/gobsapi/series/getObservationsBySeries',
    '/project/:projectKey/series/:seriesId/deletedObservations' => '/gobsapi/series/getDeletedObservationsBySeries',

    '/project/:projectKey/series/:seriesId/observation' => array(
        'POST' => '/gobsapi/observation/createObservation',
        'PUT' => '/gobsapi/observation/updateObservation',
    ),
    '/project/:projectKey/series/:seriesId/observation/:observationId' => array(
        'GET' => '/gobsapi/observation/getObservationById',
        'DELETE' => '/gobsapi/observation/deleteObservationById',
    ),
    '/project/:projectKey/series/:seriesId/observation/:observationId/media' => '/gobsapi/observation/getObservationMedia',
    '/project/:projectKey/series/:seriesId/observation/:observationId/uploadMedia' => array(
        'POST' => '/gobsapi/observation/uploadObservationMedia',
    ),
    '/project/:projectKey/series/:seriesId/observation/:observationId/deleteMedia' => array(
        'DELETE' => '/gobsapi/observation/deleteObservationMedia',
    ),
);

jApp::loadConfig('gobsapi/config.ini.php');

jApp::setCoord(new jCoordinator());
jApp::coord()->process(new Request($mapping));
