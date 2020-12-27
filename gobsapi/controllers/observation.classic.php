<?php

include jApp::getModulePath('gobsapi').'controllers/apiController.php';

class observationCtrl extends apiController
{
    /**
     * @var observation_uid: Observation uuid
     */
    protected $observation_uid;

    /**
     * @var data G-Obs Representation of an observation or many observations
     */
    protected $data;

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
                null,
            );
        }
        $user = $this->user;

        // Get Observation class
        jClasses::inc('gobsapi~Observation');

        // Observation uid is passed
        $uid_actions = array(
            'getObservationById', 'deleteObservationById',
            'uploadObservationMedia', 'deleteObservationMedia'
        );
        if (in_array($from, $uid_actions)) {

            // Parameters
            $observation_uid = $this->param('observationId');

            $gobs_observation = new Observation($user, $observation_uid, null);

            // Check uid is valid
            if (!$gobs_observation->isValidUuid($observation_uid)) {
                return array(
                    '400',
                    'error',
                    'The observation id parameter is invalid',
                    null,
                );
            }

            // Check observation is valid
            if (!$gobs_observation->observation_valid) {
                return array(
                    '404',
                    'error',
                    'The observation does not exists',
                    null,
                );
            }

            // Check logged user can deleted the observation
            $capabilities = $gobs_observation->capabilities();
            if (!$capabilities['get']) {
                return array(
                    '401',
                    'error',
                    'The authenticated user hasnot right to access this observation',
                    null,
                );
            }
            if ($from != 'getObservationById' && !$capabilities['edit']) {
                return array(
                    '401',
                    'error',
                    'The authenticated user has not right to edit this observation',
                    null,
                );
            }
            else {
                return array('200', 'success', 'Observation is a G-Obs observation', $gobs_observation);
            }
        }

        // Body is given
        $body_actions = array(
            'createObservation', 'updateObservation'
        );
        if (in_array($from, $body_actions)) {
            // Body content is passed

            // Parameters
            $body = $this->request->readHttpBody();
            $gobs_observation = new Observation($user, null, $body);

            // Check observation JSON
            $action = 'create';
            if ($from == 'updateObservation') {
                $action = 'update';
            }
            list($check_status, $check_message) = $gobs_observation->checkObservationJsonFormat($action);
            if ($check_status == 'error') {
                return array(
                    '400',
                    'error',
                    $check_message,
                    null,
                );
            }

            // Check capabilities
            $capabilities = $gobs_observation->capabilities();
            if (!$capabilities['edit']) {
                return array(
                    '401',
                    'error',
                    'The authenticated user has not right to edit this observation',
                    null,
                );
            }

            return array('200', 'success', 'Observation is a G-Obs observation', $gobs_observation);

        }

        return array('500', 'error', 'An unknown error has occured', null);

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
        // Check observation can be accessed and is a valid G-Obs observation
        $from = 'createObservation';
        list($code, $status, $message, $gobs_observation) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        list($status, $message, $data) = $gobs_observation->create();

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
        // Check observation can be accessed and is a valid G-Obs observation
        $from = 'updateObservation';
        list($code, $status, $message, $gobs_observation) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        list($status, $message, $data) = $gobs_observation->update();

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
        // Check observation can be accessed and is a valid G-Obs observation
        $from = 'createObservations';
        list($code, $status, $message, $gobs_observation) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

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
    public function getObservationById()
    {
        // Check observation can be accessed and is a valid G-Obs observation
        $from = 'getObservationById';
        list($code, $status, $message, $gobs_observation) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        list($status, $message, $data) = $gobs_observation->get();
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
        // Check observation can be accessed and is a valid G-Obs observation
        $from = 'deleteObservationById';
        list($code, $status, $message, $gobs_observation) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        list($status, $message, $data) = $gobs_observation->delete();
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
        list($code, $status, $message, $gobs_observation) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        // Proces form data
        list($status, $message, $data) = $gobs_observation->processMediaForm();
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
        list($code, $status, $message, $gobs_observation) = $this->check($from);
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        // Proces form data
        list($status, $message, $data) = $gobs_observation->deleteMedia();
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
}
