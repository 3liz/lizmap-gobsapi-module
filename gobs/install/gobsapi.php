<?php
/**
 * Entry point for G-Obs API
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
    '/user/login' => '/gobs/user/logUserIn',
    '/project/:projectkey' => '/gobs/project/getProjectByKey',
    '/observation' => array(
            'POST'=>'/gobs/observation/createObservation',
            'PUT'=>'/gobs/observation/updateObservation'
    ),
    '/observation/:obsid' => array(
            'GET'=>'/gobs/observation/getObservation',
            'DELETE'=>'/gobs/observation/deleteObservation'
    ),
);

jApp::loadConfig('gobsapi/config.ini.php');

jApp::setCoord(new jCoordinator());
jApp::coord()->process(new \Gobs\Request($mapping));

