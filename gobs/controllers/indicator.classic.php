<?php

include jApp::getModulePath('gobs').'controllers/apiController.php';

class indicatorCtrl extends apiController
{
    /**
     * Get an indicator by Code
     * /indicator/{indicatorCode}
     * Redirect to specific function depending on http method.
     *
     * @httpparam string Indicator Code
     *
     * @return jResponseJson Indicator object or standard api response
     */
    public function indicatorCode()
    {

        // Get http method
        $method = $_SERVER['REQUEST_METHOD'];

        // Redirect depending on method
        if ($method == 'GET') {
            return $this->getIndicator();
        }

        return $this->apiResponse(
            '405',
            'error',
            '"indicator/{indicatorCode}" api entry point only accepts GET request method'
        );
    }

    /**
     * Get an indicator by Code
     * /observation/{observationId}.
     *
     * @param string Indicator Code
     * @httpresponse JSON Indicator data
     *
     * @return jResponseJson Indicator data
     */
    private function getIndicator()
    {
        $data = array();
        $this->objectResponse($data);
    }

    /**
     * Get documents for an indicator by indicator Code
     * /indicator/{indicatorCode}/documents.
     *
     * @param string Indicator Code
     * @httpresponse JSON documents data
     *
     * @return jResponseJson documents data
     */
    private function documents()
    {
        $data = array();
        $this->objectResponse($data);
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
    private function observations()
    {
        $data = array();
        $this->objectResponse($data);
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
    private function deletedObservations()
    {
        $data = array();
        $this->objectResponse($data);
    }
}
