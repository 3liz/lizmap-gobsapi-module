<?php

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
    public function projectKey()
    {

        // Get http method
        $method = $_SERVER['REQUEST_METHOD'];

        // Redirect depending on method
        if ($method == 'GET') {
            return $this->getProject();
        }

        return $this->apiResponse(
            '405',
            'error',
            '"project/{projectKey}" api entry point only accepts GET request method'
        );
    }

    /**
     * Get a project by Key
     * /project/{projectKey}.
     *
     * @param string Project Key
     * @httpresponse JSON Project data
     *
     * @return jResponseJson Project data
     */
    private function getProject()
    {
        $data = array();
        $this->objectResponse($data);
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
    private function indicators()
    {
        $data = array();
        $this->objectResponse($data);
    }
}
