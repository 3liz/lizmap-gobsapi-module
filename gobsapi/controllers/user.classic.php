<?php

include jApp::getModulePath('gobsapi').'controllers/apiController.php';

class userCtrl extends apiController
{
    /**
     * Logs user into the system and returns JWC token.
     *
     * @httpmethod GET
     *
     * @param string username Username of the user to log in
     * @param string password Password of the user to log in
     *
     * @return jResponseJson JWC token or error code:
     *                       {"token": "1mx6L2L7AMdEsyKy5LW9s8gt6mBxdICwosVn5sjhbwykOoQJFUru6752dwsj2THN"}
     */
    public function logUserIn()
    {
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
                'Invalid username/password supplied',
                'logUserIn',
                array('login' => $username),
                null
            );
        }

        // Get logged user
        $jelix_user = jAuth::getUserSession();
        $login = $jelix_user->login;

        // Generate token
        jClasses::inc('gobsapi~Token');
        $token_manager = new Token();
        $token = $token_manager->generateToken($login);

        // Return token
        $rep->setHttpStatus('200', 'Successfully authenticated');
        $data = array(
            'token' => $token,
        );
        $rep->data = $data;

        // Log
        $message = null;
        $status = 'success';
        $this->logQuery(
            'logUserIn',
            array('login' => $login),
            $status,
            '200',
            $message,
            $data
        );

        return $rep;
    }

    /**
     * Logs out current logged in user session. Invalidate the token.
     *
     * @httpmethod GET
     * @httpparam string token JWC token passed as: Authorization: Bearer <token>
     *
     * @return jResponseJson Status of the logout
     */
    public function logUserOut()
    {
        // Get to
        jClasses::inc('gobsapi~Token');
        $token_manager = new Token();

        // Get request token
        $token = $token_manager->getTokenFromHeader();

        if (!$token) {
            return $this->apiResponse(
                '401',
                'error',
                'Access token is missing or invalid',
                'logUserOut',
                array('token' => $token),
                null
            );
        }

        // Validate token
        $gobs_user = $token_manager->getUserFromToken($token);
        if (!$gobs_user->login) {
            return $this->apiResponse(
                '401',
                'error',
                'Access token is missing or invalid',
                'logUserOut',
                array('token' => $token),
                null
            );
        }

        // Log the user out. Can be useless because no session, but usefull for sending events
        $login = $gobs_user->login;
        $log_user_out = jAuth::logout($login);

        // Destroy token
        $token_manager->destroyToken($token);

        // Return succces
        return $this->apiResponse(
            '200',
            'success',
            'The user has been successfully logged out',
            'logUserOut',
            array('login' => $login),
            null
        );
    }

    /**
     * Get projects for authenticated user.
     *
     * @httpmethod GET
     * @httpparam string token JWC token passed as: Authorization: Bearer <token>
     *
     * @return jResponseJson Status of the logout
     */
    public function getUserProjects()
    {
        // Get authenticated user
        $auth_ok = $this->authenticate();
        if (!$auth_ok) {
            return $this->apiResponse(
                '401',
                'error',
                'Access token is missing or invalid',
                'getUserProjects',
                null,
                null
            );
        }

        // Get projects
        $projects = $this->user->getProjects();

        return $this->objectResponse($projects, 'getUserProjects', array('login' => $this->user->login));
    }
}
?>

