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
require '../application.init.php';
require JELIX_LIB_CORE_PATH.'request/jClassicRequest.class.php';

checkAppOpened();

// mapping of url to basic url (/module/controller/method)
$mapping = array(
    '/user/login' => '/gobs/user/logUserIn',
    '/user/logout' => '/gobs/user/logUserOut',
    '/user/projects' => '/gobs/user/getUserProjects',

    '/project/:projectKey' => '/gobs/project/getProjectByKey',
    '/project/:projectKey/indicators' => '/gobs/project/getProjectIndicators',

    '/indicator/:indicatorCode' => '/gobs/indicator/getIndicatorByCode',
    '/indicator/:indicatorCode/documents' => '/gobs/indicator/getIndicatorDocuments',
    '/indicator/:indicatorCode/observations' => '/gobs/indicator/getObservationsByIndicator',
    '/indicator/:indicatorCode/deletedObservations' => '/gobs/indicator/getDeletedObservationsByIndicator',

    '/observation' => array(
        'POST' => '/gobs/observation/createObservation',
        'PUT' => '/gobs/observation/updateObservation',
    ),
    '/observation/:observationId' => array(
        'GET' => '/gobs/observation/getObservation',
        'DELETE' => '/gobs/observation/deleteObservation',
    ),
);

jApp::loadConfig('gobsapi/config.ini.php');

jApp::setCoord(new jCoordinator());
jApp::coord()->process(new \Gobs\Request($mapping));
