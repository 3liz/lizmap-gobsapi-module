<?php

class observationCtrl extends jController {

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
     * Return observation object(s) in JSON format
     *
     * @param array data Array containing a single or many observations
     * @httpresponse JSON with observation data
     * @return jResponseJson
    **/
    private function observationResponse($data) {

        $rep = $this->getResponse('json');
        $rep->setHttpStatus('200', $this->http_codes[$http_code]);
        $rep->data = $data;
        return $rep;
    }

    /**
     * Create or update a new observation
     * /observation
     * Redirect to specific function depending on http method
     *
     * @httpparam string Observation data in JSON
     *
     * @return jResponseJson Observation object created or updated
    **/
    public function index() {

        // Get http method
        $method = $_SERVER['REQUEST_METHOD'];

        // Redirect depending on method
        if ($method == 'POST') {
            return $this->createObservation();
        } elseif ($method == 'PUT') {
            return $this->updateObservation();
        } else {
            return $this->apiResponse(
                '405',
                'error',
                '"observation/" api entry point only accepts POST OR PUT request method'
            );
        }
    }


    /**
     * Create a new observation
     *
     * @httpparam string Observation data in JSON
     *
     * @return jResponseJson Created observation object
    **/
    private function createObservation() {

        $data = array();
        $this->observationResponse($data);
    }

    /**
     * Update a new observation
     *
     * @httpparam string Observation data in JSON
     *
     * @return jResponseJson Updated observation object
    **/
    private function updateObservation() {

        $data = array();
        $this->observationResponse($data);
    }


    /**
     * Create new observations by sending a list of objects
     * /observation/observations
     *
     * @httpparam string Observation data in JSON (array of objects)
     * @httpresponse JSON with the list of created observations
     *
     * @return jResponseJson List of created observations
    **/
    public function observations() {

        $data = array();
        $this->observationResponse($data);
    }


    /**
     * Get or delete an observation by UID
     * /observation/{observationId}
     * Redirect to specific function depending on http method
     *
     * @httpparam string Observation UID
     *
     * @return jResponseJson Observation object or standard api response
    **/
    public function observationId() {

        // Get http method
        $method = $_SERVER['REQUEST_METHOD'];

        // Redirect depending on method
        if ($method == 'GET') {
            return $this->getObservation();
        } elseif ($method == 'DELETE') {
            return $this->deleteObservation();
        } else {
            return $this->apiResponse(
                '405',
                'error',
                '"observation/{observationId}" api entry point only accepts GET OR DELETE request method'
            );
        }
    }

    /**
     * Get an observation by UID
     * /observation/{observationId}
     *
     * @param string Observation UID
     * @httpresponse JSON Observation data
     *
     * @return jResponseJson Observation data
    **/
    private function getObservation() {

        $data = array();
        $this->observationResponse($data);
    }

    /**
     * Delete an observation by UID
     * /observation/{observationId}
     *
     * @param string Observation UID
     * @httpresponse JSON Standard api response
     *
     * @return jResponseJson Standard api response
    **/
    private function deleteObservation() {

        $this->apiResponse('200', 'success', 'Observation successfully deleted');
    }

}
?>
