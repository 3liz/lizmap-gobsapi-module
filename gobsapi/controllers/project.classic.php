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
        $data = $this->project->get();

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
        $indicator_codes = $this->project->getIndicators();

        // Get indicators
        $indicators = array();
        jClasses::inc('gobsapi~Indicator');
        foreach ($indicator_codes as $code) {
            $gobs_indicator = new Indicator($code);
            $indicator = $gobs_indicator->get();
            $indicators[] = $indicator;
        }

        return $this->objectResponse($indicators);
    }
}
