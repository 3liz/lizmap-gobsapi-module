<?php

class apiController extends jController
{
    protected $error_codes = array(
        'error' => 0,
        'success' => 1,
    );

    protected $http_codes = array(
        '200' => 'Successfull operation',
        '401' => 'Unauthorize',
        '400' => 'Bad Request',
        '403' => 'Forbidden',
        '404' => 'Not found',
        '405' => 'Method Not Allowed',
        '500' => 'Internal Server Error',
    );

    protected $user;

    protected $lizmap_project;

    protected $gobs_project;

    protected $indicator;

    protected $requestSyncDate = null;

    protected $lastSyncDate = null;

    /**
     * Authenticate the user via JWC token
     * Token is given in Authorization header as: Authorization: Bearer <token>.
     */
    protected function authenticate()
    {
        // Get token tool
        jClasses::inc('gobsapi~Token');
        $token_manager = new Token();

        // Get request token
        $token = $token_manager->getTokenFromHeader();
        if (!$token) {
            return false;
        }

        // Validate token
        $user = $token_manager->getUserFromToken($token);
        if (!$user) {
            return false;
        }

        // Add user in property
        $this->user = $user;

        // Add requestSyncDate & lastSyncDate
        $headers = jApp::coord()->request->headers();
        $sync_dates = array(
            'Requestsyncdate'=> 'requestSyncDate',
            'Lastsyncdate'=>'lastSyncDate'
        );
        foreach($sync_dates as $key=>$prop) {
            if (array_key_exists($key, $headers)) {
                $sync_date = $headers[$key];
                if ($this->isValidDate($sync_date)) {
                    $this->$prop = $sync_date;
                }
            }
        }

        return true;
    }

    // Check if the given project in parameter is valid and accessible
    protected function checkProject() {
        // Check projectKey parameter
        $project_key = $this->param('projectKey');
        if (!$project_key) {
            return array(
                '400',
                'error',
                'The projectKey parameter is mandatory',
            );
        }
        // Check project is valid
        try {
            $lizmap_project = lizmap::getProject($project_key);
            if (!$lizmap_project) {
                return array(
                    '404',
                    'error',
                    'The given project key does not refer to a known project',
                );
            }
        } catch (UnknownLizmapProjectException $e) {
            return array(
                '404',
                'error',
                'The given project key does not refer to a known project',
            );
        }

        // Check the authenticated user can access to the project
        if (!$lizmap_project->checkAcl($this->user['usr_login'])) {
            return array(
                '403',
                'error',
                jLocale::get('view~default.repository.access.denied'),
            );
        }

        // Set lizmap project property
        $this->lizmap_project = $lizmap_project;

        // Get gobs project manager
        jClasses::inc('gobsapi~Project');
        $gobs_project = new Project($lizmap_project);

        // Test if project has and indicator
        $indicators = $gobs_project->getIndicators();
        if (empty($indicators)) {
            return array(
                '404',
                'error',
                'The given project key does not refer to a G-Obs project',
            );
        }

        // Set project property
        $this->gobs_project = $gobs_project;

        // Ok
        return array('200', 'success', 'Project is a valid G-Obs project');

    }

    // Check if the given indicator in parameter is valid and accessible
    protected function checkIndicator() {
        // Check indicatorKey parameter
        $indicator_code = $this->param('indicatorCode');
        if (!$indicator_code) {
            return array(
                '400',
                'error',
                'The indicatorKey parameter is mandatory',
            );
        }

        // Get indicator
        jClasses::inc('gobsapi~Indicator');

        $gobs_indicator = new Indicator($indicator_code, $this->lizmap_project);

        // Check indicatorKey is valid
        if (!$gobs_indicator->checkCode()) {
            return array(
                '400',
                'error',
                'The indicatorKey parameter is invalid',
            );
        }

        // Check indicator exists
        $indicator = $gobs_indicator->get();
        if (!$indicator) {
            return array(
                '404',
                'error',
                'The given indicator code does not refer to a known indicator',
            );
        }

        // Set indicator property
        $this->indicator = $gobs_indicator;

        // Ok
        return array('200', 'success', 'Indicator is a valid G-Obs indicator');

    }

    /**
     * Validate a string containing date
     * @param string date String to validate. Ex: "2020-12-12 08:34:45"
     * @param string format Format of the date to validate against. Default "Y-m-d H:i:s"
     *
     * @return boolean
     */
    private function isValidDate($date, $format = 'Y-m-d H:i:s')
    {
        $d = DateTime::createFromFormat($format, $date);
        return $d && $d->format($format) == $date;
    }

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
