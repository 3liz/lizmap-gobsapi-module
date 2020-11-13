<?php

include jApp::getModulePath('gobsapi').'controllers/apiController.php';

class observationCtrl extends apiController
{

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

        return $this->objectResponse($data);
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

        return $this->objectResponse($data);
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
    public function createObservations()
    {
        $data = array();

        return $this->objectResponse($data);
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
    private function getObservationById()
    {
        $data = array();

        return $this->objectResponse($data);
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
    private function deleteObservationById()
    {
        return $this->apiResponse(
            '200',
            'success',
            'Observation successfully deleted'
        );
    }
}
