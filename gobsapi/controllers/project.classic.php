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
                null,
            );
        }
        $user = $this->user;
        $login = $user['usr_login'];

        // Check projectKey parameter
        $project_key = $this->param('projectKey');
        if (!$project_key) {
            return array(
                '400',
                'error',
                'The projectKey parameter is mandatory',
                null,
            );
        }

        // Check project is valid
        try {
            $project = lizmap::getProject($project_key);
            if (!$project) {
                return array(
                    '404',
                    'error',
                    'The given project key does not refer to a known project',
                    null,
                );
            }
        } catch (UnknownLizmapProjectException $e) {
            return array(
                '404',
                'error',
                'The given project key does not refer to a known project',
                null,
            );
        }

        // Check the authenticated user can access to the project
        if (!$project->checkAcl($login)) {
            return array(
                '403',
                'error',
                jLocale::get('view~default.repository.access.denied'),
                null,
            );
        }

        // Get gobs project manager
        jClasses::inc('gobsapi~Project');
        $gobs_project = new Project($project);

        // Test if project has and indicator
        $indicators = $gobs_project->getProjectIndicators();
        if (!$indicators) {
            return array(
                '404',
                'error',
                'The given project key does not refer to a G-Obs project',
                null,
            );
        }

        // Ok
        return array('200', 'success', 'Project is a G-Obs project', $gobs_project);
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

        // Check project can be accessed and is a valid G-Obs project
        list($code, $status, $message, $gobs_project) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        // Get gobs project object
        $data = $gobs_project->get();

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

        // Check project can be accessed and is a valid G-Obs project
        list($code, $status, $message, $gobs_project) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        // Get indicator codes
        $indicator_codes = $gobs_project->getProjectIndicators();

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
