<?php
/**
 * @author    3liz
 * @copyright 2020 3liz
 *
 * @see      http://3liz.com
 *
 * @license Mozilla Public License : http://www.mozilla.org/MPL/
 */
class Token
{
    /**
     * Get the token from the Authentication request header.
     *
     * @return string JWC token
     */
    public function getTokenFromHeader()
    {
        // Get Authorization header value
        $authorization = jApp::coord()->request->header('Authorization');
        if (!$authorization || empty($authorization)) {
            return null;
        }

        // Get token
        $matches = array();
        preg_match('#Bearer (.+)#', $authorization, $matches);
        if (isset($matches[1])) {
            $token = $matches[1];
            if (empty($token)) {
                return null;
            }

            return $token;
        }

        return null;
    }

    /**
     * Validate a JWC token and give corresponding user name.
     *
     * @param string token Token passed in Authentication header
     * @param mixed $token
     *
     * @return array User object containing login
     */
    public function getUserFromToken($token)
    {
        // Todo: use PHP lib JWT
        // https://github.com/lcobucci/jwt/
        $cache_key = 'gobs_token_'.$token;
        $cache_login = jCache::get($cache_key);
        if ($cache_login) {
            // Check that the user exists
            $user_jelix = jAuth::getUser($cache_login);
            if ($user_jelix) {
                $login = $user_jelix->login;

                // Set jelix user session
                // This allow to use jAuth and jAcl2 methods
                // within the API
                //jAuth::setUserSession($login);

                return array(
                    'usr_login' => $login,
                );
            }
        }

        return null;
    }

    /**
     * Generate a JWC token for a given login.
     *
     * @param string $login
     *
     * @return string JWC token
     */
    public function generateToken($login)
    {
        // Todo: use PHP lib JWT
        // https://github.com/lcobucci/jwt/
        $rand = substr(md5(microtime()), rand(0, 26), 10);
        $token = md5($login.$rand);

        // Store token in cache to keep track of token for this login
        $cache_key = 'gobs_token_'.$token;
        jCache::set($cache_key, $login, 3600);

        return $token;
    }

    /**
     * Destroy a JWC token.
     *
     * @param string $token Token
     *
     * @return string JWC token
     */
    public function destroyToken($token)
    {
        // TODO: use PHP lib JWT
        // https://github.com/lcobucci/jwt/

        // Invalidate token in cache
        $cache_key = 'gobs_token_'.$token;
        jCache::delete($cache_key);

        return true;
    }
}
