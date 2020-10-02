<?php

class indicatorCtrl extends jController {

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
     * Return indicator object(s) in JSON format
     *
     * @param array data Array containing a single or many indicators
     * @httpresponse JSON with indicator data
     * @return jResponseJson
    **/
    private function indicatorResponse($data) {

        $rep = $this->getResponse('json');
        $rep->setHttpStatus('200', $this->http_codes[$http_code]);
        $rep->data = $data;
        return $rep;
    }

    /**
     * Get an indicator by Code
     * /indicator/{indicatorCode}
     * Redirect to specific function depending on http method
     *
     * @httpparam string Indicator Code
     *
     * @return jResponseJson Indicator object or standard api response
    **/
    public function indicatorCode() {

        // Get http method
        $method = $_SERVER['REQUEST_METHOD'];

        // Redirect depending on method
        if ($method == 'GET') {
            return $this->getIndicator();
        } else {
            return $this->apiResponse(
                '405',
                'error',
                '"indicator/{indicatorCode}" api entry point only accepts GET request method'
            );
        }
    }

    /**
     * Get an indicator by Code
     * /observation/{observationId}
     *
     * @param string Indicator Code
     * @httpresponse JSON Indicator data
     *
     * @return jResponseJson Indicator data
    **/
    private function getIndicator() {

        $data = array();
        $this->indicatorResponse($data);
    }

    /**
     * Get documents for an indicator by indicator Code
     * /indicator/{indicatorCode}/documents
     *
     * @param string Indicator Code
     * @httpresponse JSON documents data
     *
     * @return jResponseJson documents data
    **/
    private function documents() {

        $data = array();
        $this->indicatorResponse($data);
    }

    /**
     * Get observations for an indicator by indicator Code 
     * and Last synchronisation dates
     * /indicator/{indicatorCode}/observations
     *
     * @param string Indicator Code
     * @param string Indicator lastSyncDate
     * @param string Indicator requestSyncDate
     * @httpresponse JSON observations data
     *
     * @return jResponseJson observations data
    **/
    private function observations() {

        $data = array();
        $this->indicatorResponse($data);
    }

    /**
     * Get deleted observations for an indicator by indicator Code
     * and Last synchronisation dates
     * /indicator/{indicatorCode}/deletedObservations
     *
     * @param string Indicator Code
     * @param string Indicator lastSyncDate
     * @param string Indicator requestSyncDate
     * @httpresponse JSON observdeletedObservationsations data
     *
     * @return jResponseJson deletedObservations data
    **/
    private function deletedObservations() {

        $data = array();
        $this->indicatorResponse($data);
    }

}
?>
