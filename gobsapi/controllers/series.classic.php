<?php

include jApp::getModulePath('gobsapi').'controllers/apiController.php';

class seriesCtrl extends apiController
{
    /**
     * Check access by the user
     * and given parameters.
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

        // Check project
        list($code, $status, $message) = $this->checkProject();
        if ($status == 'error') {
            return array(
                $code,
                $status,
                $message,
            );
        }

        // Check series
        list($code, $status, $message) = $this->checkSeries();
        if ($status == 'error') {
            return array(
                $code,
                $status,
                $message,
            );
        }

        return array('200', 'success', 'Series is a G-Obs series');
    }

    /**
     * Get a series by ID
     * /series/{seriesId}
     * Redirect to specific function depending on http method.
     *
     * @httpparam string Series ID
     *
     * @return jResponseJson Series object or standard api response
     */
    public function getSeriesById()
    {
        // Check series can be accessed and is a valid G-Obs series
        list($code, $status, $message) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message,
                'getSeriesById',
                null,
                null
            );
        }

        $series = $this->series->get('publication');

        return $this->objectResponse($series, 'getSeriesById', null);
    }

    /**
     * Get observations for a series by series ID
     * and Last synchronisation dates
     * /series/{seriesId}/observations.
     *
     * @param string Series ID
     * @param string Series lastSyncDate
     * @param string Series requestSyncDate
     *
     * @httpresponse JSON observations data
     *
     * @return jResponseJson observations data
     */
    public function getObservationsBySeries()
    {
        // Check series can be accessed and is a valid G-Obs series
        list($code, $status, $message) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message,
                'getObservationsBySeries',
                null,
                null
            );
        }

        $data = $this->series->getObservations(
            $this->requestSyncDate,
            $this->lastSyncDate
        );

        return $this->objectResponse($data, 'getObservationsBySeries', null);
    }

    /**
     * Get deleted observations for a series by series ID
     * and Last synchronisation dates
     * /series/{seriesId}/deletedObservations.
     *
     * @param string Series ID
     * @param string Series lastSyncDate
     * @param string Series requestSyncDate
     *
     * @httpresponse JSON deleted observations data
     *
     * @return jResponseJson deletedObservations data
     */
    public function getDeletedObservationsBySeries()
    {
        // Check resource can be accessed and is a valid G-Obs series
        list($code, $status, $message) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message,
                'getDeletedObservationsBySeries',
                null,
                null
            );
        }

        $data = $this->series->getDeletedObservations(
            $this->requestSyncDate,
            $this->lastSyncDate
        );

        return $this->objectResponse($data, 'getDeletedObservationsBySeries', null);
    }

    /**
     * Get indicator document file by uid.
     */
    public function getIndicatorDocument()
    {
        // Check resource can be accessed and is a valid G-Obs indicator
        list($code, $status, $message) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message,
                'getIndicatorDocument',
                null,
                null
            );
        }

        // Document uid
        $uid = $this->param('documentId');
        if (!$this->series->isValidUuid($uid)) {
            return $this->apiResponse(
                '400',
                'error',
                'Invalid document UID',
                'getIndicatorDocument',
                null,
                null
            );
        }

        $document = $this->series->getDocumentByUid($uid);
        if (empty($document)) {
            return $this->apiResponse(
                '404',
                'error',
                'The given document uid does not exist for this indicator',
                'getIndicatorDocument',
                null,
                null
            );
        }

        $filePath = $this->series->getDocumentPath($document);
        if (empty($filePath)) {
            return $this->apiResponse(
                '404',
                'error',
                'The document file does not exist',
                'getIndicatorDocument',
                null,
                null
            );
        }
        $outputFileName = $document->label;

        // Return binary file
        return $this->getMedia($filePath, $outputFileName);
    }
}
