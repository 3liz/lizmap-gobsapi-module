<?php

class apiController extends jController
{
    protected $error_codes = array(
        'error' => 0,
        'success' => 1,
    );

    protected $http_codes = array(
        '200' => 'Successfull operation',
        '400' => 'Bad Request',
        '405' => 'Method Not Allowed',
    );

    /**
     * Return api response in JSON format
     * E.g. {"code": 0, "status": "error", "message":  "Method Not Allowed"}.
     *
     * @param string http_code HTTP status code. Ex: 200
     * @param string status 'error' or 'success'
     * @param string message Message with response content
     * @param mixed      $http_code
     * @param null|mixed $status
     * @param null|mixed $message
     * @httpresponse JSON with code, status and message
     *
     * @return jResponseJson
     */
    protected function apiResponse($http_code = '200', $status = null, $message = null)
    {
        $rep = $this->getResponse('json');
        $rep->setHttpStatus($http_code, $this->http_codes[$http_code]);

        if ($status) {
            $rep->data = array(
                'code' => $this->error_codes[$status],
                'status' => $status,
                'message' => $message,
            );
        }

        return $rep;
    }

    /**
     * Return object(s) in JSON format.
     *
     * @param array data Array containing the  projects
     * @param mixed $data
     * @httpresponse JSON with project data
     *
     * @return jResponseJson
     */
    protected function objectResponse($data)
    {
        $rep = $this->getResponse('json');
        $http_code = '200';
        $rep->setHttpStatus($http_code, $this->http_codes[$http_code]);
        $rep->data = $data;

        return $rep;
    }
}
