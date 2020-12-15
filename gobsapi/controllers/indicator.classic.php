<?php

include jApp::getModulePath('gobsapi').'controllers/apiController.php';

class indicatorCtrl extends apiController
{
    /**
     * Check given indicator can be accessed by the user
     * and that it is a valid G-Obs indicator.
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
                null,
            );
        }
        $user = $this->user;
        $login = $user['usr_login'];

        // Check indicatorKey parameter
        $indicator_code = $this->param('indicatorCode');
        if (!$indicator_code) {
            return array(
                '400',
                'error',
                'The indicatorKey parameter is mandatory',
                null,
            );
        }

        // Get indicator
        jClasses::inc('gobsapi~Indicator');
        $gobs_indicator = new Indicator($indicator_code);

        // Check indicatorKey is valid
        if (!$gobs_indicator->checkCode()) {
            return array(
                '400',
                'error',
                'The indicatorKey parameter is invalid',
                null,
            );
        }

        // Check indicator exists
        $indicator = $gobs_indicator->get();
        if (!$indicator) {
            return array(
                '404',
                'error',
                'The given indicator code does not refer to a known indicator',
                null,
            );
        }

        return array('200', 'success', 'Indicator is a G-Obs indicator', $gobs_indicator);

        // Check projectKey parameter
        $project_key = $this->param('projectKey');
        if (!$project_key) {
            return array(
                '400',
                'error',
                'The projectKey parameter is mandatory',
                null,
            );
        }

        // Check project is valid
        try {
            $project = lizmap::getProject($project_key);
            if (!$project) {
                return array(
                    '404',
                    'error',
                    'The given project key does not refer to a known project',
                    null,
                );
            }
        } catch (UnknownLizmapProjectException $e) {
            return array(
                '404',
                'error',
                'The given project key does not refer to a known project',
                null,
            );
        }

        // Check the authenticated user can access to the project
        if (!$project->checkAcl($login)) {
            return array(
                '403',
                'error',
                jLocale::get('view~default.repository.access.denied'),
                null,
            );
        }

        // Get gobs project manager
        jClasses::inc('gobsapi~Project');
        $gobs_project = new Project($project);

        // Test if project has and indicator
        $indicators = $gobs_project->getProjectIndicators();
        if (!$indicators) {
            return array(
                '404',
                'error',
                'The given project key does not refer to a G-Obs project',
                null,
            );
        }

        // Ok
        return array('200', 'success', 'Project is a G-Obs project', $gobs_project);
    }

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

        // Check indicator can be accessed and is a valid G-Obs indicator
        list($code, $status, $message, $gobs_indicator) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        $indicator = $gobs_indicator->get();

        return $this->objectResponse($indicator);
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
    public function getObservationsByIndicator()
    {

        // Check indicator can be accessed and is a valid G-Obs indicator
        list($code, $status, $message, $gobs_indicator) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        $data = $gobs_indicator->getObservations(
            $this->requestSyncDate,
            $this->lastSyncDate
        );

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
    public function getDeletedObservationsByIndicator()
    {
        // Check indicator can be accessed and is a valid G-Obs indicator
        list($code, $status, $message, $gobs_indicator) = $this->check();
        if ($status == 'error') {
            return $this->apiResponse(
                $code,
                $status,
                $message
            );
        }

        $data = $gobs_indicator->getDeletedObservations(
            $this->requestSyncDate,
            $this->lastSyncDate
        );

        return $this->objectResponse($data);
    }
}
