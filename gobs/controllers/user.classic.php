<?php

class userCtrl extends jController {

//$method = $_SERVER['REQUEST_METHOD'];
//if ($method != 'GET') {
    //return $this->apiResponse(
        //'405',
        //'error',
        //'"user" api entry point only accepts GET request method'
    //);
//}

// Todo : use jexli plugin to describe in an array wich method is accepted for each function


    protected error_codes = array(
        'error' => 0,
        'success' => 1,
    );

    protected http_codes = array {
        '200' => 'Successfull operation',
        '400' => 'Bad Request',
        '405' => 'Method Not Allowed',
    }

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
        );
        return $rep;
    }


    /**
     * Generate a JWC token
     *
     * @param string username Username of the user logged in
     *
     * @return string JWC token
    **/
    private function generateToken($username) {
        // Todo: use PHP lib JWT
        // https://github.com/lcobucci/jwt/
        $jwt = md5($username);
        return $jwt;
    }


    /**
     * Validate a JWC token and give corresponding user name
     *
     * @param string token Token passed in Authentication header
     *
     * @return string Login of the corresponding user name
    **/
    private function validateToken($token) {
        // TODO
        if (True) {
            return True;
        } else {
            return False;
        }
    }


    /**
     * Destroy a JWC token
     *
     * @param string username Username of the user logged in
     *
     * @return string JWC token
    **/
    private function destroyToken($username) {
        // TODO
        // Invalidate token and related session

        return;
    }

    /**
     * Logs user into the system
     *
     * @httpmethod GET
     * @httpparam string username Username of the user to log in
     * @httpparam string password Password of the user to log in
     * @httpresponse {"token": "1mx6L2L7AMdEsyKy5LW9s8gt6mBxdICwosVn5sjhbwykOoQJFUru6752dwsj2THN"}
     *
     * @return jResponseJson JWC token or error code
    **/
    public function login() {
        $rep = $this->getResponse('json');

        // Parameters
        $username = $this->param('username');
        $password = $this->param('password');

        // Log the user
        $log_user = jAuth::login($username, $password);

        // Response
        if (!$log_user || !jAuth::isConnected()) {
            return $this->apiResponse(
                '400',
                'error',
                'Invalid username/password supplied'
            );
        }

        // Generate token
        // TODO use a real class for this
        $user = jAuth::getUserSession();
        $token = $this->generateJwcToken($user->login);

        // Return token
        $rep->setHttpStatus('200', 'Successfully authenticated');
        $data = array(
            'token' => $token
        );
        return $rep;
    }

    /**
     * Logs out current logged in user session. Invalidate the token
     *
     * @httpmethod GET
     * @httpparam string token JWC token passed as: Authorization: Bearer <token>
     *
     * @return jResponseJson Status of the logout
    **/
    public function logout() {
        $rep = $this->getResponse('json');

        // TODO: use PHP lib JWC

        // Get and validate the token
        $validate_token = $this->validateToken();
        if (!$validate_token) {
            return $this->apiResponse(
                '401',
                'error',
                'Access token is missing or invalid'
            );
        }

        // Log the user out
        $log_user = jAuth::logout($username);

        // Clear session and destroy token
        $this->destroyToken($login);

        // Return succces
        return $this->apiResponse(
            '200',
            'success',
            'The user has been successfully logged out'
        );

    }




    /**
     * Return project object(s) in JSON format
     *
     * @param array data Array containing the  projects
     * @httpresponse JSON with project data
     * @return jResponseJson
    **/
    private function projectResponse($data) {

        $rep = $this->getResponse('json');
        $rep->setHttpStatus('200', $this->http_codes[$http_code]);
        $rep->data = $data;
        return $rep;
    }


    /**
     * Get projects for authenticated user
     *
     * @httpmethod GET
     * @httpparam string token JWC token passed as: Authorization: Bearer <token>
     *
     * @return jResponseJson Status of the logout
    **/
    public function projects() {

        $data = array();
        $this->projectResponse($data);

    }


?>

