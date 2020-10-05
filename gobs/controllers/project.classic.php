<?php

class projectCtrl extends jController {

    protected $error_codes = array(
        'error' => 0,
        'success' => 1,
    );

    protected $http_codes = array (
        '200' => 'Successfull operation',
        '400' => 'Bad Request',
        '405' => 'Method Not Allowed',
    );

    /**
     * Return api response in JSON format
     * E.g. {"code": 0, "status": "error", "message":  "Method Not Allowed"}
     *
     * @param string http_code HTTP status code. Ex: 200
     * @param string status 'error' or 'success'
     * @param string message Message with response content
     * @httpresponse JSON with code, status and message
     * @return jResponseJson
    **/
    private function apiResponse($http_code='200', $status=Null, $message=Null) {

        $rep = $this->getResponse('json');
        $rep->setHttpStatus($http_code, $this->http_codes[$http_code]);

        if ($status) {
            $rep->data = array(
                'code' => $this->error_codes[$status],
                'status' => $status,
                'message' => $message
            );
        }
        return $rep;
    }

    /**
     * Return project object(s) in JSON format
     *
     * @param array data Array containing a single or many projects
     * @httpresponse JSON with project data
     * @return jResponseJson
    **/
    private function projectResponse($data) {

        $rep = $this->getResponse('json');
        $rep->setHttpStatus('200', $this->http_codes[$http_code]);
        $rep->data = $data;
        return $rep;
    }

    /**
     * Get a project by Key
     * /project/{projectKey}
     * Redirect to specific function depending on http method
     *
     * @httpparam string Project Key
     *
     * @return jResponseJson Project object or standard api response
    **/
    public function projectKey() {

        // Get http method
        $method = $_SERVER['REQUEST_METHOD'];

        // Redirect depending on method
        if ($method == 'GET') {
            return $this->getProject();
        } else {
            return $this->apiResponse(
                '405',
                'error',
                '"project/{projectKey}" api entry point only accepts GET request method'
            );
        }
    }

    /**
     * Get a project by Key
     * /project/{projectKey}
     *
     * @param string Project Key
     * @httpresponse JSON Project data
     *
     * @return jResponseJson Project data
    **/
    private function getProject(){

        $data = array();
        $this->projectResponse($data);
    }

    /**
     * Get indicators for a project by project Key
     * /project/{projectKey}/indicators
     *
     * @param string Project Key
     * @httpresponse JSON Indicator data
     *
     * @return jResponseJson Indicator data
    **/
    private function indicators(){

        $data = array();
        $this->projectResponse($data);
    }

}
?>
