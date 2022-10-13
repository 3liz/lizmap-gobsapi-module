<?php

class apiController extends jController
{
    protected $error_codes = array(
        'error' => 0,
        'success' => 1,
    );

    protected $http_codes = array(
        '200' => 'Successful operation',
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

    protected $requestSyncDate;

    protected $lastSyncDate;

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
        $gobs_user = $token_manager->getUserFromToken($token);
        if (!$gobs_user) {
            return false;
        }

        // Add user in property
        $this->user = $gobs_user;

        // Add requestSyncDate & lastSyncDate
        $headers = jApp::coord()->request->headers();
        $sync_dates = array(
            'Requestsyncdate' => 'requestSyncDate',
            'Lastsyncdate' => 'lastSyncDate',
        );

        // Default values
        $this->lastSyncDate = '1970-01-01 00:00:00';
        $this->requestSyncDate = date('Y-m-d H:i:s');

        // Get lastSyncDate and requestSyncDate from headers
        foreach ($sync_dates as $key => $prop) {
            if (array_key_exists($key, $headers)) {
                $sync_date = $headers[$key];
                if ($this->isValidDate($sync_date)) {
                    $this->{$prop} = $sync_date;
                }
            }
        }

        return true;
    }

    // Check if the given project in parameter is valid and accessible
    protected function checkProject()
    {
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
        } catch (Exception $e) {
            return array(
                '404',
                'error',
                'The given project key does not refer to a known project',
            );
        }

        // Check the authenticated user can access to the project
        if (!$lizmap_project->checkAcl($this->user->login)) {
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

        // Create the corresponding actor in G-Obs database if needed
        $connection_profile = $gobs_project->getConnectionProfile();
        $gobs_actor = $this->user->createGobsActor($connection_profile);
        if (!$gobs_actor) {
            return array(
                '404',
                'error',
                'ERROR - G-Obs Actor in database cannot be found nor created !',
            );
        }

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
    protected function checkIndicator()
    {
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
        $connection_profile = $this->gobs_project->getConnectionProfile();
        $gobs_indicator = new Indicator($this->user, $indicator_code, $this->lizmap_project, $connection_profile);

        // Check indicatorKey is valid
        if (!$gobs_indicator->checkCode()) {
            return array(
                '400',
                'error',
                'The indicatorKey parameter is invalid',
            );
        }

        // Check indicator exists
        $indicator = $gobs_indicator->get('internal');
        if (!$indicator) {
            return array(
                '404',
                'error',
                'The given indicator code does not refer to a known indicator',
            );
        }

        // Add series of observation for the authenticated user
        $series_id = $gobs_indicator->getOrAddGobsSeries();
        if (!$series_id) {
            return array(
                '400',
                'error',
                'An error occured while creating the needed series for this indicator and this user',
            );
        }

        // Set indicator property
        $this->indicator = $gobs_indicator;

        // Ok
        return array('200', 'success', 'Indicator is a valid G-Obs indicator');
    }

    /**
     * Validate a string containing date.
     *
     * @param string date String to validate. Ex: "2020-12-12 08:34:45"
     * @param string format Format of the date to validate against. Default "Y-m-d H:i:s"
     * @param mixed $date
     * @param mixed $format
     *
     * @return bool
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
     * @param null|mixed $path
     * @param null|mixed $input_data
     * @param null|mixed $output_data
     *
     * @httpresponse JSON with code, status and message
     *
     * @return jResponseJson
     */
    protected function apiResponse($http_code = '200', $status = null, $message = null, $path = null, $input_data = null, $output_data = null)
    {
        $rep = $this->getResponse('json');
        $rep->setHttpStatus($http_code, $this->http_codes[$http_code]);

        if ($status) {
            $data = array(
                'code' => $this->error_codes[$status],
                'status' => $status,
                'message' => $message,
            );
            $rep->data = $data;
        }

        // Log
        $this->logQuery(
            $path,
            $input_data,
            $status,
            $http_code,
            $message,
            $output_data
        );

        return $rep;
    }

    /**
     * Return object(s) in JSON format.
     *
     * @param array data Array containing the  projects
     * @param mixed      $data
     * @param null|mixed $path
     * @param null|mixed $input_data
     *
     * @httpresponse JSON with project data
     *
     * @return jResponseJson
     */
    protected function objectResponse($data, $path = null, $input_data = null)
    {
        $rep = $this->getResponse('json');
        $http_code = '200';
        $rep->setHttpStatus($http_code, $this->http_codes[$http_code]);
        $rep->data = $data;

        // Log
        $message = null;
        $status = 'success';
        $this->logQuery(
            $path,
            $input_data,
            $status,
            $http_code,
            $message,
            $data
        );

        return $rep;
    }

    /**
     * Get media file: indicator document, observation media, project geopackage.
     *
     * @param mixed      $filePath
     * @param mixed      $outputFileName
     * @param null|mixed $mimeType
     * @param mixed      $doDownload
     */
    protected function getMedia($filePath, $outputFileName, $mimeType = null, $doDownload = true)
    {
        // Return binary geopackage file
        $rep = $this->getResponse('binary');
        $rep->doDownload = $doDownload;

        // Detect mime type if not given
        if (!$mimeType) {
            $mimeType = jFile::getMimeType($filePath);
        }
        $rep->mimeType = $mimeType;
        $rep->outputFileName = $outputFileName;

        // check file exists and return it or an error
        if (file_exists($filePath)) {
            $rep->fileName = $filePath;
            $rep->setExpires('+1 hours');
            $status = 'success';
            $message = null;
            $http_code = '200';
        } else {
            $status = 'error';
            $http_code = '404';
            $rep->fileName = null;
            $rep->mimeType = 'text/text';
            $rep->doDownload = false;
            $message = 'No file has been found in the specified path';
            $rep->content = $message;
            $rep->setHttpStatus($http_code, 'Not found');
        }

        // Log
        $this->logQuery(
            'getMedia',
            array('filePath' => $filePath),
            $status,
            $http_code,
            $message,
            null
        );

        return $rep;
    }

    /**
     * Log request query and status.
     *
     * @param mixed      $path
     * @param mixed      $input_data
     * @param mixed      $status
     * @param mixed      $http_code
     * @param mixed      $message
     * @param null|mixed $data
     */
    protected function logQuery($path, $input_data, $status, $http_code = null, $message = null, $data = null)
    {
        // Check if we must log or not
        $ini_file = jApp::varPath('config/gobsapi.ini.php');
        if (!is_file($ini_file)) {
            return;
        }
        $ini = parse_ini_file($ini_file, true);
        if (!array_key_exists('gobsapi', $ini)) {
            return;
        }
        if (!array_key_exists('log_api_calls', $ini['gobsapi'])) {
            return;
        }
        if ($ini['gobsapi']['log_api_calls'] != 'debug') {
            return;
        }
        $prefix = 'GOBSAPI';
        $level = 'default';

        // Add logged user to the prefix
        // to facilitate grepping the log
        $login = null;
        if ($this->user && $this->user->login) {
            $prefix .= ' / '.$this->user->login;
        }
        $prefix .= ' - ';

        // path. Ex: getProjectByKey
        $log = $prefix.'path: '.$path;
        \jLog::log($log, $level);

        // connection_name. Ex: gobs_test
        if (!empty($this->gobs_project->connectionName)) {
            $log = $prefix.'connection_name: '.$this->gobs_project->connectionName;
            \jLog::log($log, $level);
        }

        // input_data. Ex: {"projectKey":"lizmapdemo~lampadairess","module":"gobsapi","action":"project:getProjectByKey"}
        if (empty($input_data)) {
            $input_data = jApp::coord()->request->params;
        }
        if (!empty($input_data)) {
            $log = $prefix.'input_data: '.json_encode($input_data);
            \jLog::log($log, $level);
        }

        // http code. Ex: 404
        if (!empty($http_code)) {
            $log = $prefix.'http_code: '.$http_code;
            \jLog::log($log, $level);
        }

        // status. Ex:  success
        if (!empty($status)) {
            $log = $prefix.'status: '.$status;
            \jLog::log($log, $level);
        }

        // message. Ex: The given project key does not refer to a known project
        if (!empty($message)) {
            $log = $prefix.'message: '.$message;
            \jLog::log($log, $level);
        }

        // data. Ex: {"key":"lizmapdemo~lampadaires","label":"Paris by night","description":...}
        if (!empty($data)) {
            $log = $prefix.'data: '.json_encode($data);
            \jLog::log($log, $level);
        }

        // End of block
        $log = $prefix.'################';
        \jLog::log($log, $level);
    }
}
