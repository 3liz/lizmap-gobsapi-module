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
        $data = array();

        return $this->objectResponse($data);
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
    public function indicators()
    {
        $data = array();

        return $this->objectResponse($data);
    }
}
