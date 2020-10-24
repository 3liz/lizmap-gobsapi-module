<?php

//TODO: utiliser un plugin de coordinateur pour tester les méthodes HTTP
//$method = $_SERVER['REQUEST_METHOD'];
//if ($method != 'GET') {

    //return $this->apiResponse(
        //'405',
        //'error',
        //'"project/{projectKey}" api entry point only accepts GET request method'
    //);
//}

include jApp::getModulePath('gobs').'controllers/apiController.php';

class projectCtrl extends apiController
{
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
        // Check projectKey parameter
        $project_key = $this->param('projectKey');
        if (!$project_key) {
            return $this->apiResponse(
                '400',
                'error',
                'The projectKey parameter is mandatory !'
            );
        }

        // Check project is valid
        try {
            $project = lizmap::getProject($project_key);
            if (!$project) {
                return $this->apiResponse(
                    '404',
                    'error',
                    'The given project key does not refer to a known project'
                );
            }
        } catch (UnknownLizmapProjectException $e) {
            return $this->apiResponse(
                '404',
                'error',
                'The given project key does not refer to a known project'
            );
        }

        // Check the authenticated user can access to the project
        if (!$project->checkAcl()) {
            return $this->apiResponse(
                '403',
                'error',
                jLocale::get('view~default.repository.access.denied')
            );
        }

        // Get project
        jClasses::inc('gobs~Project');
        $gobs_project = new Project($project);
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
        $data = array();

        return $this->objectResponse($data);
    }
}
