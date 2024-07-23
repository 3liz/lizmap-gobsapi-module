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
     * and given parameters.
     *
     * @param mixed $from
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
            'getObservationMedia',
        );
        $body_actions = array(
            'createObservation', 'updateObservation',
        );
        if (in_array($from, $uid_actions)) {
            // Observation uid is passed
            // Run the check
            list($code, $status, $message) = $this->checkUidActions($from);
        } elseif (in_array($from, $body_actions)) {
            // Observation is given in body
            // Run the check
            list($code, $status, $message) = $this->checkBodyActions($from);
        }

        return array(
            $code,
            $status,
            $message,
        );
    }

    // Check parameters for action having an observation id parameter
    private function checkUidActions($from)
    {
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

        // Set observation property
        $this->observation = $gobs_observation;

        return array(
            '200',
            'success',
            'Observation is a G-Obs observation',
        );

        // Unknown error
        return array('500', 'error', 'An unknown error has occured');
    }

    // Check parameters for actions having the body of an observation as parameter
    // It is mainly for observation creation and update
    private function checkBodyActions($from)
    {
        // Parameters
        $body = $this->request->readHttpBody();
        // Since Jelix 1.7, the body is given as an array and not as a string anymore.
        // Gobs Observation class expects it as a JSON string
        if (is_array($body)) {
            // For new versions, we must re-encode it as JSON
            $bodyString = json_encode($body);
        } else {
            $bodyString = $body;
        }

        $observation_uid = null;
        $gobs_observation = new Observation($this->user, $this->indicator, $observation_uid, $bodyString);

        // Check observation JSON
        $action = 'create';
        if ($from == 'updateObservation') {
            $action = 'update';
        }
        list($check_status, $check_code, $check_message) = $gobs_observation->checkObservationBodyJSONFormat($action);
        if ($check_status == 'error') {
            return array(
                $check_code,
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

        // Create a new series and related items if needed
        // Add series of observation for the authenticated user
        $spatial_layer_code = null;
        if ($gobs_observation->spatial_object !== null) {
            $spatial_layer_code = $gobs_observation->spatial_object->sl_code;
        }
        $series_id = $this->indicator->getOrAddGobsSeries($spatial_layer_code);
        if (!$series_id) {
            return array(
                '400',
                'error',
                'An error occurred while creating the needed series for this indicator and this user',
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
        }
        // Set observation property
        $this->observation = $gobs_observation;

        return array(
            '200',
            'success',
            'Observation is a G-Obs observation',
        );

        // Unknown error
        return array('500', 'error', 'An unknown error has occurred');
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
                $message,
                'createObservation',
                null,
                null
            );
        }

        list($status, $message, $data) = $this->observation->create();

        if ($status == 'error') {
            return $this->apiResponse(
                '400',
                $status,
                $message,
                'createObservation',
                null,
                null
            );
        }

        return $this->objectResponse($data, 'createObservation', null);
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
                $message,
                'updateObservation',
                null,
                null
            );
        }

        list($status, $message, $data) = $this->observation->update();

        if ($status == 'error') {
            return $this->apiResponse(
                '400',
                $status,
                $message,
                'updateObservation',
                null,
                null
            );
        }

        return $this->objectResponse($data, 'updateObservation', null);
    }

    /**
     * Get an observation by UID
     * /observation/{observationId}.
     *
     * @param string Observation UID
     *
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
                $message,
                'getObservationById',
                null,
                null
            );
        }

        list($status, $message, $data) = $this->observation->get();
        if ($status == 'error') {
            return $this->apiResponse(
                '400',
                $status,
                $message,
                'getObservationById',
                null,
                null
            );
        }

        return $this->objectResponse($data, 'getObservationById', null);
    }

    /**
     * Delete an observation by UID
     * /observation/{observationId}.
     *
     * @param string Observation UID
     *
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
                $message,
                'deleteObservationById',
                null,
                null
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
            $message,
            'deleteObservationById',
            null,
            null
        );
    }

    /**
     * Upload media for an observation by UID
     * /observation/{observationId}/uploadMedia.
     *
     * @param string Observation UID
     *
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
                $message,
                'uploadObservationMedia',
                null,
                null
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
            $message,
            'uploadObservationMedia',
            null,
            null
        );
    }

    /**
     * Delete an observation media by UID
     * /observation/{observationId}/deleteMedia.
     *
     * @param string Observation UID
     *
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
                $message,
                'deleteObservationMedia',
                null,
                null
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
            $message,
            'deleteObservationMedia',
            null,
            null
        );
    }

    /**
     * Get observation media file.
     */
    public function getObservationMedia()
    {
        $from = 'getObservationMedia';
        list($code, $status, $message) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message,
                'getObservationMedia',
                null,
                null
            );
        }

        // Get observation
        list($status, $message, $data) = $this->observation->get();
        $code = '200';
        if ($status == 'error') {
            return $this->apiResponse(
                '400',
                $status,
                $message,
                'getObservationMedia',
                null,
                null
            );
        }

        // Get media path
        list($status, $message, $filePath) = $this->observation->getMediaPath();
        if ($status == 'error') {
            return $this->apiResponse(
                '404',
                $status,
                $message,
                'getObservationMedia',
                null,
                null
            );
        }

        $outputFileName = $data->uuid;
        $doDownload = true;

        // Return binary geopackage file
        return $this->getMedia($filePath, $outputFileName);
    }
}
