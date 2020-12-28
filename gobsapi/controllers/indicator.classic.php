<?php

include jApp::getModulePath('gobsapi').'controllers/apiController.php';

class indicatorCtrl extends apiController
{
    /**
     * Check access by the user
     * and given parameters
     */
    private function check()
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

        return array('200', 'success', 'Indicator is a G-Obs indicator');

    }

    /**
     * Get an indicator by Code
     * /indicator/{indicatorCode}
     * Redirect to specific function depending on http method.
     *
     * @httpparam string Indicator Code
     *
     * @return jResponseJson Indicator object or standard api response
     */
    public function getIndicatorByCode()
    {

        // Check indicator can be accessed and is a valid G-Obs indicator
        list($code, $status, $message) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        $indicator = $this->indicator->get('publication');

        return $this->objectResponse($indicator);
    }

    /**
     * Get observations for an indicator by indicator Code
     * and Last synchronisation dates
     * /indicator/{indicatorCode}/observations.
     *
     * @param string Indicator Code
     * @param string Indicator lastSyncDate
     * @param string Indicator requestSyncDate
     * @httpresponse JSON observations data
     *
     * @return jResponseJson observations data
     */
    public function getObservationsByIndicator()
    {

        // Check indicator can be accessed and is a valid G-Obs indicator
        list($code, $status, $message) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        $data = $this->indicator->getObservations(
            $this->requestSyncDate,
            $this->lastSyncDate
        );

        return $this->objectResponse($data);
    }

    /**
     * Get deleted observations for an indicator by indicator Code
     * and Last synchronisation dates
     * /indicator/{indicatorCode}/deletedObservations.
     *
     * @param string Indicator Code
     * @param string Indicator lastSyncDate
     * @param string Indicator requestSyncDate
     * @httpresponse JSON observdeletedObservationsations data
     *
     * @return jResponseJson deletedObservations data
     */
    public function getDeletedObservationsByIndicator()
    {
        // Check resource can be accessed and is a valid G-Obs indicator
        list($code, $status, $message) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        $data = $this->indicator->getDeletedObservations(
            $this->requestSyncDate,
            $this->lastSyncDate
        );

        return $this->objectResponse($data);
    }
}
