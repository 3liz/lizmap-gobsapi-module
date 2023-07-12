<?php

include jApp::getModulePath('gobsapi').'controllers/apiController.php';

class projectCtrl extends apiController
{
    /**
     * Check access by the user
     * and given parameters.
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
                $message,
                'getProjectByKey',
                null,
                null
            );
        }

        // Get gobs project object
        $data = $this->gobs_project->get();

        return $this->objectResponse($data, 'getProjectByKey', null);
    }

    /**
     * Get indicators for a project by project Key
     * /project/{projectKey}/indicators.
     *
     * @param string Project Key
     *
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
                $message,
                'getProjectIndicators',
                null,
                null
            );
        }

        // Get indicator codes
        $indicator_codes = $this->gobs_project->getIndicators();

        // Get indicators
        $indicators = array();
        jClasses::inc('gobsapi~Indicator');
        $project_key = $this->gobs_project->getKey();
        foreach ($indicator_codes as $code) {
            $connection_profile = $this->gobs_project->getConnectionProfile();
            $gobs_indicator = new Indicator(
                $this->user, $code,
                $project_key, $connection_profile,
                $this->gobs_project->getAllowedPolygon()
            );
            $indicator = $gobs_indicator->get('publication');
            $indicators[] = $indicator;
        }

        return $this->objectResponse($indicators, 'getProjectIndicators', null);
    }

    /**
     * Get project Geopackage file.
     */
    public function getProjectGeopackage()
    {
        // Check resource can be accessed and is valid
        list($code, $status, $message) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message,
                'getProjectGeopackage',
                null,
                null
            );
        }

        // Get gobs project object
        $data = $this->gobs_project->get();

        jClasses::inc('gobsapi~Utils');
        $utils = new Utils();
        $root_dir = $utils->getMediaRootDirectory();
        $project_key = $this->param('projectKey');
        $gpkg_dir = '/gobsapi/geopackage/'.$project_key.'.gpkg';
        $filePath = $root_dir.$gpkg_dir;
        $outputFileName = $data['key'].'.gpkg';
        $mimeType = 'application/geopackage+vnd.sqlite3';
        $doDownload = true;

        // Return binary geopackage file
        return $this->getMedia($filePath, $outputFileName, $mimeType, $doDownload);
    }

    /**
     * Get project illustration image.
     */
    public function getProjectIllustration()
    {
        // Check resource can be accessed and is valid
        list($code, $status, $message) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message,
                'getProjectIllustration',
                null,
                null
            );
        }

        // Get gobs project object
        $data = $this->gobs_project->get();

        jClasses::inc('gobsapi~Utils');
        $utils = new Utils();
        $root_dir = $utils->getMediaRootDirectory();
        $project_key = $this->param('projectKey');

        $root_dir = $utils->getMediaRootDirectory();
        $media_dir = '/gobsapi/illustration/'.$project_key;

        // default image
        $filePath = jApp::wwwPath('img/lizmap_mappemonde.jpg');
        $outputFileName = 'default.png';
        $mimeType = 'image/png';

        // Search for illustration for each allowed extensions
        $extensions = array('jpg', 'jpeg', 'png');
        foreach ($extensions as $extension) {
            $media_file_path = $root_dir.$media_dir.'.'.$extension;
            if (file_exists($media_file_path)) {
                $filePath = $media_file_path;
                $outputFileName = $data['key'].'.'.$extension;
                $mimeType = 'image/'.$extension;

                break;
            }
        }
        $doDownload = true;

        // Return binary geopackage file
        return $this->getMedia($filePath, $outputFileName, $mimeType, $doDownload);
    }
}
