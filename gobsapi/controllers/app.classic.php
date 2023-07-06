<?php

include jApp::getModulePath('gobsapi').'controllers/apiController.php';

class appCtrl extends apiController
{
    /**
     * Get the Lizmap Web Client metadata
     * and send it back to the requester.
     *
     * @httpmethod GET
     *
     * @return jResponseJson Full LWC metadata:
     */
    public function metadata()
    {
        /** @var jResponseJson $rep */
        $rep = $this->getResponse('json');

        // Authenticate
        $basicAuthUsed = false;
        if (isset($_SERVER['PHP_AUTH_USER'])) {
            $basicAuthUsed = true;
            $logUser = jAuth::login($_SERVER['PHP_AUTH_USER'], $_SERVER['PHP_AUTH_PW']);
        }

        // Get server metadata from LWC and QGIS Server Lizmap plugin
        $server = new \Lizmap\Server\Server();
        $data = $server->getMetadata();

        // Only show QGIS related data for admins
        $serverInfoAccess = (\jAcl2::check('lizmap.admin.access') || \jAcl2::check('lizmap.admin.server.information.view'));
        if (!$serverInfoAccess) {
            $data['qgis_server_info'] = array('error' => 'NO_ACCESS');
        }

        // If the user is not logged and has tried basic auth
        // Return a different error to let the plugin differentiate the two cases
        if ($basicAuthUsed && !$logUser) {
            $data['qgis_server_info'] = array('error' => 'WRONG_CREDENTIALS');
        }

        $rep->data = $data;

        return $rep;
    }
}
