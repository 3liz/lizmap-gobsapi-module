<?php

include jApp::getModulePath('gobs').'controllers/apiController.php';

class observationCtrl extends apiController
{
    /**
     * Create or update a new observation
     * /observation
     * Redirect to specific function depending on http method.
     *
     * @httpparam string Observation data in JSON
     *
     * @return jResponseJson Observation object created or updated
     */
    public function index()
    {

        // Get http method
        $method = $_SERVER['REQUEST_METHOD'];

        // Redirect depending on method
        if ($method == 'POST') {
            return $this->createObservation();
        }
        if ($method == 'PUT') {
            return $this->updateObservation();
        }

        return $this->apiResponse(
            '405',
            'error',
            '"observation/" api entry point only accepts POST OR PUT request method'
        );
    }

    /**
     * Create a new observation.
     *
     * @httpparam string Observation data in JSON
     *
     * @return jResponseJson Created observation object
     */
    private function createObservation()
    {
        $data = array();
        $this->objectResponse($data);
    }

    /**
     * Update a new observation.
     *
     * @httpparam string Observation data in JSON
     *
     * @return jResponseJson Updated observation object
     */
    private function updateObservation()
    {
        $data = array();
        $this->objectResponse($data);
    }

    /**
     * Create new observations by sending a list of objects
     * /observation/observations.
     *
     * @httpparam string Observation data in JSON (array of objects)
     * @httpresponse JSON with the list of created observations
     *
     * @return jResponseJson List of created observations
     */
    public function observations()
    {
        $data = array();
        $this->objectResponse($data);
    }

    /**
     * Get or delete an observation by UID
     * /observation/{observationId}
     * Redirect to specific function depending on http method.
     *
     * @httpparam string Observation UID
     *
     * @return jResponseJson Observation object or standard api response
     */
    public function observationId()
    {

        // Get http method
        $method = $_SERVER['REQUEST_METHOD'];

        // Redirect depending on method
        if ($method == 'GET') {
            return $this->getObservation();
        }
        if ($method == 'DELETE') {
            return $this->deleteObservation();
        }

        return $this->apiResponse(
            '405',
            'error',
            '"observation/{observationId}" api entry point only accepts GET OR DELETE request method'
        );
    }

    /**
     * Get an observation by UID
     * /observation/{observationId}.
     *
     * @param string Observation UID
     * @httpresponse JSON Observation data
     *
     * @return jResponseJson Observation data
     */
    private function getObservation()
    {
        $data = array();
        $this->objectResponse($data);
    }

    /**
     * Delete an observation by UID
     * /observation/{observationId}.
     *
     * @param string Observation UID
     * @httpresponse JSON Standard api response
     *
     * @return jResponseJson Standard api response
     */
    private function deleteObservation()
    {
        $this->apiResponse(
            '200',
            'success',
            'Observation successfully deleted'
        );
    }
}
