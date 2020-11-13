<?php

include jApp::getModulePath('gobsapi').'controllers/apiController.php';

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
    public function getIndicatorByCode()
    {

        $data = array();

        return $this->objectResponse($data);

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
    private function getIndicatorDocuments()
    {
        $data = array();

        return $this->objectResponse($data);
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
    private function getObservationsByIndicator()
    {
        $data = array();

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
    private function getDeletedObservationsByIndicator()
    {
        $data = array();

        return $this->objectResponse($data);
    }
}
