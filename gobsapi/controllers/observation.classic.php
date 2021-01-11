<?php

include jApp::getModulePath('gobsapi').'controllers/apiController.php';

class observationCtrl extends apiController
{
    /**
     * @var observation_uid: Observation uuid
     */
    protected $observation_uid;

    /**
     * @var observation G-Obs Representation of an observation or many observations
     */
    protected $observation;

    /**
     * @var access Boolean saying if the user has the right to edit the observation
     */
    protected $access;

    /**
     * Check access by the user
     * and given parameters
     */
    private function check($from)
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

        // Check indicator
        list($code, $status, $message) = $this->checkIndicator();
        if ($status == 'error') {
            return array(
                $code,
                $status,
                $message,
            );
        }

        // Get Observation class
        jClasses::inc('gobsapi~Observation');

        // Check parameters given for /observation/ path
        $uid_actions = array(
            'getObservationById', 'deleteObservationById',
            'uploadObservationMedia', 'deleteObservationMedia',
            'getObservationMedia'
        );
        $body_actions = array(
            'createObservation', 'updateObservation'
        );
        if (in_array($from, $uid_actions)) {
            // Observation uid is passed
            $check_method = 'checkUidActions';
        } elseif (in_array($from, $body_actions)) {
            // Observation is given in body
            $check_method = 'checkBodyActions';
        }

        // Run the check
        list($code, $status, $message) = $this->$check_method($from);
        return array(
            $code,
            $status,
            $message,
        );

    }

    // Check parameters for action having an observation id parameter
    private function checkUidActions($from) {
        // Parameters
        $observation_uid = $this->param('observationId');

        $gobs_observation = new Observation($this->user, $this->indicator, $observation_uid, null);

        // Check uid is valid
        if (!$gobs_observation->isValidUuid($observation_uid)) {
            return array(
                '400',
                'error',
                'The observation id parameter is invalid',
            );
        }

        // Check observation is valid
        if (!$gobs_observation->observation_valid) {
            return array(
                '404',
                'error',
                'The observation does not exists',
            );
        }

        // Check logged user can deleted the observation
        $context = 'read';
        if ($from != 'getObservationById') {
            $context = 'modify';
        }
        $capabilities = $gobs_observation->getCapabilities($context);
        if (!$capabilities['get']) {
            return array(
                '401',
                'error',
                'The authenticated user has not right to access this observation',
            );
        }
        if (!in_array($from, array('getObservationById', 'getObservationMedia')) && !$capabilities['edit']) {
            return array(
                '401',
                'error',
                'The authenticated user has not right to modify this observation',
            );
        }
        else {
            // Set observation property
            $this->observation = $gobs_observation;

            return array(
                '200',
                'success',
                'Observation is a G-Obs observation'
            );
        }

        // Unknown error
        return array('500', 'error', 'An unknown error has occured');
    }

    // Check parameters for actions having the body of an observation as parameter
    private function checkBodyActions($from) {
        // Parameters
        $body = $this->request->readHttpBody();
        $gobs_observation = new Observation($this->user, $this->indicator, null, $body);

        // Check observation JSON
        $action = 'create';
        if ($from == 'updateObservation') {
            $action = 'update';
        }
        list($check_status, $check_message) = $gobs_observation->checkObservationBodyJSONFormat($action);
        if ($check_status == 'error') {
            return array(
                '400',
                'error',
                $check_message,
            );
        }

        // Check observation is valid
        if (!$gobs_observation->observation_valid) {
            return array(
                '404',
                'error',
                'The observation is not valid',
            );
        }

        // Check capabilities
        $context = 'create';
        if ($from != 'createObservation') {
            $context = 'modify';
        }
        $capabilities = $gobs_observation->getCapabilities($context);

        if (!$capabilities['edit']) {
            return array(
                '401',
                'error',
                'The authenticated user has not right to '.$context.' this observation',
            );
        } else {
            // Set observation property
            $this->observation = $gobs_observation;

            return array(
                '200',
                'success',
                'Observation is a G-Obs observation'
            );
        }

        // Unknown error
        return array('500', 'error', 'An unknown error has occured');

    }

    /**
     * Create a new observation.
     *
     * @httpparam string Observation data in JSON
     *
     * @return jResponseJson Created observation object
     */
    public function createObservation()
    {
        // Check resource can be accessed and is valid
        $from = 'createObservation';
        list($code, $status, $message) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        list($status, $message, $data) = $this->observation->create();

        if ($status == 'error') {
            return $this->apiResponse(
                '400',
                $status,
                $message
            );
        }

        return $this->objectResponse($data);
    }

    /**
     * Update a new observation.
     *
     * @httpparam string Observation data in JSON
     *
     * @return jResponseJson Updated observation object
     */
    public function updateObservation()
    {
        // Check resource can be accessed and is valid
        $from = 'updateObservation';
        list($code, $status, $message) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        list($status, $message, $data) = $this->observation->update();

        if ($status == 'error') {
            return $this->apiResponse(
                '400',
                $status,
                $message
            );
        }

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
    public function getObservationById()
    {
        // Check resource can be accessed and is valid
        $from = 'getObservationById';
        list($code, $status, $message) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        list($status, $message, $data) = $this->observation->get();
        if ($status == 'error') {
            return $this->apiResponse(
                '400',
                $status,
                $message
            );
        }

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
    public function deleteObservationById()
    {
        // Check resource can be accessed and is valid
        $from = 'deleteObservationById';
        list($code, $status, $message) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        list($status, $message, $data) = $this->observation->delete();
        $code = '200';
        if ($status == 'error') {
            $code = '400';
        }

        // Return response
        return $this->apiResponse(
            $code,
            $status,
            $message
        );
    }

    /**
     * Upload media for an observation by UID
     * /observation/{observationId}/uploadMedia.
     *
     * @param string Observation UID
     * @httpresponse JSON Standard api response
     *
     * @return jResponseJson Standard api response
     */
    public function uploadObservationMedia()
    {
        $from = 'uploadObservationMedia';
        list($code, $status, $message) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        // Proces form data
        list($status, $message, $data) = $this->observation->processMediaForm();
        $code = '200';
        if ($status == 'error') {
            $code = '400';
        }

        // Return response
        return $this->apiResponse(
            $code,
            $status,
            $message
        );
    }

    /**
     * Delete an observation media by UID
     * /observation/{observationId}/deleteMedia.
     *
     * @param string Observation UID
     * @httpresponse JSON Standard api response
     *
     * @return jResponseJson Standard api response
     */
    public function deleteObservationMedia()
    {
        $from = 'deleteObservationMedia';
        list($code, $status, $message) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        // Proces form data
        list($status, $message, $data) = $this->observation->deleteMedia();
        $code = '200';
        if ($status == 'error') {
            $code = '400';
        }

        // Return response
        return $this->apiResponse(
            $code,
            $status,
            $message
        );
    }

    /**
     * Get observation media file
     *
     */
    public function getObservationMedia() {
        $from = 'getObservationMedia';
        list($code, $status, $message) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        // Get observation
        list($status, $message, $data) = $this->observation->get();
        $code = '200';
        if ($status == 'error') {
            return $this->apiResponse(
                '400',
                $status,
                $message
            );
        }

        // Get media path
        list($status, $message, $filePath) = $this->observation->getMediaPath();
        if ($status == 'error') {
            return $this->apiResponse(
                '404',
                $status,
                $message
            );
        }

        $outputFileName = $data->uuid;
        $doDownload = true;

        // Return binary geopackage file
        return $this->getMedia($filePath, $outputFileName);
    }

}
