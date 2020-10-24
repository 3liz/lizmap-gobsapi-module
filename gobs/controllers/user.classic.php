<?php

include jApp::getModulePath('gobs').'controllers/apiController.php';

class userCtrl extends apiController
{
    /**
     * Generate a JWC token.
     *
     * @param string username Username of the user logged in
     * @param mixed $username
     *
     * @return string JWC token
     */
    private function generateToken($username)
    {
        // Todo: use PHP lib JWT
        // https://github.com/lcobucci/jwt/
        return md5($username);
    }

    /**
     * Validate a JWC token and give corresponding user name.
     *
     * @param string token Token passed in Authentication header
     * @param mixed $token
     *
     * @return string Login of the corresponding user name
     */
    private function validateToken($token)
    {
        // TODO
        if (true) {
            return true;
        }

        return false;
    }

    /**
     * Destroy a JWC token.
     *
     * @param string username Username of the user logged in
     * @param mixed $username
     *
     * @return string JWC token
     */
    private function destroyToken($username)
    {
        // TODO
        // Invalidate token and related session
    }

    /**
     * Logs user into the system.
     *
     * @httpmethod GET
     * @httpparam string username Username of the user to log in
     * @httpparam string password Password of the user to log in
     * @httpresponse {"token": "1mx6L2L7AMdEsyKy5LW9s8gt6mBxdICwosVn5sjhbwykOoQJFUru6752dwsj2THN"}
     *
     * @return jResponseJson JWC token or error code
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
                'Invalid username/password supplied'
            );
        }

        // Temporary for dev purpose only
        // return success
        return $this->apiResponse(
            '200',
            'success',
            'User successfully logged in'
        );

        // Generate token
        // TODO use a real class for this
        $user_session = jAuth::getUserSession();
        $token = $this->generateJwcToken($user_session->login);

        // Return token
        $rep->setHttpStatus('200', 'Successfully authenticated');
        $data = array(
            'token' => $token,
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

        // TODO: use PHP lib JWC

        // Get and validate the token
        $token = 'test';
        $validate_token = $this->validateToken($token);
        if (!$validate_token) {
            return $this->apiResponse(
                '401',
                'error',
                'Access token is missing or invalid'
            );
        }

        // Log the user out
        //$log_user = jAuth::logout($username);
        $login = 'admin';
        $log_user = jAuth::logout($login);

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
        $user_session = jAuth::getUserSession();
        if (!$user_session) {
            return $this->apiResponse(
                '401',
                'error',
                'You must authenticate to get the user projects'
            );
        }

        jClasses::inc('gobs~User');
        $user = new User($user_session->login);
        $projects = $user->getProjects();

        return $this->objectResponse($projects);
    }
}
?>

