<?php
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
require ('../application.init.php');
require (JELIX_LIB_CORE_PATH.'request/jClassicRequest.class.php');

checkAppOpened();

// mapping of url to basic url (/module/controller/method)
$mapping = array(
    '/user/login' => '/gobsapi/user/logUserIn',
    '/user/logout' => '/gobsapi/user/logUserOut',
    '/user/projects' => '/gobsapi/user/getUserProjects',

    '/project/:projectKey' => '/gobsapi/project/getProjectByKey',
    '/project/:projectKey/indicators' => '/gobsapi/project/getProjectIndicators',
    '/project/:projectKey/geopackage' => '/gobsapi/project/getProjectGeopackage',

    '/project/:projectKey/indicator/:indicatorCode' => '/gobsapi/indicator/getIndicatorByCode',
    '/project/:projectKey/indicator/:indicatorCode/document/:documentId' => '/gobsapi/indicator/getIndicatorDocument',
    '/project/:projectKey/indicator/:indicatorCode/observations' => '/gobsapi/indicator/getObservationsByIndicator',
    '/project/:projectKey/indicator/:indicatorCode/deletedObservations' => '/gobsapi/indicator/getDeletedObservationsByIndicator',

    '/project/:projectKey/indicator/:indicatorCode/observation' => array(
        'POST' => '/gobsapi/observation/createObservation',
        'PUT' => '/gobsapi/observation/updateObservation',
    ),
    '/project/:projectKey/indicator/:indicatorCode/observation/:observationId' => array(
        'GET' => '/gobsapi/observation/getObservationById',
        'DELETE' => '/gobsapi/observation/deleteObservationById',
    ),
    '/project/:projectKey/indicator/:indicatorCode/observation/:observationId/media' => '/gobsapi/observation/getObservationMedia',
    '/project/:projectKey/indicator/:indicatorCode/observation/:observationId/uploadMedia' => array(
        'POST' => '/gobsapi/observation/uploadObservationMedia',
    ),
    '/project/:projectKey/indicator/:indicatorCode/observation/:observationId/deleteMedia' => array(
        'DELETE' => '/gobsapi/observation/deleteObservationMedia',
    ),
);

jApp::loadConfig('gobsapi/config.ini.php');

jApp::setCoord(new jCoordinator());
jApp::coord()->process(new \Gobsapi\Request($mapping));
