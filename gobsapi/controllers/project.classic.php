<?php

include jApp::getModulePath('gobsapi').'controllers/apiController.php';

class projectCtrl extends apiController
{
    /**
     * Check access by the user
     * and given parameters
     */
    private function check()
    {
        // Get authenticated user
        $auth_ok = $this->authenticate();
        if (!$auth_ok) {
            return array(
                '401',
                'error',
                'Access token is missing or invalid',
            );
        }
        $user = $this->user;

        // Check project
        list($code, $status, $message) = $this->checkProject();
        if ($status == 'error') {
            return array(
                $code,
                $status,
                $message,
            );
        }

        // Ok
        return array('200', 'success', 'Project is a G-Obs project');
    }

    /**
     * Get a project by Key
     * /project/{projectKey}
     * Redirect to specific function depending on http method.
     *
     * @httpparam string Project Key
     *
     * @return jResponseJson Project object or standard api response
     */
    public function getProjectByKey()
    {
        // Check resource can be accessed and is valid
        list($code, $status, $message) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        // Get gobs project object
        $data = $this->gobs_project->get();

        return $this->objectResponse($data);
    }

    /**
     * Get indicators for a project by project Key
     * /project/{projectKey}/indicators.
     *
     * @param string Project Key
     * @httpresponse JSON Indicator data
     *
     * @return jResponseJson Indicator data
     */
    public function getProjectIndicators()
    {
        // Check resource can be accessed and is valid
        list($code, $status, $message) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        // Get indicator codes
        $indicator_codes = $this->gobs_project->getIndicators();

        // Get indicators
        $indicators = array();
        jClasses::inc('gobsapi~Indicator');
        foreach ($indicator_codes as $code) {
            $gobs_indicator = new Indicator($code, $this->lizmap_project);
            $indicator = $gobs_indicator->get('publication');
            $indicators[] = $indicator;
        }

        return $this->objectResponse($indicators);
    }

    /**
     * Get project Geopackage file
     *
     */
    public function getProjectGeopackage() {
        // Check resource can be accessed and is valid
        list($code, $status, $message) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        // Get gobs project object
        $data = $this->gobs_project->get();

        // Return binary geopackage file
        $rep = $this->getResponse('binary');
        $rep->doDownload = true;
        $rep->mimeType = 'application/geopackage+vnd.sqlite3';
        $rep->outputFileName = $data['key'].'.gpkg';

        // check gpkg file and return it or an error
        $gpkg_file_path = $this->lizmap_project->getQgisPath() . '.gpkg';
        if (file_exists($gpkg_file_path)) {
            $rep->fileName = $gpkg_file_path;
            $rep->setExpires('+1 hours');
        } else {
            $rep->fileName = null;
            $rep->mimeType = 'text/text';
            $rep->doDownload = false;
            $msg = 'No geopackage file has been found for this project';
            $rep->content = $msg;
            $rep->setHttpStatus(404, 'Not found');
        }

        return $rep;
    }
}
